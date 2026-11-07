import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Shared pose geometry, calibration and YOLO fusion. The live camera supplies
/// MediaPipe landmarks through PostureMediaPipeEstimator. The Vision estimator remains
/// available for offline comparisons; both use the same image-space measurement units.
/// Missing or off-screen hips do not contribute to torso measurements. Strong model/pose
/// disagreements stay unknown, and model Bad is never directly changed to Good.

// MARK: - View

/// Which way the person faces the camera. A seated body measures differently in a profile
/// view and a square-on view, so each view keeps its own calibration.
enum PosturePoseView: String, Equatable, Sendable, CaseIterable, Codable {
    case profile
    case oblique
    case frontal

    /// Inferred from shoulder span against head height: square-on, the shoulders are wide
    /// relative to the head; seen from the side they nearly vanish.
    init(shoulderSpan: Double, headHeight: Double) {
        let ratio = headHeight > 0.001 ? shoulderSpan / headHeight : 0
        if ratio < 0.6 {
            self = .profile
        } else if ratio > 1.0 {
            self = .frontal
        } else {
            self = .oblique
        }
    }
}

// MARK: - Sample

/// One joint handed to the preview overlay (normalised, y-down).
struct PosturePoseJoint: Equatable {
    let name: String
    let point: CGPoint
    let confidence: Double
}

/// Measurements of one frame, in the units the judge expects.
///
/// Lengths are expressed in shoulder spans, the one scale present in every usable frame.
/// Angles are degrees in image space.
struct PosturePoseFeatures: Equatable {
    /// Ear line against the shoulder line, so camera roll cancels out.
    var headTiltDegrees: Double
    /// Head pushed sideways past the shoulder midpoint, in shoulder spans.
    var headForward: Double
    /// Head height above the shoulder line, in shoulder spans. A slouch sinks this.
    var headAbove: Double
    /// Shoulder line against the image horizontal. In a frontal view this is mostly camera
    /// roll, which the calibrated baseline absorbs.
    var shoulderTiltDegrees: Double
    /// Shoulder midpoint to hip midpoint against the image vertical; nil when the hips and
    /// the root were both invisible - the usual case for a seated person.
    var torsoLeanDegrees: Double?
    var view: PosturePoseView
    /// Mean confidence of the joints the frame relied on.
    var confidence: Double
    /// Person box in normalised, y-down coordinates; the crop retry uses it.
    var box: CGRect
    /// Quality of the weakest head/shoulder anchor, rather than their average.
    var weakestJointConfidence: Double = 0
    var headTiltMeasured: Bool = false

    var reliableForConflict: Bool {
        confidence.isFinite && confidence >= 0.5 && weakestJointConfidence >= 0.35 &&
        headTiltMeasured && PosturePoseBaseline.measurements(self).values.allSatisfy { $0.isFinite }
    }
}

/// One Vision pass over one frame.
struct PosturePoseSample: Equatable {
    /// Bodies the body-pose estimator found. Anything but one is not a confirmed posture.
    let bodyCount: Int
    /// Geometry, when enough joints were clear enough to measure.
    let features: PosturePoseFeatures?
    /// Joints for the preview overlay.
    let joints: [PosturePoseJoint]
    /// Person box from the body-pose joints. Available when the pose saw enough joints,
    /// even when they are too poor to measure a posture from.
    let box: CGRect?
    /// Best person location for the crop retry: the pose box when available, otherwise
    /// the human-rectangle box or the face-expanded box. Locating the person is a far
    /// easier job than measuring them, so this survives when `features` is nil.
    /// Nil when the frame is ambiguous (more than one person) or nobody was located.
    let locationBox: CGRect?
    /// All location candidates, in priority order. The crop retry asks YOLO about each
    /// candidate until one answers, so a broad human box can be followed by a tighter
    /// face/head-shoulder crop.
    let locationBoxes: [CGRect]
    /// People located by any detector (pose / human / face), capped at their maximum.
    /// The crop retry only runs when this is exactly one.
    let locatedBodies: Int

    init(bodyCount: Int, features: PosturePoseFeatures?, joints: [PosturePoseJoint],
         box: CGRect?, locationBox: CGRect? = nil, locationBoxes: [CGRect] = [],
         locatedBodies: Int = 0) {
        self.bodyCount = bodyCount
        self.features = features
        self.joints = joints
        self.box = box
        let candidates = locationBoxes + [locationBox, box].compactMap { $0 }
        var unique: [CGRect] = []
        for candidate in candidates where !unique.contains(where: { $0 == candidate }) {
            unique.append(candidate)
        }
        self.locationBoxes = unique
        self.locationBox = locationBox ?? box
        self.locatedBodies = max(locatedBodies, box == nil ? 0 : 1, bodyCount)
    }

    static let empty = PosturePoseSample(bodyCount: 0, features: nil, joints: [], box: nil,
                                         locationBox: nil, locatedBodies: 0)
}

// MARK: - Estimator

/// Runs Apple's 2D body-pose estimator on camera frames; about 6 ms on an M3, so it can
/// run on every frame.
final class PosturePoseEstimator {
    /// Joint confidence below this is treated as "not seen" for posture measurement.
    /// Vision's body-pose confidences run much lower than MediaPipe's visibility scores -
    /// a correct shoulder often lands near 0.6, and 0.3 is the low end of useful - so this
    /// is not 0.5.
    static let minimumJointConfidence: Double = 0.25
    /// Locating a person is easier than measuring their posture. A couple of faint joints
    /// are enough to build a crop; the strict measurement thresholds above remain in force
    /// for the actual GOOD/BAD decision.
    static let minimumLocatingJointConfidence: Double = 0.10
    static let minimumLocatingJointCount = 2
    /// A shoulder span below this (fraction of frame height) means the two shoulders
    /// collapsed onto each other and every angular measurement downstream is noise.
    static let minimumShoulderSpan: Double = 0.09

