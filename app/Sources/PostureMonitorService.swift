import AppKit
import Foundation
import OSLog

enum PostureRuntimeState: Equatable {
    case stopped
    case starting
    case running
    case needsPermission
    case denied
    case unavailable(String)
}

/// Coordinates the built-in camera, the bundled posture model and the Arduino
/// distance sensor. Everything runs inside Notch Triage, so the camera is granted
/// once to this app instead of to a helper process on every launch.
@MainActor
final class PostureMonitorService {
    static let enabledPreferenceKey = "notch.postureMonitoringEnabled"
    static let badDelayPreferenceKey = "notch.postureBadDelay"
    static let alertsPreferenceKey = "notch.postureAlertsEnabled"
    static let alertRepeatPreferenceKey = "notch.postureAlertRepeat"
    static let goodAlertsPreferenceKey = "notch.postureGoodAlertsEnabled"
    static let sensitivityPreferenceKey = "notch.postureSensitivity"
    static let colorThemePreferenceKey = "notch.postureColorTheme"
    static let restReminderEnabledKey = "notch.posture.restReminderEnabled"
    static let restReminderMinutesKey = "notch.posture.restReminderMinutes"
    static let restReminderCustomKey = "notch.posture.restReminderCustom"
    static let restReminderCustomMinutesKey = "notch.posture.restReminderCustomMinutes"
    static let goodColorPreferenceKey = "notch.postureGoodColor"
    static let badColorPreferenceKey = "notch.postureBadColor"
    static let warningColorPreferenceKey = "notch.postureWarningColor"
    static let defaultBadDelay: TimeInterval = 3
    static let telemetryFreshness: TimeInterval = 1.5
    static let environmentFreshness: TimeInterval = 6
    static let readingTimeout = PostureStabilizer.maximumGap
    static var savedArduinoEnabled: Bool {
        UserDefaults.standard.object(forKey: PostureArduinoLink.enabledPreferenceKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: PostureArduinoLink.enabledPreferenceKey)
    }

    static var savedAlertsEnabled: Bool {
        UserDefaults.standard.object(forKey: alertsPreferenceKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: alertsPreferenceKey)
    }

    /// Colours are stored per role so they can be edited individually; a preset
    /// chosen before this existed seeds them on first launch.
    static var savedColors: PostureColors {
        let defaults = UserDefaults.standard
        let preset = defaults.string(forKey: colorThemePreferenceKey)
            .flatMap(PostureColorTheme.init(rawValue:)) ?? .defaultTheme
        let seed = preset.colors
        return PostureColors(
            goodHex: defaults.string(forKey: goodColorPreferenceKey) ?? seed.goodHex,
            badHex: defaults.string(forKey: badColorPreferenceKey) ?? seed.badHex,
            warningHex: defaults.string(forKey: warningColorPreferenceKey) ?? seed.warningHex
        )
    }

    static func saveColors(_ colors: PostureColors) {
        let defaults = UserDefaults.standard
        defaults.set(colors.goodHex, forKey: goodColorPreferenceKey)
        defaults.set(colors.badHex, forKey: badColorPreferenceKey)
        defaults.set(colors.warningHex, forKey: warningColorPreferenceKey)
        if let theme = colors.matchingTheme {
            defaults.set(theme.rawValue, forKey: colorThemePreferenceKey)
        }
    }

    static var savedRestReminderEnabled: Bool {
        UserDefaults.standard.object(forKey: restReminderEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: restReminderEnabledKey)
    }

    static var savedRestReminderUsesCustom: Bool {
        UserDefaults.standard.bool(forKey: restReminderCustomKey)
    }

    static var savedRestReminderCustomMinutes: Double {
        let stored = UserDefaults.standard.double(forKey: restReminderCustomMinutesKey)
        return stored > 0 ? stored : 40
    }

    static var savedRestReminderMinutes: Double {
        let stored = UserDefaults.standard.double(forKey: restReminderMinutesKey)
        return stored > 0 ? stored : 45
    }

