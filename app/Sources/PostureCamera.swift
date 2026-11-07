import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// Result of one analysed camera frame.
struct PostureFrameReading {
    var outcome: PostureOutcome
    /// Highest class score in the frame, before thresholding.
    let bestScore: Double
    let preview: CGImage?
    let at: Date
    /// Which path produced `outcome`: the head on the full frame, the head on the
    /// pose-guided crop, the pose geometry, or the pose overturning a good verdict.
    var source: PostureVerdictSource = .model
    var poseAssistanceUnavailable: Bool = false
}

enum PostureCameraState: Equatable {
    case idle
    case running
    case needsPermission
    case denied
    case unavailable(String)
}

/// Owns the built-in camera, runs the bundled posture model in-process and
/// hands readings to the monitor service. Camera access is granted once to
/// Notch Triage itself, so no helper process has to ask again on every launch.
protocol PostureCameraInput: AnyObject {
    var onState: ((PostureCameraState) -> Void)? { get set }
    var onReading: ((PostureFrameReading) -> Void)? { get set }
    var onCalibration: ((PostureCalibrationState) -> Void)? { get set }
    func startCalibration()
    func cancelCalibration()
    var confidenceThreshold: Float { get set }
    /// Pose fallback: re-check frames the head cannot answer instead of giving up on them.
    var poseFallbackEnabled: Bool { get set }
    func start()
    func stop()
    func setPreviewEnabled(_ enabled: Bool)
}

final class PostureCameraController: NSObject, PostureCameraInput {
    var onState: ((PostureCameraState) -> Void)?
    var onReading: ((PostureFrameReading) -> Void)?
    var onCalibration: ((PostureCalibrationState) -> Void)?
    private var calibration = PostureCalibrationSession()
    private var calibrationID = UUID()
    private var lastCalibrationState: PostureCalibrationState = .idle

    func startCalibration() {
        let token = generation
        analysisQueue.async { [weak self] in
            guard let self, self.generation == token, self.wantsRunning,
                  self.poseFallbackEnabled, !self.calibration.state.isActive else { return }
            self.calibrationID = UUID()
            let id = self.calibrationID
            self.calibration.start(at: Date())
            self.publishCalibration(self.calibration.state, token: token)
            self.analysisQueue.asyncAfter(deadline: .now() + PostureCalibrationSession.timeout) { [weak self] in
                guard let self, self.generation == token, self.calibrationID == id,
                      self.calibration.state.isActive else { return }
                self.calibration.update(nil, bodyCount: 0, at: Date())
                self.publishCalibration(self.calibration.state, token: token)
            }
        }
    }