    private let request = VNDetectHumanBodyPoseRequest()

    func analyse(_ pixelBuffer: CVPixelBuffer) -> PosturePoseSample {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return .empty }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .empty
        }
        let observations = request.results ?? []
        // More than one body is ambiguous: the app requires a single person, exactly as
        // the detector does, so the caller keeps the frame UNKNOWN.
        guard observations.count == 1, let observation = observations.first else {
            return fallbackLocation(in: handler, detectedBodies: observations.count)
        }
        let points = (try? observation.recognizedPoints(.all)) ?? [:]
        let joints = Self.overlayJoints(points)
        let box = Self.personBox(from: points, width: width, height: height)
        let features = Self.features(from: points, width: width, height: height)
        // The strict box needs three solid joints; a looser locating box is enough to
        // frame a crop, and the measurement thresholds below stay untouched.
        let location = box ?? Self.locatingBox(from: points, width: width, height: height)
        if let location {
            return PosturePoseSample(bodyCount: 1, features: features, joints: joints, box: box,
                                     locationBox: location, locatedBodies: 1)
        }
        // The body-pose request found one body but exposed almost no joints.
        // Human/face rectangles can still locate it.
        return fallbackLocation(in: handler, detectedBodies: 1)
    }

    /// A hierarchy of person detectors used only when body-pose joints cannot provide a
    /// crop box: human rectangle first, then a face rectangle expanded into a head-and-
    /// shoulders crop. These paths locate a person; they never decide GOOD or BAD.
    /// Requests are created per call: Vision requests hold per-run state and must not be
    /// reused across frames.
    private func fallbackLocation(in handler: VNImageRequestHandler,
                                  detectedBodies: Int) -> PosturePoseSample {
        var candidates: [CGRect] = []
        let humanRectangleRequest = VNDetectHumanRectanglesRequest()
        do {
            try handler.perform([humanRectangleRequest])
            let humans = humanRectangleRequest.results ?? []
            if humans.count == 1, let observation = humans.first {
                candidates.append(Self.normalizedBox(observation.boundingBox))
            } else if humans.count > 1 {
                return PosturePoseSample(bodyCount: detectedBodies, features: nil, joints: [],
                                         box: nil, locationBox: nil,
                                         locatedBodies: max(humans.count, detectedBodies))
            }
        } catch {
            // Continue to the face fallback.
        }

        let faceRectangleRequest = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([faceRectangleRequest])
            let faces = faceRectangleRequest.results ?? []
            if faces.count == 1, let observation = faces.first {
                candidates.append(Self.expandedHeadShoulderBox(
                    Self.normalizedBox(observation.boundingBox)))
            } else if !candidates.isEmpty {
                return PosturePoseSample(bodyCount: detectedBodies, features: nil, joints: [],
                                         box: nil, locationBox: candidates[0],
                                         locationBoxes: candidates,
                                         locatedBodies: max(1, detectedBodies))
            } else {
                return PosturePoseSample(bodyCount: detectedBodies, features: nil, joints: [],
                                         box: nil, locationBox: nil,
                                         locatedBodies: max(faces.count, detectedBodies))
            }
        } catch {
            if candidates.isEmpty {
                return PosturePoseSample(bodyCount: detectedBodies, features: nil, joints: [],
                                         box: nil, locationBox: nil, locatedBodies: detectedBodies)
            }
        }
        guard let first = candidates.first else {
            return PosturePoseSample(bodyCount: detectedBodies, features: nil, joints: [],
                                     box: nil, locationBox: nil, locatedBodies: detectedBodies)
        }
        return PosturePoseSample(bodyCount: detectedBodies, features: nil, joints: [], box: nil,
                                 locationBox: first, locationBoxes: candidates,
                                 locatedBodies: max(1, detectedBodies))
    }

    /// Vision rectangles use a bottom-left origin; the rest of the posture pipeline uses
    /// a top-left origin.
    static func normalizedBox(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// Expands a face into the region that contains the head and upper torso. The crop
    /// pipeline turns this into a padded square before asking YOLO again.
    static func expandedHeadShoulderBox(_ face: CGRect) -> CGRect {
        let horizontal = max(face.width * 3.0, 0.12)
        let vertical = max(face.height * 3.75, 0.18)
        return CGRect(x: face.midX - horizontal / 2,
                      y: face.minY - face.height * 0.35,
                      width: horizontal, height: vertical)
    }

    // MARK: geometry

    /// Vision reports normalised coordinates with a bottom-left origin; the posture maths
    /// wants a top-left origin with x in units of frame height, so a tilt in a 16:9 frame
    /// measures the same angle as the same tilt in a 3:4 frame.
    static func converted(_ point: VNRecognizedPoint, aspect: Double) -> CGPoint {
        CGPoint(x: point.location.x * aspect, y: 1 - point.location.y)
    }

    /// Every joint worth drawing, normalised for the overlay.
    private static func overlayJoints(
        _ points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> [PosturePoseJoint] {
        let wanted: [(VNHumanBodyPoseObservation.JointName, String)] = [
            (.neck, "neck"), (.nose, "nose"),
            (.leftShoulder, "left shoulder"), (.rightShoulder, "right shoulder"),
            (.leftElbow, "left elbow"), (.rightElbow, "right elbow"),
            (.leftWrist, "left wrist"), (.rightWrist, "right wrist"),
            (.leftHip, "left hip"), (.rightHip, "right hip"), (.root, "root"),
            (.leftKnee, "left knee"), (.rightKnee, "right knee"),
        ]
        return wanted.compactMap { joint, name in
            guard let point = points[joint], point.confidence > 0.15 else { return nil }
            return PosturePoseJoint(
                name: name,
                point: CGPoint(x: point.location.x, y: 1 - point.location.y),
                confidence: Double(point.confidence)
            )
        }
    }

    /// Bounding box of every joint Vision was reasonably sure about, in normalised y-down
    /// coordinates. Deliberately loose: this only has to contain the person.
    static func personBox(
        from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        width: Int,
        height: Int
    ) -> CGRect? {
        guard width > 0, height > 0 else { return nil }
        let aspect = Double(width) / Double(height)
        let visible = points.values
            .filter { $0.confidence > 0.15 }
            .map { converted($0, aspect: aspect) }
        guard visible.count >= 3 else { return nil }
        let xs = visible.map { $0.x / aspect }
        let ys = visible.map { $0.y }
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: max((xs.max() ?? 1) - (xs.min() ?? 0), 0.02),
                      height: max((ys.max() ?? 1) - (ys.min() ?? 0), 0.02))
    }

    /// Looser locating box: two faint joints are enough to frame a crop. This feeds only
    /// the YOLO re-check; the GOOD/BAD geometry still requires the strict box and the
    /// strict joint confidences in `features(from:width:height:)`.
    static func locatingBox(
        from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        width: Int,
        height: Int
    ) -> CGRect? {
        guard width > 0, height > 0 else { return nil }
        let aspect = Double(width) / Double(height)
        let faint = points.values
            .filter { $0.confidence >= Float(minimumLocatingJointConfidence) }
            .map { converted($0, aspect: aspect) }
        guard faint.count >= minimumLocatingJointCount else { return nil }
        let xs = faint.map { $0.x / aspect }
        let ys = faint.map { $0.y }
        let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                         width: max((xs.max() ?? 1) - (xs.min() ?? 0), 0.02),
                         height: max((ys.max() ?? 1) - (ys.min() ?? 0), 0.02))
        // A box collapsed to a point is a hallucination, not a person.
        guard box.width >= 0.02, box.height >= 0.03 else { return nil }
        return box
    }

    /// Reduces joints to the features the judge scores. Returns nil when the shoulders are
    /// not clear enough - or not far enough apart - to measure anything trustworthy.
    static func features(
        from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        width: Int,
        height: Int
    ) -> PosturePoseFeatures? {
        measurements(from: points.mapValues {
            PosturePoseJoint(name: "", point: CGPoint(x: $0.location.x, y: 1 - $0.location.y),
                             confidence: Double($0.confidence))
        }, width: width, height: height)
    }

    /// Backend-independent normalised, top-left landmarks. MediaPipe uses stricter
    /// visibility thresholds than Vision's point confidence; those scores are not interchangeable.
    static func measurements(
        from points: [VNHumanBodyPoseObservation.JointName: PosturePoseJoint],
        width: Int, height: Int,
        minimumConfidence: Double = minimumJointConfidence,
        minimumEarConfidence: Double = 0.12,
        minimumHipConfidence: Double = 0.20
    ) -> PosturePoseFeatures? {
        guard width > 0, height > 0 else { return nil }
        let aspect = Double(width) / Double(height)

        func joint(_ name: VNHumanBodyPoseObservation.JointName,
                   minimum: Double? = nil) -> (point: CGPoint, confidence: Double)? {
            guard let point = points[name], point.confidence.isFinite,
                  point.confidence >= (minimum ?? minimumConfidence),
                  point.point.x.isFinite, point.point.y.isFinite,
                  (0...1).contains(point.point.x), (0...1).contains(point.point.y) else { return nil }
            return (CGPoint(x: point.point.x * aspect, y: point.point.y), point.confidence)
        }

        guard let shoulderL = joint(.leftShoulder),
              let shoulderR = joint(.rightShoulder) else { return nil }
        let shoulderMid = CGPoint(x: (shoulderL.point.x + shoulderR.point.x) / 2,
                                  y: (shoulderL.point.y + shoulderR.point.y) / 2)
        let span = hypot(shoulderR.point.x - shoulderL.point.x,
                         shoulderR.point.y - shoulderL.point.y)
        guard span >= Self.minimumShoulderSpan else { return nil }

        // Head: the nose is the ideal anchor, the ear midpoint the usual fallback when the
        // face is turned away or masked, and the neck pushed upward the last resort when a
        // hand, hair or a steep angle hides the face. The neck estimate only frames
        // headAbove/headForward in a plausible range; head tilt still needs both ears.
        let nose = joint(.nose)
        let earL = joint(.leftEar, minimum: minimumEarConfidence)
        let earR = joint(.rightEar, minimum: minimumEarConfidence)
        var head: CGPoint?
        var headConfidence = 0.0
        if let nose {
            head = nose.point
            headConfidence = nose.confidence
        } else if let earL, let earR {
            head = CGPoint(x: (earL.point.x + earR.point.x) / 2,
                           y: (earL.point.y + earR.point.y) / 2)
            headConfidence = min(earL.confidence, earR.confidence)
        } else if let neck = joint(.neck) {
            // Converted y grows downward, so the head sits above the neck.
            head = CGPoint(x: neck.point.x, y: neck.point.y - span * 0.5)
            headConfidence = neck.confidence * 0.8
        }
        guard let head else { return nil }

        let shoulderTilt = halfTurn(angle(shoulderR.point.x - shoulderL.point.x,
                                          shoulderR.point.y - shoulderL.point.y))
        // Head tilt needs both ears; a single visible ear carries no line. Both lines are
        // folded into (-90, 90] before subtracting so the difference is the real angle.
        var headTilt = 0.0
        if let earL, let earR {
            let earTilt = halfTurn(angle(earR.point.x - earL.point.x,
                                         earR.point.y - earL.point.y))
            headTilt = halfTurn(earTilt - shoulderTilt)
        }

        // Torso: a seated person usually has no visible hips, in which case there is no
        // torso axis to measure and the rules that need one simply do not run.
        let hipL = joint(.leftHip, minimum: minimumHipConfidence)
        let hipR = joint(.rightHip, minimum: minimumHipConfidence)
        let root = joint(.root, minimum: minimumHipConfidence)
        var hipPoint: CGPoint?
        var hipConfidence = 0.0
        switch (hipL, hipR, root) {
        case let (left?, right?, _):
            hipConfidence = min(left.confidence, right.confidence)
            hipPoint = CGPoint(x: (left.point.x + right.point.x) / 2,
                               y: (left.point.y + right.point.y) / 2)
        case let (_, _, root?):
            hipConfidence = root.confidence
            hipPoint = root.point
        default:
            hipPoint = nil
        }
        var torsoLean: Double?
        if let hipPoint {
            let dx = hipPoint.x - shoulderMid.x
            let dy = hipPoint.y - shoulderMid.y
            // A hip point sitting on the shoulders is a hallucinated hip, not a torso.
            if hypot(dx, dy) > span * 0.6 { torsoLean = tiltFromVertical(dx, dy) }
        }

        // Person box over everything that survived, for the crop retry. The head alone is
        // enough of an anchor when nothing else does.
        let anchor = [head, shoulderL.point, shoulderR.point, hipPoint].compactMap { $0 }
        let xs = anchor.map { $0.x / aspect }
        let ys = anchor.map { $0.y }
        let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                         width: max((xs.max() ?? 1) - (xs.min() ?? 0), 0.02),
                         height: max((ys.max() ?? 1) - (ys.min() ?? 0), 0.02))

        let headAbove = (shoulderMid.y - head.y) / span
        let confidence = ([shoulderL.confidence, shoulderR.confidence, headConfidence])
            .reduce(0, +) / 3

        return PosturePoseFeatures(
            headTiltDegrees: headTilt,
            headForward: abs(head.x - shoulderMid.x) / span,
            headAbove: headAbove,
            shoulderTiltDegrees: shoulderTilt,
            torsoLeanDegrees: torsoLean,
            view: PosturePoseView(shoulderSpan: span, headHeight: headAbove * span),
            confidence: confidence,
            box: box,
            weakestJointConfidence: min(shoulderL.confidence, shoulderR.confidence, headConfidence,
                                        torsoLean == nil ? 1 : hipConfidence),
            headTiltMeasured: (earL?.confidence ?? 0) >= 0.35 && (earR?.confidence ?? 0) >= 0.35
        )
    }

    /// Direction of a line in the image plane, degrees.
    private static func angle(_ dx: Double, _ dy: Double) -> Double { atan2(dy, dx) * 180 / .pi }

    /// Tilt of a mostly downward vector away from the image vertical; 0 = upright.
    private static func tiltFromVertical(_ dx: Double, _ dy: Double) -> Double {
        atan2(dx, dy) * 180 / .pi
    }

    private static func halfTurn(_ value: Double) -> Double {
        var folded = (value + 90).truncatingRemainder(dividingBy: 180)
        if folded < 0 { folded += 180 }
        return folded - 90
    }
}

