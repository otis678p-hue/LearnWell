import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import OSLog

/// A single posture detection decoded from the YOLO26 head.
struct PostureDetection: Equatable {
    /// Class ids in the order the shipped weights use: 0 = Bad, 1 = Good.
    enum Label: Int, Equatable, Sendable {
        case bad = 0
        case good = 1
    }

    let label: Label
    let confidence: Double
    /// Centre-based box in the 640 × 640 letterboxed model input.
    let box: CGRect
}

enum PostureOutcome: Equatable, Sendable {
    case good(Double)
    case bad(Double)
    case none(peopleCount: Int)

    var posture: PostureState {
        switch self {
        case .good: return .good
        case .bad: return .bad
        case .none: return .unknown
        }
    }

    var confidence: Double? {
        switch self {
        case .good(let value), .bad(let value): return value
        case .none: return nil
        }
    }

    var peopleCount: Int {
        switch self {
        case .good, .bad: return 1
        case .none(let count): return count
        }
    }

    /// Exactly one confident posture, matching the detector's original rule.
    var isConfirmed: Bool {
        switch self {
        case .good, .bad: return true
        case .none: return false
        }
    }

}

/// Pure decode + NMS for the exported model head: rows of (cx, cy, w, h, bad, good).
///
/// YOLO26 is anchor-free and has no objectness channel, so each anchor carries the
/// two class scores already sigmoid-applied inside the exported graph; the larger
/// one is the detection score. Boxes are centre-form pixels of the 640 × 640 input.
enum PostureDetectionDecoder {
    /// Standard sensitivity. The YOLO26 weights score confident in-domain frames
    /// higher than the old YOLOv5 head, so 0.50 keeps the same alert behaviour.
    static let defaultConfidenceThreshold: Float = 0.50
    static let iouThreshold: Float = 0.50
    static let maxDetections = 10
    static let columns = 6
    static let modelWidth: Float = 640
    static let modelHeight: Float = 640
    /// Anchors below this score are ignored when counting candidates for diagnostics.
    static let scoredAnchorFloor: Float = 0.01

    static func outcome(for detections: [PostureDetection]) -> PostureOutcome {
        guard detections.count == 1, let detection = detections.first else {
            return .none(peopleCount: detections.count)
        }
        switch detection.label {
        case .good: return .good(detection.confidence)
        case .bad: return .bad(detection.confidence)
        }
    }

    /// rows is row-major with `columns` floats per anchor.
    static func decode(rows: [Float], threshold: Float = defaultConfidenceThreshold) -> [PostureDetection] {
        guard rows.count >= columns else { return [] }
        var candidates: [PostureDetection] = []
        var index = 0
        while index + columns <= rows.count {
            if let detection = detection(
                anchor: PostureAnchor(
                    cx: rows[index],
                    cy: rows[index + 1],
                    width: rows[index + 2],
                    height: rows[index + 3],
                    bad: rows[index + 4],
                    good: rows[index + 5]
                ),
                threshold: threshold
            ) {
                candidates.append(detection)
            }
            index += columns
        }
        return nonMaximumSuppression(candidates)
    }

    /// Decodes the head straight out of CoreML, keeping the strides CoreML reports.
    static func summarize(
        _ tensor: PostureHeadTensor,
        threshold: Float = defaultConfidenceThreshold
    ) -> PosturePredictionSummary {
        var candidates: [PostureDetection] = []
        var best = 0.0
        var scored = 0
        var bestBad = 0.0
        var bestGood = 0.0
        for index in 0..<tensor.anchors {
            let anchor = tensor.anchor(index)
            let score = max(anchor.bad, anchor.good)
            guard score > 0 else { continue }
            if score >= scoredAnchorFloor { scored += 1 }
            if Double(score) > best {
                best = Double(score)
                bestBad = Double(anchor.bad)
                bestGood = Double(anchor.good)
            }
            guard score >= threshold, let detection = detection(anchor: anchor, threshold: threshold) else {
                continue
            }
            candidates.append(detection)
        }
        return PosturePredictionSummary(
            detections: nonMaximumSuppression(candidates),
            bestScore: best,
            scoredAnchors: scored,
            bestBad: bestBad,
            bestGood: bestGood
        )
    }