    func cancelCalibration() {
        let token = generation
        analysisQueue.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.calibrationID = UUID()
            self.calibration = PostureCalibrationSession()
            self.publishCalibration(self.poseTracker.hasManualBaseline ? .complete : .idle, token: token)
        }
    }

    private func publishCalibration(_ value: PostureCalibrationState, token: UUID) {
        guard lastCalibrationState != value else { return }
        lastCalibrationState = value
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.onCalibration?(value)
        }
    }

    /// Detection sensitivity, applied to the bundled model.
    var confidenceThreshold: Float = PostureDetectionDecoder.defaultConfidenceThreshold {
        didSet { classifier?.confidenceThreshold = confidenceThreshold }
    }
    /// Language stamped onto the preview overlay so its verdict chip reads in
    /// the active interface language instead of leaking the other one.
    var overlayLanguage: AppLanguage = .defaultLanguage

    /// When the head has no confident answer, ask the body pose for a second opinion.
    /// Turning this off restores the pure YOLO26 behaviour (no verdict without a box).
    var poseFallbackEnabled: Bool = true {
        didSet {
            guard oldValue != poseFallbackEnabled else { return }
            let enabled = poseFallbackEnabled
            analysisQueue.async { [weak self] in
                self?.hybridArbiter.reset()
                self?.poseTracker.resetTemporalEvidence()
                if !enabled { self?.poseEstimator.stop() }
            }
        }
    }

    private var generation = UUID()

    private let sessionQueue = DispatchQueue(label: "com.sitwell.posture.session")
    private let analysisQueue = DispatchQueue(
        label: "com.sitwell.posture.analysis",
        qos: .userInitiated
    )
    private let pipeline = PostureImagePipeline()
    private let poseEstimator = PostureMediaPipeEstimator()
    private var poseTracker = PosturePoseTracker()
    private var hybridArbiter = PostureHybridArbiter()
    private var classifier: PostureClassifier?
    private var classifierLoaded = false
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var wantsRunning = false
    private var state: PostureCameraState = .idle
    private var lastPreviewAt: Date = .distantPast
    /// Analysis-queue only. Posture changes over seconds, so ~5 analyses a second is enough.
    private var lastAnalysisAt: TimeInterval = 0
    private var previewEnabled = false
    private var activationObserver: NSObjectProtocol?

    func start() {
        generation = UUID()
        wantsRunning = true
        let token = generation
        // Model changes take effect on restart, on the same queue as inference.
        analysisQueue.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.classifier = nil
            self.classifierLoaded = false
            self.poseEstimator.stop()
            self.calibration = PostureCalibrationSession()
            self.hybridArbiter.reset()
            self.poseTracker = PosturePoseTracker()
            if let saved = PostureManualReference.load() {
                self.poseTracker.installManualBaseline(saved)
            }
            self.lastCalibrationState = .idle
            self.publishCalibration(self.poseTracker.hasManualBaseline ? .complete : .idle, token: token)
        }
        observeActivation()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            publish(.needsPermission)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.wantsRunning, self.generation == token else { return }
                    if granted {
                        self.configureAndRun()
                    } else {
                        self.publish(.denied)
                    }
                }
            }
        case .denied, .restricted:
            publish(.denied)
        @unknown default:
            publish(.denied)
        }
    }

    func stop() {
        generation = UUID()
        wantsRunning = false
        cancelCalibration()
        analysisQueue.async { [weak self] in self?.poseEstimator.stop() }
        lastPreviewAt = .distantPast
        stopObservingActivation()
        publish(.idle)
        sessionQueue.async { [weak self] in
            guard let self, let session = self.session, session.isRunning else { return }
            session.stopRunning()
        }
    }

    /// A grant made in System Settings should start detection without a relaunch.
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recheckAuthorization()
        }
    }

    private func stopObservingActivation() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    private func recheckAuthorization() {
        guard wantsRunning else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            guard state != .running else { return }
            configureAndRun()
        case .denied, .restricted:
            guard state != .denied else { return }
            publish(.denied)
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func setPreviewEnabled(_ enabled: Bool) {
        previewEnabled = enabled
        if !enabled { lastPreviewAt = .distantPast }
    }

    private func publish(_ newState: PostureCameraState, token: UUID? = nil) {
        let deliver = { [weak self] in
            guard let self, token == nil || self.generation == token, self.state != newState else { return }
            self.state = newState
            self.onState?(newState)
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }

    private func configureAndRun() {
        let token = generation
        sessionQueue.async { [weak self] in
            guard let self, self.wantsRunning, self.generation == token else { return }
            do {
                let session = try self.makeSession()
                guard self.wantsRunning, self.generation == token else {
                    session.stopRunning()
                    return
                }
                if !session.isRunning { session.startRunning() }
                guard self.wantsRunning, self.generation == token else {
                    session.stopRunning()
                    return
                }
                self.publish(session.isRunning ? .running : .unavailable("Unable to start the camera. Please retry."), token: token)
            } catch {
                self.publish(.unavailable(error.localizedDescription), token: token)
            }
        }
    }

    private func makeSession() throws -> AVCaptureSession {
        if let session, output != nil { return session }

        let device = Self.cameraDevice()
        guard let device else {
            throw PostureCameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw PostureCameraError.cannotConfigure
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw PostureCameraError.cannotConfigure
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: analysisQueue)
        session.commitConfiguration()

        Self.applyFrameRate(15, to: device)
        self.session = session
        self.output = output
        return session
    }

    private static func cameraDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? AVCaptureDevice.default(for: .video)
    }

    private static func applyFrameRate(_ fps: Int32, to device: AVCaptureDevice) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.first,
              range.maxFrameRate >= Double(fps),
              (try? device.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: fps)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    private func analyse(_ sampleBuffer: CMSampleBuffer) {
        guard wantsRunning, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 0.18 s rather than 0.2 so frame jitter at 15 fps still keeps every third frame.
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastAnalysisAt >= 0.18 else { return }
        lastAnalysisAt = uptime
        let token = generation
        if !classifierLoaded {
            classifierLoaded = true
            classifier = PostureClassifier()
            classifier?.confidenceThreshold = confidenceThreshold
            if classifier == nil {
                publish(.unavailable("The posture model is missing. Please reinstall LearnWell."))
            }
        }
        guard let classifier else { return }

        let now = Date()
        // Same jitter tolerance as the analysis throttle, so every analysed frame can refresh it.
        let wantsPreview = previewEnabled && now.timeIntervalSince(lastPreviewAt) >= 0.18
        guard let letterboxed = pipeline.letterbox(pixelBuffer) else { return }
        let summary = classifier.predictDetailed(letterboxed.buffer)
        let modelOutcome = PostureDetectionDecoder.outcome(for: summary.detections)

        var decision = PostureHybridDecision(
            outcome: modelOutcome,
            source: .model,
            bestScore: summary.bestScore,
            boxes: summary.detections.map { detection in
                (detection.label, detection.confidence,
                 letterboxed.transform.frameRect(for: detection.box))
            },
            pose: nil,
            poseState: .unknown,
            poseScore: 0
        )
        if poseFallbackEnabled {
            decision = hybridDecision(
                for: pixelBuffer,
                model: modelOutcome,
                summary: summary,
                letterboxed: letterboxed,
                classifier: classifier,
                now: now,
                token: token
            )
        }

        var preview: CGImage?
        if wantsPreview {
            lastPreviewAt = now
            if let plain = pipeline.previewImage(from: pixelBuffer) {
                // Draw the verdict onto the preview: the box plus the class and its
                // confidence, in the preview image's own pixel space.
                let scale = CGFloat(plain.width) / CGFloat(max(CVPixelBufferGetWidth(pixelBuffer), 1))
                let overlayLanguage = self.overlayLanguage
                let boxes = decision.boxes.map { label, confidence, rect in
                    PosturePreviewBox(
                        label: label,
                        confidence: confidence,
                        rect: rect.applying(CGAffineTransform(scaleX: scale, y: scale)),
                        source: decision.source,
                        language: overlayLanguage
                    )
                }
                preview = PosturePreviewOverlay.draw(
                    plain, boxes: boxes, skeleton: decision.skeleton
                ) ?? plain
            }
        }
        let reading = PostureFrameReading(
            outcome: decision.outcome,
            bestScore: decision.bestScore,
            preview: preview,
            at: now,
            source: decision.source,
            poseAssistanceUnavailable: poseFallbackEnabled && poseEstimator.lastError != nil
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsRunning, self.generation == token else { return }
            self.onReading?(reading)
        }
    }

    /// One frame through the fallback: pose-guided crop, then geometry, then the veto.
    ///
    /// The camera owns the buffer plumbing (letterboxing the crop, mapping boxes back to
    /// frame pixels); the rule itself lives in `PostureHybridPolicy`, so the off-line
    /// check exercises exactly what runs on the camera.
    private func hybridDecision(
        for pixelBuffer: CVPixelBuffer,
        model: PostureOutcome,
        summary: PosturePredictionSummary,
        letterboxed: (buffer: CVPixelBuffer, transform: PostureLetterboxTransform),
        classifier: PostureClassifier,
        now: Date,
        token: UUID
    ) -> PostureHybridDecision {
        let pose = poseEstimator.analyse(pixelBuffer)
        let wasCalibrating = calibration.state.isActive
        if wasCalibrating {
            calibration.update(pose.features, bodyCount: pose.bodyCount, at: now)
            if calibration.state == .complete {
                poseTracker.installManualBaseline(calibration.candidate)
                hybridArbiter.reset()
                PostureManualReference.save(calibration.candidate)
            }
            publishCalibration(calibration.state, token: token)
        }
        let (verdict, poseState) = poseTracker.update(pose.bodyCount == 1 ? pose.features : nil)
        let singleBody = pose.bodyCount == 1 && pose.features != nil

        var cropAnswer = PostureHybridPolicy.CropAnswer.notAttempted
        var cropBoxes: [(PostureDetection.Label, Double, CGRect)]?
        var cropTransform: PostureLetterboxTransform?
        // The locating boxes may come from a human rectangle or an expanded face when
        // the pose joints are too poor to measure; `locatedBodies` stays the gate so a
        // multi-person frame never gets silently re-framed to one person. Candidates
        // run in order until one answers, so a broad body box can be followed by a
        // tighter head-shoulder crop.
        let cropCandidates = pose.locationBoxes
        if !model.isConfirmed, pose.locatedBodies == 1 {
            for box in cropCandidates {
                guard let cropped = pipeline.letterbox(pixelBuffer, crop: Self.padded(box))
                else { continue }
                let second = classifier.predictDetailed(cropped.buffer)
                let secondOutcome = PostureDetectionDecoder.outcome(for: second.detections)
                if secondOutcome.isConfirmed {
                    cropAnswer = .answered(secondOutcome, second.bestScore)
                    cropBoxes = second.detections.map { detection in
                        (detection.label, detection.confidence,
                         cropped.transform.frameRect(for: detection.box))
                    }
                    cropTransform = cropped.transform
                    break
                }
                cropAnswer = .abstained
            }
        }

        let decision = hybridArbiter.decide(
            model: pose.locatedBodies > 1 ? .none(peopleCount: pose.locatedBodies) : model,
            singleBody: singleBody,
            poseState: poseState,
            verdict: verdict,
            crop: cropAnswer,
            features: pose.features,
            manualBaseline: poseTracker.hasManualBaseline ? poseTracker.baseline : nil,
            now: now
        )

        var boxes: [(PostureDetection.Label, Double, CGRect)]
        if decision.source == .poseCrop, let cropBoxes {
            boxes = cropBoxes
        } else if decision.source == .pose, let features = pose.features {
            boxes = [(decision.outcome.posture == .bad ? .bad : .good, decision.bestScore,
                      Self.frameRect(features.box, in: pixelBuffer))]
        } else if decision.source.isVeto {
            boxes = []
        } else {
            boxes = summary.detections.map { detection in
                (detection.label, detection.confidence,
                 letterboxed.transform.frameRect(for: detection.box))
            }
        }
        _ = cropTransform   // kept for symmetry with the crop boxes above

        var hybrid = PostureHybridDecision(
            outcome: decision.outcome,
            source: decision.source,
            bestScore: decision.bestScore,
            boxes: boxes,
            pose: pose.features,
            poseState: poseState,
            poseScore: verdict.score
        )
        // A face can establish presence even when neither the skeleton nor YOLO
        // can classify posture. Do not turn that valid frame into an away event.
        if case .none(peopleCount: 0) = hybrid.outcome, pose.locatedBodies > 0 {
            hybrid.outcome = .none(peopleCount: pose.locatedBodies)
        }
        let outcomeIsGood: Bool
        if case .good = decision.outcome { outcomeIsGood = true } else { outcomeIsGood = false }
        if !wasCalibrating {
            poseTracker.learn(pose.features, verdict: verdict, outcomeIsGood: outcomeIsGood)
        } else {
            hybrid.outcome = .none(peopleCount: pose.bodyCount)
            hybrid.bestScore = 0
            hybrid.boxes = []
        }
        if let box = pose.features?.box ?? pose.locationBox ?? pose.box {
            hybrid.skeleton = PosturePreviewSkeleton(
                joints: pose.joints,
                box: box,
                color: hybrid.outcome.posture == .unknown ? .secondaryLabelColor : (outcomeIsGood
                    ? NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
                    : NSColor(srgbRed: 0.93, green: 0.26, blue: 0.26, alpha: 1))
            )
        }
        return hybrid
    }

    /// The pose box grown to a square with padding, so the crop keeps the whole body and
    /// gives the head the framing it was trained on.
    static func padded(_ box: CGRect, padding: CGFloat = 0.18) -> CGRect {
        let side = max(box.width, box.height) * (1 + 2 * padding)
        let centre = CGPoint(x: box.midX, y: box.midY)
        var rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2,
                          width: side, height: side)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return rect
    }

    /// Normalised y-down box to frame pixels, for the preview overlay.
    static func frameRect(_ box: CGRect, in pixelBuffer: CVPixelBuffer) -> CGRect {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        return CGRect(x: box.minX * width, y: box.minY * height,
                      width: box.width * width, height: box.height * height)
    }
}

/// What one frame worked out: the verdict, which path produced it, and what to draw.
struct PostureHybridDecision {
    var outcome: PostureOutcome
    var source: PostureVerdictSource
    var bestScore: Double
    /// label, confidence, box in frame pixels.
    var boxes: [(PostureDetection.Label, Double, CGRect)]
    var pose: PosturePoseFeatures?
    var poseState: PostureState
    var poseScore: Double
    var skeleton: PosturePreviewSkeleton?
}


extension PostureCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        analyse(sampleBuffer)
    }
}

enum PostureCameraError: LocalizedError {
    case noCamera
    case cannotConfigure

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No camera is available."
        case .cannotConfigure: return "Unable to configure the camera. Close other apps using it and retry."
        }
    }
}