// MARK: - Baseline

/// Per-user, per-view reference of the features measured while sitting straight.
///
/// The median of the collected samples says where this person, at this desk, with this
/// camera angle, sits when they sit well; the median absolute deviation says how much that
/// wobbles by itself. Only confidently-good frames that break no ergonomic limit are fed
/// in, so a slouch cannot teach the reference what "straight" means.
struct PosturePoseBaseline: Equatable, Codable {
    static let window = 600
    static let minimumSamples = 24

    /// Smallest useful tolerance per feature; the live tolerance is several robust sigmas,
    /// never below this, so a perfectly still user gets no alert noise.
    static let floor: [String: Double] = [
        "headTilt": 5.0,
        "headForward": 0.10,
        "headAbove": 0.12,
        "shoulderTilt": 5.0,
        "torsoLean": 5.0,
    ]

    private var values: [PosturePoseView: [String: [Double]]] = [:]
    private(set) var counts: [PosturePoseView: Int] = [:]

    var samples: Int { counts.values.reduce(0, +) }

    var isCalibrated: Bool { counts.values.contains { $0 >= Self.minimumSamples } }

    func isReady(for view: PosturePoseView) -> Bool {
        (counts[view] ?? 0) >= Self.minimumSamples
    }

    mutating func observe(_ features: PosturePoseFeatures) {
        var series = values[features.view] ?? [:]
        for (name, value) in Self.measurements(features) {
            var list = series[name] ?? []
            list.append(value)
            if list.count > Self.window { list.removeFirst(list.count - Self.window) }
            series[name] = list
        }
        values[features.view] = series
        counts[features.view, default: 0] += 1
    }