    static func detection(anchor: PostureAnchor, threshold: Float) -> PostureDetection? {
        let score = max(anchor.bad, anchor.good)
        guard score >= threshold, score > 0,
              anchor.width > 0, anchor.height > 0,
              anchor.cx.isFinite, anchor.cy.isFinite,
              anchor.width.isFinite, anchor.height.isFinite else { return nil }
        // The head reports centre-form boxes; everything downstream (letterbox
        // mapping, preview overlay) expects a top-left origin.
        let width = CGFloat(anchor.width) / CGFloat(modelWidth)
        let height = CGFloat(anchor.height) / CGFloat(modelHeight)
        return PostureDetection(
            label: anchor.good >= anchor.bad ? .good : .bad,
            confidence: Double(score),
            box: CGRect(
                x: CGFloat(anchor.cx) / CGFloat(modelWidth) - width / 2,
                y: CGFloat(anchor.cy) / CGFloat(modelHeight) - height / 2,
                width: width,
                height: height
            )
        )
    }

    static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard union > 0 else { return 0 }
        return intersectionArea / union
    }

    /// Class-aware NMS with the detector's original IoU threshold. YOLO26 hands the
    /// head over without suppression, so duplicate anchors still need removing.
    static func nonMaximumSuppression(_ detections: [PostureDetection]) -> [PostureDetection] {
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var kept: [PostureDetection] = []
        for candidate in sorted where kept.count < maxDetections {
            let overlaps = kept.contains { existing in
                existing.label == candidate.label
                    && intersectionOverUnion(existing.box, candidate.box) > CGFloat(iouThreshold)
            }
            if !overlaps { kept.append(candidate) }
        }
        return kept
    }
}

/// One decoded anchor row of the YOLO26 head.
struct PostureAnchor: Equatable {
    let cx: Float
    let cy: Float
    let width: Float
    let height: Float
    let bad: Float
    let good: Float
}

/// Result of one pass over the head.
struct PosturePredictionSummary {
    let detections: [PostureDetection]
    /// Best class score over all anchors, before thresholding.
    let bestScore: Double
    let scoredAnchors: Int
    /// Both class scores at the most confident anchor, for diagnostics: how far
    /// apart Good and Bad are is the only way to tell a verdict from a coin flip.
    let bestBad: Double
    let bestGood: Double

    static let empty = PosturePredictionSummary(
        detections: [], bestScore: 0, scoredAnchors: 0, bestBad: 0, bestGood: 0
    )
}

/// Stride-aware reader for the exported head.
///
/// Ultralytics exports the YOLO26 head as `[1, 6, 8400]` (channels first:
/// cx, cy, w, h, bad, good) and CoreML may pad that buffer, so every value is
/// gathered with the strides the model reports. A row-major `[1, 8400, 6]` head
/// is read too, in case the export layout changes.
struct PostureHeadTensor {
    let anchors: Int
    private let base: Int
    private let anchorStride: Int
    private let channelStride: Int
    private let array: MLMultiArray
    private let float32: UnsafeMutablePointer<Float>?
    private let float16: UnsafeMutablePointer<Float16>?

    init?(array: MLMultiArray) {
        let shape = array.shape.map { $0.intValue }
        let strides = array.strides.map { $0.intValue }
        guard shape.count >= 2, strides.count >= 2 else { return nil }
        let channels = PostureDetectionDecoder.columns
        let last = shape[shape.count - 1]
        let secondLast = shape[shape.count - 2]
        if secondLast == channels, last > 0 {
            // [1, 6, 8400]: channels first, anchors last.
            anchors = last
            channelStride = strides[strides.count - 2]
            anchorStride = strides[strides.count - 1]
        } else if last == channels, secondLast > 0 {
            // [1, 8400, 6]: one row of channels per anchor.
            anchors = secondLast
            channelStride = strides[strides.count - 1]
            anchorStride = strides[strides.count - 2]
        } else {
            return nil
        }
        self.array = array
        base = 0
        // Read straight from memory for the two layouts CoreML actually ships
        // instead of boxing 50k numbers per frame.
        float32 = array.dataType == .float32
            ? array.dataPointer.bindMemory(to: Float.self, capacity: 1)
            : nil
        float16 = array.dataType == .float16
            ? array.dataPointer.bindMemory(to: Float16.self, capacity: 1)
            : nil
    }

    func anchor(_ index: Int) -> PostureAnchor {
        let offset = base + index * anchorStride
        func value(_ channel: Int) -> Float {
            let position = offset + channel * channelStride
            if let float32 { return float32[position] }
            if let float16 { return Float(float16[position]) }
            return array[position].floatValue
        }
        return PostureAnchor(
            cx: value(0),
            cy: value(1),
            width: value(2),
            height: value(3),
            bad: value(4),
            good: value(5)
        )
    }
}

