import CoreGraphics
import Foundation

enum PostureState: String, Decodable, Sendable {
    case good, bad, unknown

    var title: String {
        switch self {
        case .good: return "Good posture"
        case .bad: return "Bad posture"
        case .unknown: return "Unknown posture"
        }
    }
}

enum PostureArduinoState: String, Decodable, Sendable {
    case connected, disconnected, starting, unresponsive, disabled

    var title: String {
        switch self {
        case .connected: return "Arduino connected"
        case .disconnected: return "Arduino disconnected"
        case .starting: return "Arduino starting"
        case .unresponsive: return "Arduino: no sensor data"
        case .disabled: return "Arduino disabled"
        }
    }

    var symbol: String {
        switch self {
        case .connected: return "cable.connector"
        case .starting: return "ellipsis"
        case .unresponsive: return "exclamationmark"
        case .disconnected, .disabled: return "xmark"
        }
    }
}

/// Distance zones reported by the ultrasonic firmware (D,<cm>,<zone>).
enum PostureDistanceZone: String, Equatable, Sendable {
    case tooClose = "C"
    case near = "W"
    case good = "G"
    case none = "N"

    var title: String {
        switch self {
        case .tooClose: return "Too close - move back"
        case .near: return "A bit close"
        case .good: return "Good distance"
        case .none: return "Out of range"
        }
    }
}

/// The camera model produced the reported posture.
enum PostureSignalSource: String, Equatable, Sendable {
    /// The YOLO posture model reading the camera frame.
    case camera

    var title: String {
        switch self {
        case .camera: return "Camera"
        }
    }
}

enum PostureEnvironmentState: Equatable, Sendable {
    case waiting, live, unavailable, stale

    var title: String {
        switch self {
        case .waiting: return "Waiting for climate data. Check that the updated firmware is uploaded."
        case .live: return "Updates every 2 seconds"
        case .unavailable: return "Sensor read failed. Check D2 wiring and sensor type."
        case .stale: return "Temperature and humidity data is stale"
        }
    }
}

struct PostureSnapshot: Equatable, Sendable {
    var posture: PostureState = .unknown
    var arduino: PostureArduinoState = .disconnected
    var distanceCM: Double?
    var tooClose: Bool = false
    var isRunning: Bool = false
    /// True only when a source actually measured this posture: one confident
    /// detection in the frame.
    var confirmed: Bool = false
    /// The source that decided `posture`, nil while nothing measured it.
    var source: PostureSignalSource?
    var confidence: Double?
    var peopleCount: Int = 0
    var zone: PostureDistanceZone?
    /// Best confidence seen in the current frames, even when it stayed below the threshold.
    var bestScore: Double = 0

    var temperatureC: Double?
    var humidityPercent: Double?
    var environmentState: PostureEnvironmentState = .waiting

    /// Strong model/pose disagreement; neutral even when the model score is high.
    var poseConflict: Bool = false
    var pendingPosture: PostureState?
    var poseAssistanceUnavailable: Bool = false

    static let offline = PostureSnapshot()

    var title: String {
        guard isRunning else { return "Posture detection is not running" }
        if tooClose { return "Too close — move back" }
        guard confirmed else { return PostureState.unknown.title }
        return posture.title
    }

    /// Secondary line for the ring hover preview and the panel header.
    var detail: PostureDetail {
        guard isRunning else { return .arduino(arduino.title) }
        if poseAssistanceUnavailable { return .message("MediaPipe is unavailable. Check the local Python environment.") }
        if poseConflict { return .message("Model and pose disagree; posture is temporarily unknown") }
        if pendingPosture != nil { return .message("Confirming a posture change; please hold steady") }
        if let confidence, confirmed, source == .camera { return .confidence(confidence) }
        if peopleCount > 1 { return .people(peopleCount) }
        return .arduino(arduino.title)
    }
}

enum PostureDetail: Equatable, Sendable {
    case message(String)
    case confidence(Double)
    case people(Int)
    /// Localisation key describing the Arduino link.
    case arduino(String)
}

/// A posture reminder; shown in the notch through the system HUD pipeline.
struct PostureAlert: Equatable, Sendable {
    enum Kind: String, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
        case badPosture
        case tooClose
        case good

        var id: String { rawValue }
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    init(tooClose: Bool) {
        self.kind = tooClose ? .tooClose : .badPosture
    }

    var isPositive: Bool { kind == .good }

    var title: String {
        switch kind {
        case .badPosture: return "Bad posture"
        case .tooClose: return "Too close"
        case .good: return "Good posture"
        }
    }

    var subtitle: String {
        switch kind {
        case .badPosture: return "Sit up straight and relax your shoulders"
        case .tooClose: return "Too close - sit back"
        case .good: return "Keep it up"
        }
    }
}

/// Announces a confirmed good posture once per correction: the first confident
/// result of a session, and every time good posture follows a bad one.
struct PostureGoodAlertPolicy: Equatable {
    private var announced = false
    private var seenGood = false
    private var badSinceGood = false

