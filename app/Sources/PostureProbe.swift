import AppKit
import AVFoundation
import CoreVideo
import Foundation

/// Diagnostics entry point: `INT4154PostureDetection --posture-probe [seconds]`.
/// Runs the real camera pipeline and prints what the model actually sees, so a
/// "no detection" state can be told apart from a broken frame or model input.
enum PostureProbe {
    private static var log = ""
    private static var logURL: URL {
        URL(fileURLWithPath: "/tmp/notch-posture-probe.txt")
    }

    static func note(_ text: String) {
        print(text)
        log += text + "\n"
        try? log.write(to: logURL, atomically: true, encoding: .utf8)
    }

    static func run(seconds: Double, exposure: Double? = nil) -> Int32 {
        log = ""
        if let exposure { PostureImagePipeline.exposureAdjustment = exposure }
        return runProbe(seconds: seconds)
    }

    /// Captures one raw camera frame for offline comparison with the Python pipeline.
    static func capture(path: String) -> Int32 {
        log = ""
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            note("capture: camera permission not granted")
            return 3
        }
        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first ?? AVCaptureDevice.default(for: .video) else {
            note("capture: no camera")
            return 4
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            note("capture: cannot add input")
            return 4
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { return 4 }
        session.addOutput(output)
        session.commitConfiguration()
        let queue = DispatchQueue(label: "com.sitwell.posture.capture")
        let saver = FrameSaver(url: URL(fileURLWithPath: path), classifier: PostureClassifier(), pipeline: PostureImagePipeline())
        output.setSampleBufferDelegate(saver, queue: queue)
        session.startRunning()
        saver.wait()
        session.stopRunning()
        note("capture: wrote \(path) after \(saver.frames) frames")
        if let overlay = saver.overlayPath {
            note("capture: wrote \(overlay) (same frame with the detector's box)")
        }
        return saver.saved ? 0 : 1
    }

    private final class FrameSaver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let url: URL
        private let classifier: PostureClassifier?
        private let pipeline: PostureImagePipeline?
        private let context = CIContext()
        private let done = DispatchSemaphore(value: 0)
        private(set) var frames = 0
        private(set) var saved = false
        private(set) var overlayPath: String?

        init(url: URL, classifier: PostureClassifier?, pipeline: PostureImagePipeline?) {
            self.url = url
            self.classifier = classifier
            self.pipeline = pipeline
        }