/// Maps the letterboxed model space back onto the camera frame.
struct PostureLetterboxTransform: Equatable {
    let scale: CGFloat
    let offset: CGPoint
    let modelWidth: CGFloat
    let modelHeight: CGFloat
    /// Top-left of the source region in frame pixels. Zero for a whole-frame pass; the
    /// crop retry sets it so boxes map back onto the camera frame, not the crop.
    var origin: CGPoint = .zero

    /// Converts a detection box into the camera frame's pixel coordinates.
    func frameRect(for box: CGRect) -> CGRect {
        guard scale > 0 else { return box }
        let x = (box.minX * modelWidth - offset.x) / scale + origin.x
        let y = (box.minY * modelHeight - offset.y) / scale + origin.y
        let width = box.width * modelWidth / scale
        let height = box.height * modelHeight / scale
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

final class PostureClassifier {
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let log = Logger(subsystem: "com.hyacinth.notchtriage", category: "posture")
    /// Detection sensitivity; standard is 0.50 (see `PostureSensitivity`).
    var confidenceThreshold: Float = PostureDetectionDecoder.defaultConfidenceThreshold

    convenience init?(bundle: Bundle = .main) {
        if let path = UserDefaults.standard.string(forKey: "notch.posture.customModel"),
           FileManager.default.fileExists(atPath: path),
           let custom = Self(url: URL(fileURLWithPath: path)) {
            self.init(model: custom.model, inputName: custom.inputName, outputName: custom.outputName)
            return
        }
        guard let url = Self.modelURL(in: bundle) else { return nil }
        self.init(url: url)
    }

    private init(model: MLModel, inputName: String, outputName: String) {
        self.model = model
        self.inputName = inputName
        self.outputName = outputName
    }

    /// Loads a compiled `.mlmodelc` or a `.mlpackage` from disk; used by the
    /// bundle loader above and by `tools/posture_model_check.swift`.
    init?(url: URL) {
        let resolved: URL
        if url.pathExtension == "mlpackage" {
            guard let compiled = try? MLModel.compileModel(at: url) else { return nil }
            resolved = compiled
        } else {
            resolved = url
        }
        guard let loaded = try? MLModel(contentsOf: resolved) else { return nil }
        model = loaded
        guard let input = loaded.modelDescription.inputDescriptionsByName.first,
              let output = loaded.modelDescription.outputDescriptionsByName.first else {
            return nil
        }
        inputName = input.key
        outputName = output.key
        // Printed once at startup: the quickest way to tell which model a bundle runs.
        let description = loaded.modelDescription.metadata[MLModelMetadataKey.description] as? String ?? "no description"
        let size = input.value.imageConstraint.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "?"
        log.notice("posture model: \(description, privacy: .public) | input \(size, privacy: .public) | output \(self.outputName, privacy: .public)")
    }

    /// The model ships precompiled; a .mlpackage fallback keeps development builds working.
    private static func modelURL(in bundle: Bundle) -> URL? {
        if let compiled = bundle.url(forResource: "PostureYOLO", withExtension: "mlmodelc") {
            return compiled
        }
        guard let package = bundle.url(forResource: "PostureYOLO", withExtension: "mlpackage"),
              let compiled = try? MLModel.compileModel(at: package) else { return nil }
        return compiled
    }

    typealias PredictionSummary = PosturePredictionSummary

    func predict(_ pixelBuffer: CVPixelBuffer) -> [PostureDetection] {
        predictDetailed(pixelBuffer).detections
    }

    func predictDetailed(_ pixelBuffer: CVPixelBuffer) -> PredictionSummary {
        let provider: MLDictionaryFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)]
            )
        } catch {
            return .empty
        }
        guard let output = try? model.prediction(from: provider),
              let array = output.featureValue(for: outputName)?.multiArrayValue,
              let tensor = PostureHeadTensor(array: array) else {
            return .empty
        }
        return PostureDetectionDecoder.summarize(tensor, threshold: confidenceThreshold)
    }

}

/// Letterboxes camera frames into the model's square input and renders previews.
final class PostureImagePipeline {
    /// Optional exposure lift for dim rooms; 0 keeps the reference behaviour.
    static var exposureAdjustment: Double? = ProcessInfo.processInfo.environment["POSTURE_EV"]
        .flatMap(Double.init)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    /// YOLO26 was trained on square 640 x 640 letterboxed tiles, so camera frames
    /// are padded onto the same canvas (grey 114, like ultralytics LetterBox). The
    /// old 640 x 384 rectangle belonged to the YOLOv5 viewer and no longer applies.
    private let modelWidth = 640
    private let modelHeight = 640