    mutating func evaluate(confirmedGood: Bool, bad: Bool, enabled: Bool, now: Date = Date()) -> Bool {
        if bad {
            announced = false
            badSinceGood = true
            return false
        }
        guard confirmedGood, !announced else { return false }
        announced = true
        let isFirstOfSession = !seenGood
        seenGood = true
        guard enabled, badSinceGood || isFirstOfSession else { return false }
        badSinceGood = false
        return true
    }

    mutating func reset() {
        announced = false
        seenGood = false
        badSinceGood = false
    }
}

/// Seconds-based hysteresis shared by presentation, reminders and camera blur.
/// Unknown clears evidence immediately; gaps and replayed frames cannot advance timers.
struct PostureStabilizer: Equatable {
    static let badConfirmation: TimeInterval = 2
    static let goodConfirmation: TimeInterval = 0.6
    static let maximumGap: TimeInterval = 1
    static let minimumSamples = 3

    private(set) var stable: PostureOutcome = .none(peopleCount: 0)
    private(set) var badSince: Date?
    private(set) var pendingState: PostureState?
    private var pendingSince: Date?
    private var pendingSamples = 0
    private var lastAt: Date?

    mutating func update(_ outcome: PostureOutcome, now: Date) -> PostureOutcome {
        if let lastAt {
            guard now > lastAt else { return stable }
            if now.timeIntervalSince(lastAt) > Self.maximumGap { reset() }
        }
        lastAt = now
        guard outcome.isConfirmed else {
            reset()
            lastAt = now
            stable = outcome
            return stable
        }
        if outcome.posture == stable.posture {
            stable = outcome
            clearPending()
            return stable
        }
        if pendingState != outcome.posture {
            pendingState = outcome.posture
            pendingSince = now
            pendingSamples = 0
        }
        pendingSamples += 1
        let duration = outcome.posture == .bad ? Self.badConfirmation : Self.goodConfirmation
        if let pendingSince, pendingSamples >= Self.minimumSamples,
           now.timeIntervalSince(pendingSince) + 0.000001 >= duration {
            stable = outcome
            badSince = outcome.posture == .bad ? pendingSince : nil
            clearPending()
        } else if !stable.isConfirmed {
            // A visible person awaiting confirmation is not an empty chair.
            stable = .none(peopleCount: outcome.peopleCount)
        }
        return stable
    }

    private mutating func clearPending() {
        pendingState = nil
        pendingSince = nil
        pendingSamples = 0
    }

    mutating func reset() {
        stable = .none(peopleCount: 0)
        badSince = nil
        lastAt = nil
        clearPending()
    }
}

/// Detection sensitivity: how confidently the model must match before the notch
/// reports a posture. Lower values help in dim light or off-axis seating.
enum PostureSensitivity: String, CaseIterable, Sendable, Identifiable {
    case strict
    case standard
    case relaxed
    case sensitive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strict: return "Strict"
        case .standard: return "Regular"
        case .relaxed: return "Relaxed"
        case .sensitive: return "Sensitive"
        }
    }

    var threshold: Float {
        switch self {
        case .strict: return 0.60
        case .standard: return 0.50
        case .relaxed: return 0.40
        case .sensitive: return 0.30
        }
    }

    /// Standard is the out-of-the-box default: it matches the reference viewer in
    /// good light while still detecting in dim rooms where 0.60 never fires.
    static let defaultSensitivity = PostureSensitivity.standard
}

/// How often a bad posture is repeated while it continues.
enum PostureAlertRepeat: String, CaseIterable, Sendable, Identifiable {
    case once
    case periodic
    case continuous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: return "Once"
        case .periodic: return "Every 45 s"
        case .continuous: return "Continuous"
        }
    }

    /// nil means the reminder fires once per episode and then stays quiet.
    var interval: TimeInterval? {
        switch self {
        case .once: return nil
        case .periodic: return 45
        case .continuous: return 4
        }
    }

    static let defaultRepeat = PostureAlertRepeat.periodic
}

/// Decides when a bad-posture reminder is due: once when the episode starts,
/// then again every `repeatInterval` while it continues.
struct PostureAlertPolicy: Equatable {
    var repeatInterval: TimeInterval?
    private var episodeActive = false
    private var lastAlertAt: Date?

    init(repeatInterval: TimeInterval? = PostureAlertRepeat.defaultRepeat.interval) {
        self.repeatInterval = repeatInterval
    }

    mutating func evaluate(active: Bool, enabled: Bool, now: Date) -> Bool {
        guard active else {
            episodeActive = false
            lastAlertAt = nil
            return false
        }
        guard enabled else {
            episodeActive = false
            return false
        }
        let isNewEpisode = !episodeActive
        episodeActive = true
        guard !isNewEpisode else {
            lastAlertAt = now
            return true
        }
        guard let repeatInterval,
              let lastAlertAt,
              now.timeIntervalSince(lastAlertAt) >= repeatInterval else { return false }
        self.lastAlertAt = now
        return true
    }

    mutating func reset() {
        episodeActive = false
        lastAlertAt = nil
    }
}