        func wait() { _ = done.wait(timeout: .now() + 20) }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            frames += 1
            // Skip the first few frames while exposure settles.
            guard frames == 8 else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                done.signal()
                return
            }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = context.createCGImage(image, from: image.extent) else {
                done.signal()
                return
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                saved = true
            }
            // Same frame run through the app's own pipeline, with the box drawn on
            // it: proves the overlay and the letterbox mapping agree.
            if let classifier, let pipeline, let letterboxed = pipeline.letterbox(pixelBuffer) {
                let summary = classifier.predictDetailed(letterboxed.buffer)
                let boxes = summary.detections.map { detection in
                    PosturePreviewBox(
                        label: detection.label,
                        confidence: detection.confidence,
                        rect: letterboxed.transform.frameRect(for: detection.box)
                    )
                }
                if let annotated = PosturePreviewOverlay.draw(cgImage, boxes: boxes),
                   let data = NSBitmapImageRep(cgImage: annotated)
                    .representation(using: .png, properties: [:]) {
                    let target = url.deletingPathExtension().appendingPathExtension("overlay.png")
                    if (try? data.write(to: target)) != nil {
                        overlayPath = target.path
                    }
                }
            }
            done.signal()
        }
    }

    private static func runProbe(seconds: Double) -> Int32 {
        guard let classifier = PostureClassifier() else {
            note("probe: model unavailable")
            return 1
        }
        let sensitivity = PostureSensitivity(
            rawValue: UserDefaults.standard.string(forKey: "notch.postureSensitivity") ?? ""
        ) ?? .defaultSensitivity
        classifier.confidenceThreshold = sensitivity.threshold
        note("probe: sensitivity \(sensitivity.rawValue) (threshold \(sensitivity.threshold))")
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            note("probe: camera permission not granted yet")
            return 3
        case .denied, .restricted:
            note("probe: camera permission denied")
            return 3
        @unknown default:
            return 3
        }
        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first ?? AVCaptureDevice.default(for: .video) else {
            note("probe: no camera")
            return 4
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            note("probe: cannot add camera input")
            return 4
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        guard session.canAddOutput(output) else {
            note("probe: cannot add video output")
            return 4
        }
        session.addOutput(output)
        session.commitConfiguration()

        let pipeline = PostureImagePipeline()
        let queue = DispatchQueue(label: "com.sitwell.posture.probe")
        let collector = Collector(classifier: classifier, pipeline: pipeline, seconds: seconds)
        output.setSampleBufferDelegate(collector, queue: queue)
        session.startRunning()
        collector.wait()
        session.stopRunning()
        collector.report(sensitivity: sensitivity)
        return collector.bestScore >= Double(PostureDetectionDecoder.defaultConfidenceThreshold)
            || !collector.detectionCounts.isEmpty ? 0 : 5
    }

    private final class Collector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let classifier: PostureClassifier
        private let pipeline: PostureImagePipeline
        private let deadline: Date
        private let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()

        private(set) var frames = 0
        private(set) var analysed = 0
        private(set) var bestScore = 0.0
        private(set) var detectionCounts: [Int] = []
        private(set) var outcomes: [PostureOutcome] = []
        private(set) var classScores: [(bad: Double, good: Double)] = []
        private(set) var boxHeights: [CGFloat] = []
        private var letterboxMeans: [Double] = []
        private var boxSizes: [CGRect] = []
        /// Which path produced each frame's verdict: model, pose crop, geometry or veto.
        private var sources: [PostureVerdictSource] = []
        private var poseStates: [PostureState] = []
        private var poseEstimator = PosturePoseEstimator()
        private var poseTracker = PosturePoseTracker()
        private var hybridArbiter = PostureHybridArbiter()

        init(classifier: PostureClassifier, pipeline: PostureImagePipeline, seconds: Double) {
            self.classifier = classifier
            self.pipeline = pipeline
            self.deadline = Date().addingTimeInterval(seconds)
            if let saved = PostureManualReference.load() { poseTracker.installManualBaseline(saved) }
        }

        func wait() { _ = finished.wait(timeout: .now() + 30) }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard Date() < deadline else {
                finished.signal()
                return
            }
            frames += 1
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let letterboxed = pipeline.letterbox(pixelBuffer) else { return }
            let summary = classifier.predictDetailed(letterboxed.buffer)
            let modelOutcome = PostureDetectionDecoder.outcome(for: summary.detections)

            // Exercise the same fallback the camera runs, so the probe reports how many
            // frames it rescued rather than only what the head made of the frame.
            let pose = poseEstimator.analyse(pixelBuffer)
            let (poseVerdict, poseState) = poseTracker.update(pose.bodyCount == 1 ? pose.features : nil)
            var cropAnswer = PostureHybridPolicy.CropAnswer.notAttempted
            if !modelOutcome.isConfirmed, pose.locatedBodies == 1 {
                let candidates = pose.locationBoxes
                for box in candidates {
                    let side = max(box.width, box.height) * 1.36
                    let crop = CGRect(x: box.midX - side / 2, y: box.midY - side / 2,
                                      width: side, height: side)
                        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    guard let cropped = pipeline.letterbox(pixelBuffer, crop: crop) else { continue }
                    let second = classifier.predictDetailed(cropped.buffer)
                    let secondOutcome = PostureDetectionDecoder.outcome(for: second.detections)
                    if secondOutcome.isConfirmed {
                        cropAnswer = .answered(secondOutcome, second.bestScore)
                        break
                    }
                    cropAnswer = .abstained
                }
            }
            let decision = hybridArbiter.decide(
                model: modelOutcome,
                singleBody: pose.bodyCount == 1 && pose.features != nil,
                poseState: poseState,
                verdict: poseVerdict,
                crop: cropAnswer,
                features: pose.features,
                manualBaseline: poseTracker.hasManualBaseline ? poseTracker.baseline : nil,
                now: Date()
            )
            let outcomeIsGood: Bool = { if case .good = decision.outcome { return true }; return false }()
            poseTracker.learn(pose.features, verdict: poseVerdict, outcomeIsGood: outcomeIsGood)

            lock.lock()
            analysed += 1
            sources.append(decision.source)
            poseStates.append(poseVerdict.state)
            bestScore = max(bestScore, summary.bestScore)
            classScores.append((bad: summary.bestBad, good: summary.bestGood))
            outcomes.append(decision.outcome)
            if let best = summary.detections.first {
                boxHeights.append(best.box.height)
            }
            if !summary.detections.isEmpty {
                detectionCounts.append(summary.detections.count)
                boxSizes.append(contentsOf: summary.detections.map { $0.box })
            }
            if letterboxMeans.count < 3 {
                letterboxMeans.append(mean(of: letterboxed.buffer))
            }
            lock.unlock()
            if analysed % 10 == 0 {
                note(String(format: "probe: frame %d, detections %d, bad %.3f good %.3f, %@",
                             analysed, summary.detections.count,
                             summary.bestBad, summary.bestGood,
                             summary.detections.first.map { $0.label == .bad ? "BAD" : "GOOD" } ?? "-"))
            }
        }

        func report(sensitivity: PostureSensitivity) {
            note("probe: frames \(frames), analysed \(analysed)")
            note(String(format: "probe: best score over run %.3f (threshold %.2f)",
                         bestScore, Double(sensitivity.threshold)))
            note("probe: letterbox mean brightness \(letterboxMeans.map { String(format: "%.1f", $0) })")
            let verdicts = outcomes.reduce(into: [String: Int]()) { counts, outcome in
                counts[outcome.posture.rawValue, default: 0] += 1
            }
            note("probe: verdicts \(verdicts)")
            let bySource = sources.reduce(into: [String: Int]()) { counts, source in
                counts[source.rawValue, default: 0] += 1
            }
            let poseTally = poseStates.reduce(into: [String: Int]()) { counts, state in
                counts[state.rawValue, default: 0] += 1
            }
            note("probe: verdict sources \(bySource)")
            note("probe: pose readings \(poseTally) | pose reference calibrated \(poseTracker.isCalibrated) (\(poseTracker.baseline.samples) frames)")
            if !classScores.isEmpty {
                let meanBad = classScores.map(\.bad).reduce(0, +) / Double(classScores.count)
                let meanGood = classScores.map(\.good).reduce(0, +) / Double(classScores.count)
                let margins = classScores.map { abs($0.bad - $0.good) }
                let meanMargin = margins.reduce(0, +) / Double(margins.count)
                note(String(format: "probe: mean class scores bad %.3f good %.3f | mean margin %.3f | decisive frames (margin>0.2) %d/%d",
                             meanBad, meanGood, meanMargin,
                             margins.filter { $0 > 0.2 }.count, margins.count))
            }
            if !boxHeights.isEmpty {
                let meanHeight = boxHeights.reduce(0, +) / CGFloat(boxHeights.count)
                note(String(format: "probe: mean box height %.1f%% of the model canvas (a seated torso usually fills >30%%)",
                             Double(meanHeight) * 100))
            }
            if detectionCounts.isEmpty {
                note("probe: no detection passed the threshold")
            } else {
                let histogram = Dictionary(grouping: detectionCounts, by: { $0 }).mapValues { $0.count }
                note("probe: detections per frame \(histogram)")
                for box in boxSizes.prefix(5) {
                    note(String(format: "probe:  box x %.2f y %.2f w %.2f h %.2f",
                                 box.minX, box.minY, box.width, box.height))
                }
            }
        }

        private func mean(of buffer: CVPixelBuffer) -> Double {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let width = CVPixelBufferGetWidth(buffer)
            let pointer = base.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            var total = 0.0
            var count = 0
            for y in stride(from: 0, to: height, by: 32) {
                for x in stride(from: 0, to: width, by: 32) {
                    let offset = y * bytesPerRow + x * 4
                    total += Double(pointer[offset]) + Double(pointer[offset + 1]) + Double(pointer[offset + 2])
                    count += 3
                }
            }
            return count > 0 ? total / Double(count) : -1
        }
    }
}