    static var savedSensitivity: PostureSensitivity {
        UserDefaults.standard.string(forKey: sensitivityPreferenceKey)
            .flatMap(PostureSensitivity.init(rawValue:)) ?? .defaultSensitivity
    }

    static let poseFallbackPreferenceKey = "notch.posture.poseFallback"

    /// On unless the user turned it off: a frame the head cannot read is otherwise
    /// simply lost, and the pose fallback only ever adds a second opinion.
    static var savedPoseFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: poseFallbackPreferenceKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: poseFallbackPreferenceKey)
    }

    static var savedGoodAlertsEnabled: Bool {
        UserDefaults.standard.object(forKey: goodAlertsPreferenceKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: goodAlertsPreferenceKey)
    }

    static var savedAlertRepeat: PostureAlertRepeat {
        UserDefaults.standard.string(forKey: alertRepeatPreferenceKey)
            .flatMap(PostureAlertRepeat.init(rawValue:)) ?? .defaultRepeat
    }

    static var savedBadDelay: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: badDelayPreferenceKey)
        return stored > 0 ? stored : defaultBadDelay
    }

    static let blurEnabledKey = "notch.posture.progressiveBlur"
    static var savedBlurEnabled: Bool { UserDefaults.standard.bool(forKey: blurEnabledKey) }

    /// Remove preferences belonging to retired features and tracking modes. The
    /// camera is always used now, including for existing installations with an old
    /// choice, and the skeletal score was removed in favour of the YOLO verdict.
    static func removeLegacyTrackingPreferences(defaults: UserDefaults = .standard) {
        for key in ["notch.posture.trackingMethod", "notch.posture.calibration.airPods",
                    "notch.posture.cameraAlgorithm", "notch.posture.calibration.vision",
                    "notch.posture.pose2D.baseline.v1", "notch.posture.pose2D.wizardIntroduced.v1",
                    "notch.posture.scoreEnabled", "notch.posture.scoreBaseline"] {
            defaults.removeObject(forKey: key)
        }
    }

    private let blur: PostureBlurPresenting
    private let clock: () -> Date
    private var blurEnabled = PostureMonitorService.savedBlurEnabled
    private var blurSettings = PostureBlurSettings.load()
    private var awaySince: Date?
    private var hasSeenCameraPerson = false
    private var latestFrameAt: Date?

    private let camera: PostureCameraInput
    private let arduino: PostureArduinoInput
    private let onSnapshot: (PostureSnapshot) -> Void
    private let onPreview: (NSImage?) -> Void
    private let onState: (PostureRuntimeState) -> Void
    private let onAlert: (PostureAlert) -> Void

    private let onCalibration: (PostureCalibrationState) -> Void
    private(set) var calibrationState: PostureCalibrationState = .idle

    func startCalibration() {
        guard wantsDetection, cameraState == .running, poseFallbackEnabled,
              !calibrationState.isActive else { return }
        calibrationChanged(.preparing(3))
        camera.startCalibration()
    }

    func cancelCalibration() {
        camera.cancelCalibration()
        calibrationChanged(PostureManualReference.load() == nil ? .idle : .complete)
    }

    private func calibrationChanged(_ state: PostureCalibrationState) {
        calibrationState = state
        latestVerdictSource = .model
        onCalibration(state)
        // Clear old camera warnings and votes at either boundary; distance stays independent.
        stabilizer.reset()
        outcome = .none(peopleCount: 1)
        badSince = nil
        awaySince = nil
        if wantsDetection {
            arduino.notify(arduinoSignal(now: clock()))
            publishSnapshot(force: true)
        }
    }

    private var wantsDetection = false
    private var previewVisible = false
    private var arduinoEnabled: Bool
    private var cameraState: PostureCameraState = .idle
    private var arduinoState: PostureArduinoLink.State = .disabled
    private var outcome: PostureOutcome = .none(peopleCount: 0)
    private var stabilizer = PostureStabilizer()
    private var badSince: Date?
    /// When the ultrasonic reading first went under the too-close line, so the
    /// distance-driven blur can hold its own reminder delay.
    private var distanceBadSince: Date?
    private var latestTelemetry: PostureSerialTelemetry?
    private var latestTelemetryAt: Date?
    private var latestEnvironment: PostureEnvironmentTelemetry?
    private var latestEnvironmentAt: Date?
    private var latestReadingAt: Date?
    private var startedAt: Date?
    private var published = PostureSnapshot.offline
    private var lastPublishAt: Date = .distantPast
    private var runtime: PostureRuntimeState = .stopped
    private var heartbeat: Timer?
    private var latestBestScore: Double = 0
    private var latestVerdictSource: PostureVerdictSource = .model
    private var poseAssistanceUnavailable = false
    private var lastLoggedBlurIntensity: Double = 0
    private let log = Logger(subsystem: "com.hyacinth.notchtriage", category: "posture")
    private var alertPolicy = PostureAlertPolicy(
        repeatInterval: PostureMonitorService.savedAlertRepeat.interval
    )
    private var goodAlertPolicy = PostureGoodAlertPolicy()

    init(
        onSnapshot: @escaping (PostureSnapshot) -> Void,
        onPreview: @escaping (NSImage?) -> Void,
        onState: @escaping (PostureRuntimeState) -> Void,
        onAlert: @escaping (PostureAlert) -> Void,
        camera: PostureCameraInput? = nil,
        blur: PostureBlurPresenting? = nil,
        arduino: PostureArduinoInput? = nil,
        clock: @escaping () -> Date = Date.init,
        onCalibration: @escaping (PostureCalibrationState) -> Void = { _ in }
    ) {
        let camera = camera ?? PostureCameraController()
        let arduino = arduino ?? PostureArduinoLink()
        self.arduino = arduino
        self.camera = camera
        self.blur = blur ?? PostureBlurOverlay()
        self.clock = clock
        self.onSnapshot = onSnapshot
        self.onPreview = onPreview
        self.onState = onState
        self.onAlert = onAlert
        self.onCalibration = onCalibration
        arduinoEnabled = PostureMonitorService.savedArduinoEnabled
        PostureMonitorService.removeLegacyTrackingPreferences()
        camera.confidenceThreshold = PostureMonitorService.savedSensitivity.threshold
        camera.poseFallbackEnabled = PostureMonitorService.savedPoseFallbackEnabled
        if let controller = camera as? PostureCameraController {
            controller.overlayLanguage = overlayLanguage
        }
        camera.onState = { [weak self] state in self?.cameraStateChanged(state) }
        camera.onReading = { [weak self] reading in self?.received(reading) }
        camera.onCalibration = { [weak self] state in self?.calibrationChanged(state) }
        arduino.onState = { [weak self] state in self?.arduinoStateChanged(state) }
        arduino.onTelemetry = { [weak self] telemetry in self?.received(telemetry) }
        arduino.onEnvironment = { [weak self] telemetry in self?.received(telemetry) }
        arduino.onBoardRemembered = { board in PostureArduinoLink.remember(board) }
    }

    func setBlurEnabled(_ enabled: Bool) {
        blurEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.blurEnabledKey)
        if !enabled { awaySince = nil; blur.clear() }
        else { publishSnapshot(force: true) }
    }

    func setBlurSettings(_ settings: PostureBlurSettings) {
        let value = settings.normalized
        if value.distanceEnabled != blurSettings.distanceEnabled || value.startDistanceCM != blurSettings.startDistanceCM || value.fullDistanceCM != blurSettings.fullDistanceCM {
            distanceBadSince = nil
        }
        if value.awayEnabled != blurSettings.awayEnabled { awaySince = nil }
        blurSettings = value
        value.save()
        publishSnapshot(force: true)
    }

    var sensitivity: PostureSensitivity = PostureMonitorService.savedSensitivity {
        didSet {
            UserDefaults.standard.set(sensitivity.rawValue, forKey: Self.sensitivityPreferenceKey)
            camera.confidenceThreshold = sensitivity.threshold
        }
    }

    func setSensitivity(_ value: PostureSensitivity) {
        guard sensitivity != value else { return }
        sensitivity = value
    }

    var poseFallbackEnabled: Bool = PostureMonitorService.savedPoseFallbackEnabled {
        didSet {
            UserDefaults.standard.set(poseFallbackEnabled, forKey: Self.poseFallbackPreferenceKey)
            camera.poseFallbackEnabled = poseFallbackEnabled
            if !poseFallbackEnabled { cancelCalibration() }
        }
    }

    func setPoseFallbackEnabled(_ enabled: Bool) {
        guard poseFallbackEnabled != enabled else { return }
        poseFallbackEnabled = enabled
    }

    /// Language stamped onto camera preview verdict chips, so they never leak
    /// the inactive interface language.
    var overlayLanguage: AppLanguage = AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: "notch.appLanguage") ?? ""
    ) ?? .defaultLanguage {
        didSet {
            if let controller = camera as? PostureCameraController {
                controller.overlayLanguage = overlayLanguage
            }
        }
    }

    var goodAlertsEnabled: Bool = PostureMonitorService.savedGoodAlertsEnabled {
        didSet {
            UserDefaults.standard.set(goodAlertsEnabled, forKey: Self.goodAlertsPreferenceKey)
            if !goodAlertsEnabled { goodAlertPolicy.reset() }
        }
    }

    func setGoodAlertsEnabled(_ enabled: Bool) {
        guard goodAlertsEnabled != enabled else { return }
        goodAlertsEnabled = enabled
    }

    var alertsEnabled: Bool = PostureMonitorService.savedAlertsEnabled {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: Self.alertsPreferenceKey)
            if !alertsEnabled { alertPolicy.reset() }
        }
    }

    func setAlertsEnabled(_ enabled: Bool) {
        guard alertsEnabled != enabled else { return }
        alertsEnabled = enabled
    }

    var alertRepeat: PostureAlertRepeat = PostureMonitorService.savedAlertRepeat {
        didSet {
            UserDefaults.standard.set(alertRepeat.rawValue, forKey: Self.alertRepeatPreferenceKey)
            alertPolicy.repeatInterval = alertRepeat.interval
        }
    }

    func setAlertRepeat(_ repeatMode: PostureAlertRepeat) {
        guard alertRepeat != repeatMode else { return }
        alertRepeat = repeatMode
    }

    var badDelay: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.badDelayPreferenceKey)
            return stored > 0 ? stored : Self.defaultBadDelay
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.badDelayPreferenceKey)
        }
    }

    func start(enabled: Bool) {
        setEnabled(enabled)
    }

    func setEnabled(_ enabled: Bool) {
        wantsDetection = enabled
        guard enabled else {
            stop()
            return
        }
        guard !isActive else { return }
        startedAt = clock()
        badSince = nil
        stabilizer.reset()
        outcome = .none(peopleCount: 0)
        latestReadingAt = nil
        log.notice("posture detection starting (sensitivity=\(self.sensitivity.rawValue, privacy: .public))")
        setRuntime(.starting)
        latestFrameAt = nil
        awaySince = nil
        hasSeenCameraPerson = false
        camera.setPreviewEnabled(previewVisible)
        camera.start()
        arduino.start(enabled: arduinoEnabled)
        startHeartbeat()
        publishSnapshot(force: true)
    }

    func setPreviewVisible(_ visible: Bool) {
        guard previewVisible != visible else { return }
        previewVisible = visible
        camera.setPreviewEnabled(visible)
        if !visible { onPreview(nil) }
    }

    func setArduinoEnabled(_ enabled: Bool) {
        guard arduinoEnabled != enabled else { return }
        arduinoEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PostureArduinoLink.enabledPreferenceKey)
        if !wantsDetection { return }
        if enabled {
            arduino.start(enabled: true)
        } else {
            arduino.stop()
            latestTelemetry = nil
            latestTelemetryAt = nil
            latestEnvironment = nil
            latestEnvironmentAt = nil
        }
        publishSnapshot(force: true)
    }

    /// Re-applies the stored preferences and asks for camera access again.
    /// `enabled` lets the caller keep the camera off while the system is locked
    /// or asleep.
    func restart(enabled: Bool = true) {
        stop()
        setEnabled(enabled)
    }

    func stop() {
        wantsDetection = false
        heartbeat?.invalidate()
        heartbeat = nil
        camera.stop()
        calibrationState = PostureManualReference.load() == nil ? .idle : .complete
        onCalibration(calibrationState)
        blur.clear()
        distanceBadSince = nil
        latestFrameAt = nil
        awaySince = nil
        hasSeenCameraPerson = false
        arduino.stop()
        cameraState = .idle
        arduinoState = .disabled
        outcome = .none(peopleCount: 0)
        stabilizer.reset()
        badSince = nil
        latestTelemetry = nil
        latestTelemetryAt = nil
        latestEnvironment = nil
        latestEnvironmentAt = nil
        latestReadingAt = nil
        latestBestScore = 0
        latestVerdictSource = .model
        poseAssistanceUnavailable = false
        alertPolicy.reset()
        goodAlertPolicy.reset()
        published = .offline
        onSnapshot(.offline)
        onPreview(nil)
        setRuntime(.stopped)
    }

    private var isActive: Bool {
        if case .stopped = runtime { return false }
        if case .unavailable = runtime { return false }
        if case .denied = runtime { return false }
        return true
    }

    private func cameraStateChanged(_ state: PostureCameraState) {
        guard wantsDetection else { return }
        log.notice("camera state -> \(String(describing: state), privacy: .public)")
        cameraState = state
        if state != .running {
            stabilizer.reset()
            outcome = .none(peopleCount: 0)
            badSince = nil
            latestReadingAt = nil
            latestFrameAt = nil
            latestVerdictSource = .model
            if calibrationState.isActive { cancelCalibration() }
            awaySince = nil
            hasSeenCameraPerson = false
        }
        switch state {
        case .idle:
            break
        case .running:
            setRuntime(.running)
        case .needsPermission:
            setRuntime(.needsPermission)
        case .denied:
            setRuntime(.denied)
        case .unavailable(let message):
            setRuntime(.unavailable(message))
            camera.stop()
        }
        publishSnapshot(force: true)
    }

    private func arduinoStateChanged(_ state: PostureArduinoLink.State) {
        arduinoState = state
        if state != .connected {
            distanceBadSince = nil
            latestTelemetry = nil
            latestTelemetryAt = nil
            latestEnvironment = nil
            latestEnvironmentAt = nil
        }
        publishSnapshot(force: true)
    }

    private func received(_ telemetry: PostureEnvironmentTelemetry) {
        guard wantsDetection, arduinoEnabled else { return }
        latestEnvironment = telemetry
        latestEnvironmentAt = clock()
        publishSnapshot(force: true)
    }

    private func received(_ telemetry: PostureSerialTelemetry) {
        guard wantsDetection else { return }
        let now = clock()
        if let previous = latestTelemetryAt, now.timeIntervalSince(previous) > Self.telemetryFreshness {
            distanceBadSince = nil
        }
        latestTelemetry = telemetry
        latestTelemetryAt = now
        updateDistanceBadSince(telemetry: telemetry, now: now)
        arduino.notify(arduinoSignal(now: now))
        refreshAlert(now: now)
        publishSnapshot()
    }

    private func received(_ reading: PostureFrameReading) {
        guard wantsDetection, cameraState == .running else { return }
        let age = clock().timeIntervalSince(reading.at)
        guard age >= 0, age <= Self.readingTimeout,
              latestFrameAt.map({ reading.at > $0 }) ?? true else { return }
        var reading = reading
        if calibrationState.isActive { reading.outcome = .none(peopleCount: 1) }
        // Only fresh, analysed frames can establish absence. A stalled camera,
        // denied permission is never evidence of leaving.
        if let lastFrame = latestFrameAt, reading.at.timeIntervalSince(lastFrame) > Self.readingTimeout {
            awaySince = nil
            hasSeenCameraPerson = false
        }
        if reading.outcome.isConfirmed { hasSeenCameraPerson = true }
        if case .none(peopleCount: 0) = reading.outcome,
           !reading.poseAssistanceUnavailable, hasSeenCameraPerson, blurEnabled, blurSettings.awayEnabled {
            if awaySince == nil { awaySince = reading.at }
        } else {
            awaySince = nil
        }
        latestFrameAt = reading.at
        latestReadingAt = reading.at
        outcome = stabilizer.update(reading.outcome, now: reading.at)
        latestBestScore = reading.bestScore
        latestVerdictSource = calibrationState.isActive ? .model : reading.source
        poseAssistanceUnavailable = reading.poseAssistanceUnavailable
        badSince = stabilizer.badSince
        if let preview = reading.preview, previewVisible {
            onPreview(NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height)))
        }
        if case .starting = runtime, cameraState == .running { setRuntime(.running) }
        arduino.notify(arduinoSignal(now: reading.at))
        refreshAlert(now: reading.at)
        publishSnapshot()
    }

    /// Everything the reminder policies need, in one place so the HUD and the
    /// Arduino LED can never disagree.
    private struct AlertInputs {
        var tooClose: Bool
        /// The tracker has confirmed bad posture.
        var cameraBad: Bool
        /// ...and it has lasted past the alert delay.
        var cameraSlouching: Bool

        var isBad: Bool { tooClose || cameraSlouching }
        /// Bad posture still inside its grace period: the LED waits, like the HUD.
        var isPending: Bool { !isBad && cameraBad }
    }

    private func alertInputs(now: Date) -> AlertInputs {
        let telemetryFresh = latestTelemetryAt.map {
            now.timeIntervalSince($0) <= Self.telemetryFreshness
        } ?? false
        let tooClose = arduinoEnabled && telemetryFresh && latestTelemetry?.zone == .tooClose
        let cameraBad: Bool = {
            guard cameraState == .running, case .bad = outcome,
                  let latestReadingAt, now.timeIntervalSince(latestReadingAt) <= Self.readingTimeout else { return false }
            return true
        }()
        let cameraSlouching: Bool = {
            guard cameraBad, let badSince else { return false }
            return now.timeIntervalSince(badSince) >= badDelay
        }()
        return AlertInputs(
            tooClose: tooClose,
            cameraBad: cameraBad,
            cameraSlouching: cameraSlouching
        )
    }

    /// Reminds once when bad posture starts, then at most every
    /// `repeatInterval` seconds while it continues.
    private func refreshAlert(now: Date) {
        let inputs = alertInputs(now: now)
        let active = wantsDetection && inputs.isBad
        if alertPolicy.evaluate(active: active, enabled: alertsEnabled, now: now) {
            onAlert(PostureAlert(tooClose: inputs.tooClose))
        }

        // Confirming a correction is as useful as warning about a slouch.
        let confirmedGood: Bool = {
            guard wantsDetection, cameraState == .running,
                  let latestReadingAt, now.timeIntervalSince(latestReadingAt) <= Self.readingTimeout else { return false }
            guard case .good = outcome else { return false }
            return true
        }()
        let confirmedBad = wantsDetection && inputs.cameraBad
        if goodAlertPolicy.evaluate(
            confirmedGood: confirmedGood,
            bad: confirmedBad,
            enabled: goodAlertsEnabled,
            now: now
        ) {
            onAlert(PostureAlert(kind: .good))
        }
    }

    private func arduinoSignal(now: Date) -> PostureArduinoSignal {
        let inputs = alertInputs(now: now)
        if inputs.isBad { return .alert }
        guard wantsDetection, cameraState == .running,
              let latestReadingAt, now.timeIntervalSince(latestReadingAt) <= Self.readingTimeout,
              case .good = outcome else { return .pending }
        return .good
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshReadings()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// Re-evaluate freshness independently of input callbacks so silent devices cannot keep warnings alive.
    func refreshReadings() {
        guard wantsDetection else { return }
        if let reading = latestReadingAt,
           clock().timeIntervalSince(reading) > Self.readingTimeout {
            latestReadingAt = nil
            latestBestScore = 0
            latestVerdictSource = .model
            outcome = .none(peopleCount: 0)
            stabilizer.reset()
            badSince = nil
            awaySince = nil
            hasSeenCameraPerson = false
            onPreview(nil)
        }
        if let telemetryAt = latestTelemetryAt,
           clock().timeIntervalSince(telemetryAt) > Self.telemetryFreshness {
            distanceBadSince = nil
        }
        arduino.notify(arduinoSignal(now: clock()))
        refreshAlert(now: clock())
        publishSnapshot(force: true)
    }

    private func setRuntime(_ state: PostureRuntimeState) {
        guard runtime != state else { return }
        runtime = state
        onState(state)
    }

    /// The distance sensor keeps its own streak: leaning in and sitting back are
    /// continuous, so the blur can follow how far past the line the person is.
    private func updateDistanceBadSince(telemetry: PostureSerialTelemetry, now: Date) {
        guard arduinoEnabled else {
            distanceBadSince = nil
            return
        }
        let leaningIn = blurSettings.distanceEnabled && PostureDistanceResponse.severity(
            distanceCM: telemetry.distanceCM ?? -1,
            startCM: blurSettings.startDistanceCM, fullCM: blurSettings.fullDistanceCM) > 0
        if leaningIn {
            if distanceBadSince == nil { distanceBadSince = now }
        } else {
            distanceBadSince = nil
        }
    }

    /// Blur strength: the camera's confirmed slouch (a fixed gentle intensity,
    /// because the classifier has no "how bad"), raised by how far the ultrasonic
    /// reading is past the too-close line.
    private func blurIntensity(snapshot: PostureSnapshot, now: Date) -> Double {
        guard blurEnabled, wantsDetection else { return 0 }
        let sourceFresh = latestReadingAt.map { now.timeIntervalSince($0) <= Self.readingTimeout } ?? false
        guard sourceFresh, cameraState == .running else { return 0 }
        let camera: Double = snapshot.confirmed && alertInputs(now: now).cameraSlouching ? 0.5 : 0
        let telemetryFresh = latestTelemetryAt.map {
            now.timeIntervalSince($0) <= Self.telemetryFreshness
        } ?? false
        let distance: Double = {
            guard blurSettings.distanceEnabled, arduinoEnabled, telemetryFresh, snapshot.isRunning,
                  let distanceCM = latestTelemetry?.distanceCM else { return 0 }
            return PostureDistanceResponse.blurIntensity(
                distanceCM: distanceCM,
                badSince: distanceBadSince,
                delay: badDelay,
                now: now,
                startCM: blurSettings.startDistanceCM,
                fullCM: blurSettings.fullDistanceCM
            )
        }()
        let away: Double = {
            guard blurSettings.awayEnabled, hasSeenCameraPerson,
                  let awaySince, now.timeIntervalSince(awaySince) >= blurSettings.awayDelay else { return 0 }
            return 0.5
        }()
        return blurSettings.adjustedIntensity(max(camera, distance, away))
    }

    private func publishSnapshot(force: Bool = false) {
        let now = clock()
        let snapshot = makeSnapshot(now: now)
        let warningIntensity = blurIntensity(snapshot: snapshot, now: now)
        blur.update(intensity: warningIntensity)
        if abs(warningIntensity - lastLoggedBlurIntensity) >= 0.05 {
            lastLoggedBlurIntensity = warningIntensity
            log.notice("blur intensity -> \(String(format: "%.2f", warningIntensity), privacy: .public)")
        }
        if !force, now.timeIntervalSince(lastPublishAt) < 0.25 { return }
        lastPublishAt = now
        guard snapshot != published else { return }
        let postureChanged = snapshot.posture != published.posture
            || snapshot.confirmed != published.confirmed
        published = snapshot
        if postureChanged {
            log.notice(
                "posture=\(snapshot.posture.rawValue, privacy: .public) confirmed=\(snapshot.confirmed, privacy: .public) source=\(snapshot.source?.rawValue ?? "none", privacy: .public) score=\(String(format: "%.2f", snapshot.bestScore), privacy: .public) distance=\(snapshot.distanceCM ?? -1, privacy: .public)"
            )
        }
        onSnapshot(snapshot)
    }

    private func makeSnapshot(now: Date) -> PostureSnapshot {
        let telemetryFresh = latestTelemetryAt.map {
            now.timeIntervalSince($0) <= Self.telemetryFreshness
        } ?? false
        let tooClose = arduinoEnabled && telemetryFresh && latestTelemetry?.zone == .tooClose
        let cameraRunning = wantsDetection && cameraState == .running &&
            (latestReadingAt.map { now.timeIntervalSince($0) <= Self.readingTimeout } ?? false)
        let running = cameraRunning
        let posture: PostureState = running ? outcome.posture : .unknown
        let source: PostureSignalSource? = {
            guard running, outcome.isConfirmed else { return nil }
            return .camera
        }()
        let confirmed = running && outcome.isConfirmed
        let environmentFresh = latestEnvironmentAt.map {
            now.timeIntervalSince($0) <= Self.environmentFreshness
        } ?? false
        let environmentState: PostureEnvironmentState = {
            guard arduinoEnabled, latestEnvironmentAt != nil else { return .waiting }
            guard environmentFresh else { return .stale }
            return latestEnvironment?.temperatureC != nil ? .live : .unavailable
        }()
        let snapshot = PostureSnapshot(
            posture: posture,
            arduino: arduinoDisplayState(telemetryFresh: telemetryFresh),
            distanceCM: arduinoEnabled && telemetryFresh ? latestTelemetry?.distanceCM : nil,
            tooClose: tooClose,
            isRunning: running,
            confirmed: confirmed,
            source: source,
            confidence: cameraRunning ? outcome.confidence : nil,
            peopleCount: cameraRunning ? outcome.peopleCount : 0,
            zone: arduinoEnabled && telemetryFresh ? latestTelemetry?.zone : nil,
            bestScore: cameraRunning ? latestBestScore : 0,
            temperatureC: arduinoEnabled && environmentFresh ? latestEnvironment?.temperatureC : nil,
            humidityPercent: arduinoEnabled && environmentFresh ? latestEnvironment?.humidityPercent : nil,
            environmentState: environmentState,
            poseConflict: cameraRunning && !confirmed && latestVerdictSource.isVeto,
            pendingPosture: cameraRunning ? stabilizer.pendingState : nil,
            poseAssistanceUnavailable: cameraRunning && poseAssistanceUnavailable
        )
        return snapshot
    }

    private func arduinoDisplayState(telemetryFresh: Bool) -> PostureArduinoState {
        guard arduinoEnabled else { return .disabled }
        switch arduinoState {
        case .disabled:
            return .disabled
        case .connected:
            return telemetryFresh ? .connected : .unresponsive
        case .connecting:
            return .starting
        case .searching:
            let waited = startedAt.map { clock().timeIntervalSince($0) } ?? 0
            return waited > 5 ? .disconnected : .starting
        case .failed:
            return .disconnected
        }
    }
}
