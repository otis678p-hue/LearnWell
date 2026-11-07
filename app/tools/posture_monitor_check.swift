import AppKit
import Foundation

final class FakeCamera: PostureCameraInput {
    var onState: ((PostureCameraState) -> Void)?
    var onReading: ((PostureFrameReading) -> Void)?
    var confidenceThreshold: Float = 0.5
    var poseFallbackEnabled = true
    var onCalibration: ((PostureCalibrationState) -> Void)?
    var calibrations = 0
    func startCalibration() { calibrations += 1; onCalibration?(.preparing(3)) }
    func cancelCalibration() { onCalibration?(.idle) }
    var starts = 0
    var stops = 0
    var previewEnabled = false
    func start() { starts += 1; onState?(.running) }
    func stop() { stops += 1 }
    func setPreviewEnabled(_ enabled: Bool) { previewEnabled = enabled }
}
@MainActor final class FakeBlur: PostureBlurPresenting {
    var intensity: Double = 0
    func update(intensity: Double) { self.intensity = intensity }
    func clear() { intensity = 0 }
}
final class TestClock { var now = Date(timeIntervalSince1970: 1_800_000_000) }


final class FakeArduino: PostureArduinoInput {
    var onState: ((PostureArduinoLink.State) -> Void)?
    var onTelemetry: ((PostureSerialTelemetry) -> Void)?
    var onEnvironment: ((PostureEnvironmentTelemetry) -> Void)?
    var onBoardRemembered: ((PostureSerialBoard) -> Void)?
    var signal: PostureArduinoSignal = .pending
    func start(enabled: Bool) { onState?(enabled ? .connected : .disabled) }
    func stop() { onState?(.disabled) }
    func notify(_ signal: PostureArduinoSignal) { self.signal = signal }
}