    /// Only measured features from the same calibrated view can establish agreement.
    /// Losing a feature (for example hips) cannot masquerade as an upright zero angle.
    func matchesUpright(_ features: PosturePoseFeatures) -> Bool {
        guard isReady(for: features.view), let reference = values[features.view] else { return false }
        let current = Self.measurements(features)
        return reference.allSatisfy { name, samples in
            guard samples.count >= Self.minimumSamples, let value = current[name], value.isFinite,
                  let center = center(name, view: features.view) else { return false }
            return abs(value - center) <= tolerance(name, view: features.view)
        }
    }

    func hasReference(_ name: String, view: PosturePoseView) -> Bool {
        isReady(for: view) && (values[view]?[name]?.count ?? 0) >= Self.minimumSamples
    }

    mutating func discardSparseMeasurements() {
        for view in Array(values.keys) {
            values[view] = values[view]?.filter { $0.value.count >= Self.minimumSamples }
        }
    }

    func center(_ name: String, view: PosturePoseView) -> Double? {
        guard isReady(for: view), let list = values[view]?[name], !list.isEmpty else { return nil }
        return Self.median(list)
    }

    func tolerance(_ name: String, view: PosturePoseView) -> Double {
        let minimum = Self.floor[name] ?? 0.05
        guard isReady(for: view), let list = values[view]?[name], list.count >= 8 else {
            return minimum
        }
        let center = Self.median(list)
        let deviation = Self.median(list.map { abs($0 - center) }) * 1.4826
        return max(minimum, 3.5 * deviation)
    }