    func letterbox(_ source: CVPixelBuffer) -> (buffer: CVPixelBuffer, transform: PostureLetterboxTransform)? {
        let width = CGFloat(CVPixelBufferGetWidth(source))
        let height = CGFloat(CVPixelBufferGetHeight(source))
        guard width > 0, height > 0 else { return nil }
        let scale = min(CGFloat(modelWidth) / width, CGFloat(modelHeight) / height)
        let drawWidth = width * scale
        let drawHeight = height * scale
        let offset = CGPoint(
            x: (CGFloat(modelWidth) - drawWidth) / 2,
            y: (CGFloat(modelHeight) - drawHeight) / 2
        )
        guard let destination = makeBuffer() else { return nil }
        let gray = CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255)
        let bounds = CGRect(x: 0, y: 0, width: modelWidth, height: modelHeight)
        var image = CIImage(cvPixelBuffer: source)
        if let ev = Self.exposureAdjustment, ev != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        }
        image = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
            .composited(over: CIImage(color: gray).cropped(to: bounds))
        context.render(
            image,
            to: destination,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (
            destination,
            PostureLetterboxTransform(
                scale: scale,
                offset: offset,
                modelWidth: CGFloat(modelWidth),
                modelHeight: CGFloat(modelHeight)
            )
        )
    }

    /// Letterboxes one rectangular region of the frame onto the model canvas.
    ///
    /// This is the second half of the pose fallback: once Vision has located the person,
    /// the YOLO26 head is asked again about just that region, enlarged. The full-frame
    /// pass fails on small or badly framed people precisely because the subject is tiny;
    /// a crop restores both the apparent size and the plain RGB context the weights were
    /// trained on. `crop` is normalised with a top-left origin, like the preview.
    func letterbox(
        _ source: CVPixelBuffer,
        crop: CGRect
    ) -> (buffer: CVPixelBuffer, transform: PostureLetterboxTransform)? {
        let width = CGFloat(CVPixelBufferGetWidth(source))
        let height = CGFloat(CVPixelBufferGetHeight(source))
        guard width > 0, height > 0 else { return nil }

        let clamped = crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0.02, clamped.height > 0.02 else { return nil }

        // CIImage works bottom-left; the crop arrives top-left.
        let sourceExtent = CGRect(
            x: clamped.minX * width,
            y: (1 - clamped.maxY) * height,
            width: clamped.width * width,
            height: clamped.height * height
        ).integral
        guard sourceExtent.width >= 2, sourceExtent.height >= 2 else { return nil }

        let scale = min(CGFloat(modelWidth) / sourceExtent.width,
                        CGFloat(modelHeight) / sourceExtent.height)
        let drawWidth = sourceExtent.width * scale
        let drawHeight = sourceExtent.height * scale
        let offset = CGPoint(
            x: (CGFloat(modelWidth) - drawWidth) / 2,
            y: (CGFloat(modelHeight) - drawHeight) / 2
        )
        guard let destination = makeBuffer() else { return nil }
        let gray = CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255)
        let bounds = CGRect(x: 0, y: 0, width: modelWidth, height: modelHeight)
        var image = CIImage(cvPixelBuffer: source)
        if let ev = Self.exposureAdjustment, ev != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        }
        image = image
            .cropped(to: sourceExtent)
            .transformed(by: CGAffineTransform(translationX: -sourceExtent.minX,
                                               y: -sourceExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
            .composited(over: CIImage(color: gray).cropped(to: bounds))
        context.render(
            image,
            to: destination,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (
            destination,
            PostureLetterboxTransform(
                scale: scale,
                offset: offset,
                modelWidth: CGFloat(modelWidth),
                modelHeight: CGFloat(modelHeight),
                origin: CGPoint(x: sourceExtent.minX, y: height - sourceExtent.maxY)
            )
        )
    }

    func previewImage(from source: CVPixelBuffer, maxWidth: CGFloat = 720) -> CGImage? {
        let width = CGFloat(CVPixelBufferGetWidth(source))
        guard width > 0 else { return nil }
        let scale = min(1, maxWidth / width)
        let image = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = image.extent.integral
        guard !extent.isEmpty else { return nil }
        return context.createCGImage(image, from: extent)
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: modelWidth,
                kCVPixelBufferHeightKey: modelHeight,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
            ]
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                attributes as CFDictionary,
                &pool
            )
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }
}