@main enum PostureMonitorCheck {
    @MainActor static func main() throws {
        guard let domain = Bundle.main.bundleIdentifier, domain.hasPrefix("com.posture.monitor-check.") else {
            fatalError("Run through run_posture_monitor_check.sh for isolated preferences")
        }
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        // Resizing must survive relaunch and keep window and hit-test geometry aligned.
        precondition(PosturePreviewSizing.load() == 220)
        precondition(PosturePreviewSizing.normalized(.nan) == 220)
        precondition(PosturePreviewSizing.normalized(30) == 120)
        precondition(PosturePreviewSizing.normalized(900) == 360)
        let previewModel = AppModel()
        precondition(previewModel.posturePreviewFullFrame)
        previewModel.setPosturePreviewHeight(300)
        previewModel.posturePreviewFullFrame = false
        let restoredPreview = AppModel()
        precondition(restoredPreview.posturePreviewHeight == 300 && !restoredPreview.posturePreviewFullFrame)
        restoredPreview.resetPosturePreviewSize()
        precondition(PosturePreviewSizing.load() == 220)
        precondition(PosturePreviewSizing.expandedHeight(previewHeight: 360,
            environmentVisible: true, availableHeight: 600) == 600,
            "Large previews respect available screen height")
        let resizedGeometry = NotchLayout.geometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            menuBarHeight: 37, phase: .workspace, expandedContentHeight: 600)
        precondition(resizedGeometry.windowFrame.height == 690)
        precondition(resizedGeometry.windowFrame.maxY == 982)
        precondition(resizedGeometry.visibleSurfaceFrame.height == 690)
        precondition(resizedGeometry.visibleSurfaceFrame.minY == resizedGeometry.windowFrame.minY,
            "The expanded hit-test region follows the resized window")
        precondition(NotchLayout.geometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            menuBarHeight: 37, phase: .compact, expandedContentHeight: 600).windowFrame.height == 37,
            "Preview sizing cannot enlarge the collapsed notch")
        defaults.removeObject(forKey: PosturePreviewSizing.heightKey)
        defaults.removeObject(forKey: PosturePreviewSizing.fullFrameKey)
        print("PASS: preview size limits, persistence, reset, screen bounds and expanded/compact geometry")
        // Retired choices must not prevent camera startup or retain calibration.
        defaults.set("airPods", forKey: "notch.posture.trackingMethod")
        defaults.set(Data([1, 2, 3]), forKey: "notch.posture.calibration.airPods")
        defaults.set(Data([1, 2, 3]), forKey: "notch.posture.pose2D.baseline.v1")
        defaults.set(true, forKey: "notch.posture.pose2D.wizardIntroduced.v1")
        defaults.set(false, forKey: PostureArduinoLink.enabledPreferenceKey)
        defaults.set(true, forKey: PostureMonitorService.blurEnabledKey)
        defaults.set(true, forKey: PostureMonitorService.goodAlertsPreferenceKey)
        let camera = FakeCamera(), blur = FakeBlur(), time = TestClock()
        let board = FakeArduino()
        var alerts: [PostureAlert] = []
        var snapshot = PostureSnapshot.offline
        let service = PostureMonitorService(onSnapshot: { snapshot = $0 }, onPreview: { _ in },
            onState: { _ in }, onAlert: { alerts.append($0) },
            camera: camera, blur: blur, arduino: board, clock: { time.now })
        defer { service.stop() }
        func frame(_ outcome: PostureOutcome) {
            time.now.addTimeInterval(0.11)
            camera.onReading?(.init(outcome: outcome, bestScore: outcome.confidence ?? 0, preview: nil, at: time.now))
        }
        service.start(enabled: true)
        precondition(camera.starts == 1)
        precondition(snapshot.posture == .unknown && board.signal == .pending, "Startup is unknown")
        precondition(defaults.object(forKey: "notch.posture.trackingMethod") == nil)
        precondition(defaults.object(forKey: "notch.posture.calibration.airPods") == nil)
        precondition(defaults.object(forKey: "notch.posture.pose2D.baseline.v1") == nil)
        precondition(defaults.object(forKey: "notch.posture.pose2D.wizardIntroduced.v1") == nil)
        service.startCalibration()
        precondition(camera.calibrations == 1 && service.calibrationState.isActive)
        for _ in 0..<40 { frame(.bad(0.9)) }
        for _ in 0..<40 { frame(.good(0.9)) }
        service.refreshReadings()
        precondition(snapshot.posture == .unknown && blur.intensity == 0 && alerts.isEmpty,
                     "Calibration suppresses camera warnings and positive confirmations")
        service.cancelCalibration()
        precondition(!service.calibrationState.isActive)
        service.setPoseFallbackEnabled(false)
        service.startCalibration()
        precondition(camera.calibrations == 1, "Calibration requires the pose fallback")
        service.setPoseFallbackEnabled(true)
        service.startCalibration()
        service.setPoseFallbackEnabled(false)
        precondition(!service.calibrationState.isActive, "Disabling the fallback cancels capture")
        service.setPoseFallbackEnabled(true)
        frame(.none(peopleCount: 0))
        service.refreshReadings()
        precondition(snapshot.posture == .unknown && !snapshot.confirmed && snapshot.source == nil && blur.intensity == 0)
        precondition(snapshot.title == "Unknown posture" && board.signal == .pending && alerts.isEmpty)
        // An arbitrated conflict is neutral and gets an explicit explanation.
        time.now.addTimeInterval(0.11)
        camera.onReading?(.init(outcome: .none(peopleCount: 1), bestScore: 0.95,
            preview: nil, at: time.now, source: .poseConflict))
        service.refreshReadings()
        precondition(snapshot.poseConflict && snapshot.posture == .unknown && !snapshot.confirmed)
        precondition(snapshot.detail == .message("Model and pose disagree; posture is temporarily unknown"))
        precondition(board.signal == .pending && blur.intensity == 0 && alerts.isEmpty,
                     "A conflict sends neither bad-posture warnings nor positive confirmations")
        time.now.addTimeInterval(4)
        service.refreshReadings()
        precondition(!snapshot.poseConflict, "A stale frame cannot retain the conflict explanation")
        // ~4.4 s of bad frames: past the 3 s reminder delay.
        for _ in 0..<40 { frame(.bad(0.9)) }
        precondition(snapshot.confirmed && snapshot.posture == .bad && snapshot.source == .camera)
        precondition(blur.intensity > 0)
        frame(.good(0.9))
        precondition(blur.intensity > 0, "A single good frame does not flicker the warning off")
        for _ in 0..<6 { frame(.good(0.9)) }
        service.refreshReadings()
        precondition(snapshot.posture == .good)
        precondition(board.signal == .good && alerts.contains { $0.kind == .good })
        let positiveAlerts = alerts.filter { $0.kind == .good }.count
        frame(.none(peopleCount: 2))
        service.refreshReadings()
        precondition(snapshot.isRunning && snapshot.posture == .unknown && !snapshot.confirmed)
        precondition(snapshot.peopleCount == 2 && snapshot.confidence == nil && snapshot.source == nil)
        precondition(board.signal == .pending && alerts.filter { $0.kind == .good }.count == positiveAlerts,
                     "Unknown never sends a good LED signal or positive reminder")
        frame(.none(peopleCount: 0))
        service.refreshReadings()
        precondition(snapshot.posture == .unknown && snapshot.peopleCount == 0 && board.signal == .pending)
        for _ in 0..<40 { frame(.bad(0.9)) }
        precondition(blur.intensity > 0)
        frame(.none(peopleCount: 0))
        precondition(blur.intensity == 0, "Losing the person clears blur")
        service.refreshReadings()
        precondition(snapshot.posture == .unknown && !snapshot.confirmed && board.signal == .pending)

        for _ in 0..<40 { frame(.bad(0.9)) }
        precondition(blur.intensity > 0)
        time.now.addTimeInterval(4)
        service.refreshReadings()
        precondition(snapshot.posture == .unknown && !snapshot.confirmed && blur.intensity == 0 && board.signal == .pending,
                     "Stalled camera input expires to unknown")
        frame(.good(0.9))
        service.refreshReadings()
        precondition(snapshot.posture == .unknown && !snapshot.confirmed, "Stale votes cannot confirm a fresh frame")
        camera.onState?(.denied)
        precondition(blur.intensity == 0)
        let startsBeforeFailure = camera.starts
        for _ in 0..<5 { time.now.addTimeInterval(1); service.refreshReadings() }
        precondition(camera.starts == startsBeforeFailure, "Denied camera is not restarted in a loop")
        service.stop()
        precondition(snapshot == .offline && blur.intensity == 0)
        frame(.bad(0.9))
        precondition(snapshot == .offline, "Callbacks after stop are ignored")
        // One stabilized timeline drives all camera effects without stacked delays.
        let timingCamera = FakeCamera(), timingBlur = FakeBlur(), timingClock = TestClock()
        let timingBoard = FakeArduino()
        var timingSnapshot = PostureSnapshot.offline
        var timingAlerts: [PostureAlert] = []
        let timingService = PostureMonitorService(onSnapshot: { timingSnapshot = $0 },
            onPreview: { _ in }, onState: { _ in }, onAlert: { timingAlerts.append($0) },
            camera: timingCamera, blur: timingBlur, arduino: timingBoard, clock: { timingClock.now })
        timingService.badDelay = 3
        timingService.start(enabled: true)
        func timingFrame(_ value: PostureOutcome) {
            timingClock.now.addTimeInterval(0.125)
            timingCamera.onReading?(.init(outcome: value, bestScore: value.confidence ?? 0,
                preview: nil, at: timingClock.now))
            timingService.refreshReadings()
        }
        for _ in 0..<16 { timingFrame(.bad(0.9)) }
        precondition(!timingSnapshot.confirmed && timingSnapshot.pendingPosture == .bad)
        precondition(timingAlerts.isEmpty && timingBlur.intensity == 0)
        timingFrame(.bad(0.9))
        precondition(timingSnapshot.posture == .bad && timingBlur.intensity == 0 && timingBoard.signal == .pending)
        for _ in 0..<7 { timingFrame(.bad(0.9)) }
        precondition(timingAlerts.isEmpty && timingBlur.intensity == 0, "No warning before three seconds from onset")
        timingFrame(.bad(0.9))
        precondition(timingAlerts.count == 1 && timingBlur.intensity == 0.5 && timingBoard.signal == .alert,
                     "HUD, LED and blur start together at three seconds, not five")
        timingFrame(.good(0.9))
        precondition(timingSnapshot.posture == .bad && timingBlur.intensity == 0.5)
        timingFrame(.bad(0.9))
        precondition(timingAlerts.count == 1, "A one-frame Good glitch cannot restart the alert episode")
        for _ in 0..<5 { timingFrame(.good(0.9)) }
        precondition(timingSnapshot.posture == .bad && timingBlur.intensity > 0)
        timingFrame(.good(0.9))
        precondition(timingSnapshot.posture == .good && timingBlur.intensity == 0 && timingBoard.signal == .good,
                     "Recovery clears all camera warnings after 0.6 seconds")
        let timingGoodAlerts = timingAlerts.filter { $0.kind == .good }.count
        for _ in 0..<8 { timingFrame(.bad(0.9)) }
        timingFrame(.good(0.9))
        precondition(timingSnapshot.posture == .good && timingBlur.intensity == 0 &&
                     timingAlerts.filter { $0.kind == .good }.count == timingGoodAlerts,
                     "A one-second lean does not flip state or create a correction notification")
        timingFrame(.none(peopleCount: 1))
        precondition(timingSnapshot.posture == .unknown && !timingSnapshot.confirmed)
        for _ in 0..<16 { timingFrame(.bad(0.9)) }
        let oldTime = timingClock.now
        timingClock.now.addTimeInterval(1.01)
        timingService.refreshReadings()
        precondition(timingSnapshot.posture == .unknown && timingBlur.intensity == 0)
        timingCamera.onReading?(.init(outcome: .bad(0.9), bestScore: 0.9, preview: nil, at: oldTime))
        timingService.refreshReadings()
        precondition(timingSnapshot.posture == .unknown && !timingSnapshot.isRunning,
                     "A stale callback cannot revive a stopped evidence timer")
        timingFrame(.bad(0.9))
        precondition(timingSnapshot.posture == .unknown, "A new frame after a gap starts over")
        timingFrame(.none(peopleCount: 0))
        timingService.badDelay = 1
        for _ in 0..<16 { timingFrame(.bad(0.9)) }
        precondition(timingBlur.intensity == 0, "A short configured delay still waits for confirmation")
        timingFrame(.bad(0.9))
        precondition(timingBlur.intensity > 0 && timingSnapshot.posture == .bad)
        timingService.badDelay = 3
        timingService.stop()
        print("PASS: seconds-based confirmation, fast recovery, brief leans, unified HUD/LED/blur onset, glitches and stale callbacks")

        // An old Auto selection is also migrated and never creates a fallback path.
        defaults.set("auto", forKey: "notch.posture.trackingMethod")
        let migratedCamera = FakeCamera()
        let migrated = PostureMonitorService(onSnapshot: { _ in }, onPreview: { _ in },
            onState: { _ in }, onAlert: { _ in }, camera: migratedCamera, blur: FakeBlur(), arduino: FakeArduino())
        migrated.start(enabled: true)
        precondition(migratedCamera.starts == 1 && defaults.object(forKey: "notch.posture.trackingMethod") == nil)
        migrated.stop()

        // Climate telemetry has its own cadence and expiry, independent of distance.
        defaults.set(true, forKey: PostureArduinoLink.enabledPreferenceKey)
        let climateBoard = FakeArduino(), climateClock = TestClock()
        var climateSnapshot = PostureSnapshot.offline
        let climateService = PostureMonitorService(onSnapshot: { climateSnapshot = $0 },
            onPreview: { _ in }, onState: { _ in }, onAlert: { _ in },
            camera: FakeCamera(), blur: FakeBlur(),
            arduino: climateBoard, clock: { climateClock.now })
        climateService.start(enabled: true)
        precondition(climateSnapshot.environmentState == .waiting)
        climateService.startCalibration()
        precondition(climateService.calibrationState.isActive)
        climateBoard.onTelemetry?(.init(distanceCM: 45, zone: .tooClose))
        climateService.refreshReadings()
        precondition(climateSnapshot.tooClose, "Distance warnings remain active during calibration")
        climateService.cancelCalibration()
        climateBoard.onEnvironment?(.init(temperatureC: 23.4, humidityPercent: 56.7))
        precondition(climateSnapshot.temperatureC == 23.4 && climateSnapshot.humidityPercent == 56.7)
        precondition(climateSnapshot.tooClose, "climate cannot clear distance alerts")
        climateClock.now.addTimeInterval(3)
        climateService.refreshReadings()
        precondition(climateSnapshot.distanceCM == nil && climateSnapshot.temperatureC == 23.4)
        climateClock.now.addTimeInterval(3.1)
        climateBoard.onTelemetry?(.init(distanceCM: 70, zone: .good))
        precondition(climateSnapshot.temperatureC == nil && climateSnapshot.environmentState == .stale)
        climateBoard.onEnvironment?(.init(temperatureC: nil, humidityPercent: nil))
        precondition(climateSnapshot.environmentState == .unavailable)
        climateBoard.onEnvironment?(.init(temperatureC: 0, humidityPercent: 0))
        precondition(climateSnapshot.environmentState == .live && climateSnapshot.temperatureC == 0)
        climateBoard.onState?(.searching)
        precondition(climateSnapshot.temperatureC == nil && climateSnapshot.humidityPercent == nil)
        climateBoard.onEnvironment?(.init(temperatureC: 25, humidityPercent: 50))
        climateService.setArduinoEnabled(false)
        precondition(climateSnapshot.temperatureC == nil && climateSnapshot.arduino == .disabled)
        climateService.stop()
        precondition(climateSnapshot == .offline)
        print("PASS: climate cadence, stale data, read failure, zero values, disconnect, disable and stop")

        // Blur controls use isolated preferences and simulated devices only.
        defaults.set(true, forKey: PostureArduinoLink.enabledPreferenceKey)
        let blurCamera = FakeCamera(), blurBoard = FakeArduino(), controlledBlur = FakeBlur(), blurClock = TestClock()
        var blurSnapshot = PostureSnapshot.offline
        let blurService = PostureMonitorService(onSnapshot: { blurSnapshot = $0 },
            onPreview: { _ in }, onState: { _ in }, onAlert: { _ in },
            camera: blurCamera, blur: controlledBlur,
            arduino: blurBoard, clock: { blurClock.now })
        var controls = PostureBlurSettings()
        controls.awayEnabled = true
        controls.awayDelay = 5
        blurService.setBlurSettings(controls)
        blurService.start(enabled: true)
        func blurFrame(_ outcome: PostureOutcome, advance: Double = 0.25) {
            blurClock.now.addTimeInterval(advance)
            blurCamera.onReading?(.init(outcome: outcome, bestScore: outcome.confidence ?? 0, preview: nil, at: blurClock.now))
        }
        for _ in 0..<30 { blurFrame(.none(peopleCount: 0)) }
        precondition(controlledBlur.intensity == 0, "An empty startup is not leaving the desk")
        for _ in 0..<4 { blurFrame(.good(0.9)) }
        for _ in 0..<30 {
            blurClock.now.addTimeInterval(0.25)
            blurCamera.onReading?(.init(outcome: .none(peopleCount: 0), bestScore: 0,
                preview: nil, at: blurClock.now, poseAssistanceUnavailable: true))
        }
        precondition(controlledBlur.intensity == 0 && blurSnapshot.poseAssistanceUnavailable,
                     "A failed pose worker must be visible and must not count as leaving the desk")
        precondition(blurSnapshot.detail == .message("MediaPipe is unavailable. Check the local Python environment."))
        blurFrame(.good(0.9))
        precondition(!blurSnapshot.poseAssistanceUnavailable, "Worker recovery clears its status")
        for _ in 0..<25 { blurFrame(.none(peopleCount: 1)) }
        precondition(controlledBlur.intensity == 0,
                     "A located person with an unknown posture is present, not away")
        for _ in 0..<12 { blurFrame(.none(peopleCount: 0)) }
        precondition(controlledBlur.intensity == 0, "Away waits its own delay")
        for _ in 0..<12 { blurFrame(.none(peopleCount: 0)) }
        precondition(abs(controlledBlur.intensity - 0.5) < 0.001, "Fresh empty frames trigger away blur")
        blurFrame(.good(0.9))
        precondition(controlledBlur.intensity == 0, "Returning clears away blur on the first frame")
        for _ in 0..<25 { blurFrame(.none(peopleCount: 0)) }
        precondition(controlledBlur.intensity > 0)
        blurFrame(.none(peopleCount: 2))
        precondition(controlledBlur.intensity == 0, "Multiple people are not absence")
        for _ in 0..<25 { blurFrame(.none(peopleCount: 0)) }
        precondition(controlledBlur.intensity > 0)
        blurClock.now.addTimeInterval(4)
        blurService.refreshReadings()
        precondition(controlledBlur.intensity == 0, "Camera stalls clear away blur")
        for _ in 0..<25 { blurFrame(.none(peopleCount: 0)) }
        precondition(controlledBlur.intensity == 0, "A stall requires presence again before away can rearm")
        for _ in 0..<4 { blurFrame(.good(0.9)) }
        for _ in 0..<25 { blurFrame(.none(peopleCount: 0)) }
        precondition(controlledBlur.intensity > 0)
        blurCamera.onState?(.denied)
        precondition(controlledBlur.intensity == 0, "Permission denial is not absence")
        blurCamera.onState?(.running)
        for _ in 0..<4 { blurFrame(.good(0.9)) }
        for _ in 0..<25 { blurFrame(.none(peopleCount: 0)) }
        controls.awayEnabled = false
        blurService.setBlurSettings(controls)
        precondition(controlledBlur.intensity == 0, "Disabling away clears its blur immediately")

        controls.startDistanceCM = 70
        controls.fullDistanceCM = 40
        blurService.setBlurSettings(controls)
        for _ in 0..<4 { blurFrame(.good(0.9)) }
        blurBoard.onTelemetry?(.init(distanceCM: 65, zone: .good))
        precondition(controlledBlur.intensity == 0, "Custom distance still waits the reminder delay")
        for _ in 0..<16 {
            blurFrame(.good(0.9))
            blurBoard.onTelemetry?(.init(distanceCM: 65, zone: .good))
        }
        precondition(abs(controlledBlur.intensity - 1.0 / 6) < 0.001)
        precondition(!blurSnapshot.tooClose, "Blur settings do not change distance alerts")
        controls.intensity = 0.5
        blurService.setBlurSettings(controls)
        let gentle = controlledBlur.intensity
        controls.intensity = 2
        blurService.setBlurSettings(controls)
        precondition(controlledBlur.intensity > gentle * 2, "Intensity applies immediately")
        precondition(PostureBlurSettings.load() == controls.normalized, "Blur preferences persist")
        controls.startDistanceCM = 60
        blurService.setBlurSettings(controls)
        precondition(controlledBlur.intensity == 0, "Changing distance clears the previous streak")
        controls.distanceEnabled = false
        blurService.setBlurSettings(controls)
        blurClock.now.addTimeInterval(0.3)
        blurBoard.onTelemetry?(.init(distanceCM: 45, zone: .tooClose))
        precondition(controlledBlur.intensity == 0 && blurSnapshot.tooClose, "Distance blur can be disabled independently of alerts")
        blurFrame(.none(peopleCount: 0))
        precondition(blurSnapshot.posture == .unknown && blurSnapshot.tooClose,
                     "Distance warning does not replace an unknown camera classification")
        controls.awayEnabled = true
        blurService.setBlurSettings(controls)
        for _ in 0..<4 { blurFrame(.good(0.9)) }
        for _ in 0..<25 { blurFrame(.none(peopleCount: 0)) }
        precondition(controlledBlur.intensity > 0)
        blurService.setEnabled(false)
        precondition(controlledBlur.intensity == 0, "Pausing clears away blur")
        let cameraStartsBeforeResume = blurCamera.starts
        blurService.setEnabled(true)
        precondition(blurCamera.starts == cameraStartsBeforeResume + 1)
        for _ in 0..<25 { blurFrame(.none(peopleCount: 0)) }
        precondition(controlledBlur.intensity == 0, "Resuming requires presence before away can rearm")
        blurService.stop()
        precondition(controlledBlur.intensity == 0)
        var invalidControls = PostureBlurSettings()
        invalidControls.intensity = .nan
        invalidControls.startDistanceCM = 10
        invalidControls.fullDistanceCM = 90
        invalidControls.awayDelay = .infinity
        precondition(invalidControls.normalized.intensity == 1)
        precondition(invalidControls.normalized.startDistanceCM == 20 && invalidControls.normalized.fullDistanceCM == 15)
        precondition(invalidControls.normalized.awayDelay == 5)
        print("PASS: adjustable blur intensity, custom distances, independent alerts, away delay, return, no startup blur, multi-person presence, camera stalls, denial, pause/resume, normalization and persistence")

        print("PASS: camera startup, migration of retired preferences, YOLO frames, blur recovery, stale input, permission denial, and stop")
        print("PASS: good/bad/unknown classification, unknown metadata, immediate detection loss, vote reset, neutral Arduino signal and no positive reminders for unknown")
    }
}