    mutating func reset() {
        values.removeAll()
        counts.removeAll()
    }

    static func measurements(_ features: PosturePoseFeatures) -> [String: Double] {
        var result: [String: Double] = [
            "headForward": features.headForward,
            "headAbove": features.headAbove,
            "shoulderTilt": features.shoulderTiltDegrees,
        ]
        if features.headTiltMeasured { result["headTilt"] = features.headTiltDegrees }
        if let lean = features.torsoLeanDegrees { result["torsoLean"] = lean }
        return result
    }

    private static func median(_ list: [Double]) -> Double {
        let sorted = list.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

// MARK: - Judge

/// Turns pose features into GOOD / BAD / UNKNOWN with an explainable score.
struct PosturePoseJudge: Equatable {
    // Limits are ergonomic in kind and Vision-calibrated in value: the nine sample photos
    // put upright heads at 0.4-8 degrees of tilt, 0.02-0.05 shoulder spans of forward
    // offset and 0.57-0.69 spans of height, while the slouched frame Vision could measure
    // cleanly reached 45 degrees of tilt and 0.35 spans of forward offset. The calibrated
    // baseline below is what catches the subtler drift between those.
    static let headTiltBad = 20.0, headTiltFull = 40.0
    static let headForwardBad = 0.22, headForwardFull = 0.45
    static let headAboveBad = 0.45, headAboveFull = 0.30      // below this the head has sunk
    static let shoulderTiltBad = 25.0, shoulderTiltFull = 45.0
    static let torsoLeanBad = 18.0, torsoLeanFull = 32.0
    static let badScore = 0.55
    static let softScore = 0.25
    static let goodScore = 0.15
    /// Pose badness needed to overturn a confident model GOOD.
    static let vetoScore = 0.75

    var baseline = PosturePoseBaseline()
    var usesManualReference = false

    func absoluteScores(_ features: PosturePoseFeatures) -> [String: Double] {
        var scores: [String: Double] = [
            "head tilt": exceedance(abs(features.headTiltDegrees), Self.headTiltBad,
                                    Self.headTiltFull),
            "forward head": exceedance(features.headForward, Self.headForwardBad,
                                       Self.headForwardFull),
            "head sunk": belowExceedance(features.headAbove, Self.headAboveBad,
                                          Self.headAboveFull),
            "shoulders tilted": exceedance(abs(features.shoulderTiltDegrees),
                                            Self.shoulderTiltBad, Self.shoulderTiltFull),
        ]
        if let lean = features.torsoLeanDegrees {
            scores["torso lean"] = exceedance(abs(lean), Self.torsoLeanBad, Self.torsoLeanFull)
        }
        return scores
    }

    func relativeScores(_ features: PosturePoseFeatures) -> [String: Double] {
        guard baseline.isReady(for: features.view) else { return [:] }
        var scores: [String: Double] = [:]
        for (name, value) in PosturePoseBaseline.measurements(features) {
            guard let center = baseline.center(name, view: features.view) else { continue }
            let tolerance = baseline.tolerance(name, view: features.view)
            let drift = abs(value - center)
            // Two tolerances of drift is a full score: a clear move away from this user's
            // own straight posture, even while still inside the ergonomic limits.
            if drift > tolerance {
                scores["drift:\(name)"] = min(1, (drift - tolerance) / tolerance)
            }
        }
        return scores
    }

    func verdict(for features: PosturePoseFeatures?) -> PosturePoseVerdict {
        guard let features else {
            return PosturePoseVerdict(state: .unknown, score: 0, confidence: 0,
                                      reasons: ["pose: not enough of the body visible"])
        }
        var combined = absoluteScores(features)
        if usesManualReference, baseline.isReady(for: features.view) {
            // A user-confirmed reference absorbs camera framing and body proportions.
            // Automatic learning never bypasses the original absolute limits.
            let calibratedNames = ["head tilt": "headTilt", "forward head": "headForward",
                                   "head sunk": "headAbove", "shoulders tilted": "shoulderTilt",
                                   "torso lean": "torsoLean"]
            for (score, measurement) in calibratedNames {
                if baseline.hasReference(measurement, view: features.view) {
                    combined.removeValue(forKey: score)
                }
            }
            if !PostureCalibrationSession.plausibleReference(features) {
                combined["pose outside calibration range"] = 1
            }
        }
        combined.merge(relativeScores(features)) { current, new in max(current, new) }
        var score = combined.values.max() ?? 0
        let soft = combined.filter { $0.value >= Self.softScore }.keys
        var reasons = combined
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { String(format: "%@ %.2f", $0.key, $0.value) }
        // Two moderate deviations in different places (a tilted *and* a pushed-forward head,
        // say) are a slouch even when neither alone crosses the confident limit.
        if soft.count >= 2 {
            score = max(score, Self.badScore)
            reasons.append("several postures off at once")
        }
        if score >= Self.badScore {
            return PosturePoseVerdict(state: .bad, score: score,
                                      confidence: min(0.95, 0.5 + 0.5 * score),
                                      reasons: reasons)
        }
        if score <= Self.goodScore {
            let confidence = baseline.isReady(for: features.view) ? 0.75 : 0.55
            return PosturePoseVerdict(state: .good, score: score, confidence: confidence,
                                      reasons: reasons.isEmpty ? ["pose: aligned"] : reasons)
        }
        return PosturePoseVerdict(state: .unknown, score: score, confidence: 0,
                                  reasons: reasons.isEmpty ? ["pose: inconclusive"] : reasons)
    }

    /// True when the pose breaks an ergonomic limit, so it must not train the baseline.
    func grossViolation(_ features: PosturePoseFeatures) -> Bool {
        (absoluteScores(features).values.max() ?? 0) > 0
    }

    private func exceedance(_ value: Double, _ bad: Double, _ full: Double) -> Double {
        guard value > bad, full > bad else { return 0 }
        return min(1, (value - bad) / (full - bad))
    }

    private func belowExceedance(_ value: Double, _ bad: Double, _ full: Double) -> Double {
        guard value < bad, bad > full else { return 0 }
        return min(1, (bad - value) / (bad - full))
    }
}

/// One pose verdict, before temporal damping.
struct PosturePoseVerdict: Equatable {
    let state: PostureState
    let score: Double
    let confidence: Double
    let reasons: [String]

    static let unknown = PosturePoseVerdict(state: .unknown, score: 0, confidence: 0, reasons: [])
}

// MARK: - Tracker

/// Keeps the baseline, the judge and the damped verdict together across frames.
///
/// The pose verdict is noisier than a YOLO box, so it is averaged over frames and only
/// changes state when the averaged score crosses a boundary: one odd frame cannot flip GOOD
/// to BAD, and a recovery has to be convincing before the app says good again.
struct PosturePoseTracker: Equatable {
    static let warmup = 3
    static let alpha = 0.35

    private(set) var baseline = PosturePoseBaseline()
    private var smoother = PosturePoseSmoother()
    private(set) var hasManualBaseline = false

    mutating func installManualBaseline(_ reference: PosturePoseBaseline) {
        baseline = reference
        hasManualBaseline = true
        smoother.reset()
    }

    var isCalibrated: Bool { baseline.isCalibrated }

    mutating func resetTemporalEvidence() { smoother.reset() }

    /// Judges one frame and returns the damped state along with the raw verdict.
    mutating func update(_ features: PosturePoseFeatures?) -> (verdict: PosturePoseVerdict,
                                                              state: PostureState) {
        guard let features else {
            smoother.reset()
            return (PosturePoseVerdict(state: .unknown, score: 0, confidence: 0,
                                       reasons: ["pose: no person"]), .unknown)
        }
        let verdict = PosturePoseJudge(baseline: baseline, usesManualReference: hasManualBaseline)
            .verdict(for: features)
        return (verdict, smoother.update(verdict))
    }

    /// Feeds the calibration baseline, but only from frames that are clearly good.
    mutating func learn(_ features: PosturePoseFeatures?, verdict: PosturePoseVerdict,
                        outcomeIsGood: Bool) {
        guard !hasManualBaseline, let features, outcomeIsGood, verdict.state != .bad else { return }
        guard !PosturePoseJudge(baseline: baseline).grossViolation(features) else { return }
        baseline.observe(features)
    }

    mutating func reset() {
        baseline.reset()
        hasManualBaseline = false
        smoother.reset()
    }
}

/// Damped, hysteretic switch for the pose verdict.
struct PosturePoseSmoother: Equatable {
    private var score: Double?
    private var samples = 0
    private(set) var state: PostureState = .unknown

    mutating func update(_ verdict: PosturePoseVerdict) -> PostureState {
        samples += 1
        score = score.map { PosturePoseTracker.alpha * verdict.score
            + (1 - PosturePoseTracker.alpha) * $0 } ?? verdict.score
        let value = score ?? 0
        if samples < PosturePoseTracker.warmup {
            state = .unknown
        } else if value >= PosturePoseJudge.badScore {
            state = .bad
        } else if state == .bad && value > PosturePoseJudge.goodScore {
            state = .bad                       // stay bad until clearly recovered
        } else if value <= PosturePoseJudge.goodScore {
            state = .good
        } else {
            state = .unknown
        }
        return state
    }

    mutating func reset() {
        score = nil
        samples = 0
        state = .unknown
    }
}

// MARK: - Policy

/// The three-step rule that turns the model's answer and the pose's answer into one
/// verdict. Kept free of camera plumbing so it can be exercised off-line by
/// `tools/posture_pose_check.swift` and reasoned about on its own.
enum PostureHybridPolicy {
    /// What the head said when it was asked again about the pose-guided crop.
    enum CropAnswer {
        case notAttempted
        /// Confident answer from the cropped pass, with its best score.
        case answered(PostureOutcome, Double)
        /// Still nothing usable on the crop.
        case abstained
    }

    struct Decision: Equatable {
        let outcome: PostureOutcome
        let source: PostureVerdictSource
        let bestScore: Double
    }

    static func decide(
        model: PostureOutcome,
        singleBody: Bool,
        poseState: PostureState,
        verdict: PosturePoseVerdict,
        crop: CropAnswer,
        poseVeto: Bool = true,
        poseReliable: Bool = true,
        uprightConflictConfirmed: Bool = false
    ) -> Decision {
        var outcome = model
        var source = PostureVerdictSource.model
        var bestScore: Double
        switch model {
        case .good(let value), .bad(let value): bestScore = value
        case .none: bestScore = 0
        }

        // A second pass must not silently select one person out of a multi-person frame.
        if case .none(let people) = model, people > 1 {
            return Decision(outcome: model, source: .model, bestScore: bestScore)
        }
        if !model.isConfirmed {
            // 1. The trained head, asked again about a properly framed crop, is the most
            //    reliable repair - it is the same model the app trusts everywhere else.
            if case let .answered(cropOutcome, cropScore) = crop {
                outcome = cropOutcome
                source = .poseCrop
                bestScore = cropScore
            }
            // 2. Geometry only speaks when the head still has nothing to say.
            if !outcome.isConfirmed, singleBody, poseReliable, poseState != .unknown,
               verdict.state == poseState, verdict.confidence > 0 {
                outcome = poseState == .bad ? .bad(verdict.confidence) : .good(verdict.confidence)
                source = .pose
                bestScore = verdict.confidence
            }
        }

        // Strong disagreements are neutral, so neither source wins by confidence alone.
        if poseVeto, singleBody, poseReliable, case .good = outcome,
           poseState == .bad, verdict.state == .bad,
           verdict.score >= PosturePoseJudge.vetoScore {
            outcome = .none(peopleCount: 1)
            source = .poseVeto
            bestScore = verdict.score
        }
        if poseVeto, singleBody, poseReliable, case .bad = outcome,
           poseState == .good, verdict.state == .good,
           verdict.score <= PosturePoseJudge.goodScore, uprightConflictConfirmed {
            outcome = .none(peopleCount: 1)
            source = .poseConflict
        }
        return Decision(outcome: outcome, source: source, bestScore: bestScore)
    }
}

/// Shared by the live camera and diagnostics. Model/pose scores measure different
/// things and are never averaged as if they were interchangeable probabilities.
struct PostureHybridArbiter {
    static let conflictDuration: TimeInterval = 2
    static let maximumGap: TimeInterval = 0.75
    private var conflictSince: Date?
    private var lastAt: Date?
    private var view: PosturePoseView?

    mutating func reset() {
        conflictSince = nil
        lastAt = nil
        view = nil
    }

    mutating func decide(
        model: PostureOutcome,
        singleBody: Bool,
        poseState: PostureState,
        verdict: PosturePoseVerdict,
        crop: PostureHybridPolicy.CropAnswer,
        features: PosturePoseFeatures?,
        manualBaseline: PosturePoseBaseline? = nil,
        now: Date,
        poseVeto: Bool = true
    ) -> PostureHybridPolicy.Decision {
        var candidate = model
        if case .none(let people) = model, people > 1 {
            candidate = model
        } else if !candidate.isConfirmed, case .answered(let answer, _) = crop {
            candidate = answer
        }
        let reliable = features?.reliableForConflict == true
        let eligible = poseVeto && singleBody && candidate.posture == .bad &&
            poseState == .good && verdict.state == .good &&
            verdict.score <= PosturePoseJudge.goodScore && reliable &&
            features.map { manualBaseline?.matchesUpright($0) == true } == true
        if eligible {
            let gap = lastAt.map { now.timeIntervalSince($0) }
            let continuous = gap.map { $0 > 0 && $0 <= Self.maximumGap } ?? false
            if conflictSince == nil || view != features?.view || !continuous {
                conflictSince = now
            }
            lastAt = now
            view = features?.view
        } else {
            reset()
        }
        let confirmed = conflictSince.map { now.timeIntervalSince($0) >= Self.conflictDuration } ?? false
        // Gross slouches can still veto a model Good without both ears being visible;
        // they must have clear head/shoulder anchors and a raw and smoothed Bad verdict.
        let poseReliable = features.map {
            $0.confidence.isFinite && $0.confidence >= 0.3 && $0.weakestJointConfidence >= 0.2 &&
            PosturePoseBaseline.measurements($0).values.allSatisfy { $0.isFinite }
        } ?? false
        return PostureHybridPolicy.decide(
            model: model, singleBody: singleBody, poseState: poseState, verdict: verdict,
            crop: crop, poseVeto: poseVeto, poseReliable: poseReliable,
            uprightConflictConfirmed: confirmed)
    }
}

// MARK: - Sources

/// Which path produced the verdict, for the preview chip and the diagnostics log.
enum PostureVerdictSource: String, Equatable, Sendable {
    /// The YOLO26 head answered on the full frame - the unchanged primary path.
    case model
    /// The head answered on the pose-guided crop.
    case poseCrop
    /// The pose geometry decided.
    case pose
    /// Strong pose Bad evidence contradicted model Good; the frame is UNKNOWN.
    case poseVeto
    /// Sustained upright evidence against a manual reference contradicted model Bad.
    case poseConflict

    var isVeto: Bool { self == .poseVeto || self == .poseConflict }
}


// MARK: - Explicit calibration

enum PostureCalibrationIssue: Equatable {
    case noPerson, multiplePeople, missingJoints, lowConfidence, poseRange, moving, cameraGap, insufficientSamples

    var message: String {
        switch self {
        case .noPerson: return "No body detected. Move back slightly so your head, both shoulders and upper body are visible."
        case .multiplePeople: return "Multiple people detected. Keep only one person in view."
        case .missingJoints: return "Head or shoulders are unclear. Adjust the camera to show your upper body."
        case .lowConfidence: return "Landmarks are unclear. Add front lighting and keep your shoulders unobstructed."
        case .poseRange: return "The pose is outside the capture range. Sit upright, relax your shoulders and hold steady."
        case .moving: return "Restarting capture. Stay upright and avoid turning for now."
        case .cameraGap: return "Camera frames interrupted. Waiting for a new frame."
        case .insufficientSamples: return "Not enough usable samples. Keep the camera and your posture steady, then retry."
        }
    }
}

enum PostureCalibrationState: Equatable {
    case idle
    case preparing(Int)
    case collecting(Int)
    case waiting(PostureCalibrationIssue, Int)
    case complete
    case failed
    case failedWithReason(PostureCalibrationIssue)

    var progress: Int? {
        switch self {
        case .collecting(let value), .waiting(_, let value): return value
        default: return nil
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .collecting, .waiting: return true
        default: return false
        }
    }
}

/// Stores measurements only, never camera images. Versioned separately from retired modes.
enum PostureManualReference {
    // Vision measurements must never be silently reused with MediaPipe landmarks.
    static let key = "notch.posture.manualReference.mediapipe.v1"

    static func load(defaults: UserDefaults = .standard) -> PosturePoseBaseline? {
        guard let data = defaults.data(forKey: key),
              let reference = try? JSONDecoder().decode(PosturePoseBaseline.self, from: data),
              reference.isCalibrated else { return nil }
        return reference
    }

    static func save(_ reference: PosturePoseBaseline, defaults: UserDefaults = .standard) {
        guard reference.isCalibrated, let data = try? JSONEncoder().encode(reference) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Captures six seconds of usable evidence; brief landmark loss pauses progress.
/// Candidates remain separate from the installed reference until capture succeeds.
struct PostureCalibrationSession {
    static let preparation: TimeInterval = 3
    static let duration: TimeInterval = 6
    static let timeout: TimeInterval = 25
    static let dropoutGrace: TimeInterval = 1
    private(set) var state: PostureCalibrationState = .idle
    private(set) var candidate = PosturePoseBaseline()
    private var startedAt: Date?
    private var lastObservationAt: Date?
    private var lastAcceptedAt: Date?
    private var previousWasUsable = false
    private var captured: TimeInterval = 0
    private var anchor: PosturePoseFeatures?

    /// Broad measurement guards, not a circular requirement to already classify Good.
    static func plausibleReference(_ features: PosturePoseFeatures) -> Bool {
        features.headAbove > 0.1 && features.headAbove < 4 && features.headForward < 1.5 &&
        abs(features.shoulderTiltDegrees) < 45 &&
        (!features.headTiltMeasured || abs(features.headTiltDegrees) < 40) &&
        (features.torsoLeanDegrees.map { abs($0) < 55 } ?? true)
    }

    mutating func start(at now: Date) {
        self = Self()
        startedAt = now
        state = .preparing(3)
    }

    mutating func update(_ features: PosturePoseFeatures?, bodyCount: Int, at now: Date) {
        guard state.isActive, let startedAt else { return }
        if let lastObservationAt, now <= lastObservationAt { return }
        let previousObservation = lastObservationAt
        lastObservationAt = now
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed < Self.timeout else {
            switch state {
            case .waiting(let issue, _): state = .failedWithReason(issue)
            case .preparing: state = .failedWithReason(.cameraGap)
            default: state = .failedWithReason(.insufficientSamples)
            }
            return
        }
        if elapsed < Self.preparation {
            state = .preparing(max(1, Int(ceil(Self.preparation - elapsed))))
            return
        }
        guard bodyCount == 1 else {
            pause(bodyCount > 1 ? .multiplePeople : .noPerson, at: now)
            return
        }
        guard let features else { pause(.missingJoints, at: now); return }
        guard features.confidence.isFinite, features.confidence >= 0.3,
              PosturePoseBaseline.measurements(features).values.allSatisfy({ $0.isFinite }) else {
            pause(.lowConfidence, at: now)
            return
        }
        guard Self.plausibleReference(features) else { pause(.poseRange, at: now); return }
        if let lastAcceptedAt, now.timeIntervalSince(lastAcceptedAt) > Self.dropoutGrace {
            resetCapture()
        }
        if let anchor {
            let current = PosturePoseBaseline.measurements(features)
            let stable = PosturePoseBaseline.measurements(anchor).allSatisfy { name, value in
                // Optional ears/hips may disappear; an unmeasured angle is never stored as zero.
                guard let next = current[name] else { return true }
                return abs(next - value) <= 2 * (PosturePoseBaseline.floor[name] ?? 0.05)
            }
            if features.view != anchor.view || !stable {
                resetCapture()
                self.anchor = features
                candidate.observe(features)
                lastAcceptedAt = now
                previousWasUsable = true
                state = .waiting(.moving, 0)
                return
            }
        }
        if anchor == nil { anchor = features }
        if previousWasUsable, let previousObservation {
            let delta = now.timeIntervalSince(previousObservation)
            if delta <= Self.dropoutGrace { captured += delta }
        }
        candidate.observe(features)
        lastAcceptedAt = now
        previousWasUsable = true
        if captured + 0.000001 >= Self.duration && candidate.isCalibrated {
            candidate.discardSparseMeasurements()
            state = .complete
        } else {
            state = .collecting(progress)
        }
    }

    private var progress: Int { min(99, Int(captured / Self.duration * 100)) }

    private mutating func pause(_ issue: PostureCalibrationIssue, at now: Date) {
        if issue == .multiplePeople || issue == .poseRange ||
            lastAcceptedAt.map({ now.timeIntervalSince($0) > Self.dropoutGrace }) == true {
            resetCapture()
        }
        previousWasUsable = false
        state = .waiting(issue, progress)
    }

    private mutating func resetCapture() {
        candidate.reset()
        captured = 0
        lastAcceptedAt = nil
        previousWasUsable = false
        anchor = nil
    }
}
