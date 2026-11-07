import Foundation

// MARK: - Posture response function
//
// Extracted from Dorso 1.16.1 <https://github.com/tldev/dorso> (MIT, "Posturr
// Contributors"): `Sources/Core/PostureEngine.swift` (PostureMonitoringState,
// PostureConfig, processReading). The pieces that were tied to Dorso's blur overlay, menu bar
// and analytics are left behind; what stays is the pure response function.
//
// The shape is the same for every sensor:
//
//     samples -> (isBad, severity) -> response state -> notch verdict
//
//   * A detector converts one measurement into a *reading*: a boolean plus a
//     0...1 severity.
//   * `PostureResponse.process` turns a stream of readings into stable state:
//     N consecutive bad samples make the pose *leaning*, M consecutive good
//     samples clear it, and an onset delay separates leaning from *slouching*
//     (the pose worth a reminder). The severity becomes a 0...1 warning
//     intensity through an intensity exponent.
//
// The camera classifier supplies good/bad readings; the ultrasonic sensor
// supplies the proportional distance response in PostureBlurSettings.swift.

// MARK: - Reading

/// One posture measurement from any source, shaped like Dorso's `PostureReading`.
struct PostureResponseReading: Equatable, Sendable {
    var timestamp: Date
    /// True when this single sample looks like bad posture.
    var isBadPosture: Bool
    /// 0.0 (good) ... 1.0 (very bad), Dorso's `severity`.
    var severity: Double

    init(timestamp: Date = Date(), isBadPosture: Bool, severity: Double) {
        self.timestamp = timestamp
        self.isBadPosture = isBadPosture
        self.severity = max(0, min(1, severity))
    }

    static func good(at timestamp: Date = Date()) -> PostureResponseReading {
        PostureResponseReading(timestamp: timestamp, isBadPosture: false, severity: 0)
    }
}

// MARK: - Configuration

/// Dorso's `PostureConfig`. The two thresholds are sample counts rather than
/// seconds because Dorso compares consecutive frames; at the firmware's 5 Hz
/// telemetry rate the defaults below equal Dorso's 10 fps timing of 0.8 s and
/// 0.6 s, so a slouch has to survive a few noisy ultrasonic echoes first.
struct PostureResponseConfig: Equatable, Sendable {
    /// Consecutive bad samples needed before a slouch episode opens.
    var badSampleThreshold: Int = 4
    /// Consecutive good samples needed before that episode closes.
    var goodSampleThreshold: Int = 3
    /// Grace period after the episode opens before warnings become active
    /// (Dorso's `warningOnsetDelay`, the app's "Bad posture alert delay" setting).
    var warningOnsetDelay: TimeInterval = 0
    /// Warning intensity multiplier, 0.5 (gentle) ... 2 (sharp). Dorso's
    /// `intensity` slider: severity is raised to `1 / intensity`.
    var intensity: Double = 1

    /// A single bad echo is never enough, whatever the numbers say.
    var normalized: PostureResponseConfig {
        var copy = self
        copy.badSampleThreshold = max(1, badSampleThreshold)
        copy.goodSampleThreshold = max(1, goodSampleThreshold)
        return copy
    }
}

// MARK: - State

/// Dorso's `PostureMonitoringState`, minus the away/screen-lock bookkeeping
/// that belongs to a desktop app rather than to the sensor.
struct PostureResponseState: Equatable, Sendable {
    var consecutiveBadSamples: Int = 0
    var consecutiveGoodSamples: Int = 0
    /// The sample threshold is met: the reading looks like bad posture, but the
    /// onset delay may still be running. Dorso had no name for this because its
    /// blur and its menu bar icon always waited; the notch ring wants to show the
    /// pose as soon as it is stable, while the reminder still gets its grace period.
    var isLeaning: Bool = false
    /// Leaning *and* past the onset delay: the posture worth a reminder.
    var isSlouching: Bool = false
    /// When the current run of bad samples began.
    var badStartTime: Date?
    /// 0...1, Dorso's `postureWarningIntensity`: how strong the reminder may be.
    var warningIntensity: Double = 0

    mutating func reset() {
        consecutiveBadSamples = 0
        consecutiveGoodSamples = 0
        isLeaning = false
        isSlouching = false
        badStartTime = nil
        warningIntensity = 0
    }

    /// Bad posture that already outlasted the onset delay and is therefore worth
    /// a reminder. Also the value the Arduino's red LED follows.
    var shouldWarn: Bool { isSlouching }
}

// MARK: - Effects

/// What the response function asks the caller to do. Dorso also asked for the
/// blur overlay and for analytics intervals; those have no equivalent here —
/// the notch ring, the HUD and `PostureSessionTracker` read the state instead.
enum PostureResponseEffect: Equatable, Sendable {
    /// Presentation must be refreshed (ring colour, LED byte, statistics).
    case updatePresentation
    /// A slouch episode started; counts once per episode.
    case recordSlouchEvent
}

struct PostureResponseResult: Equatable, Sendable {
    var state: PostureResponseState
    var effects: [PostureResponseEffect]

    var isLeaning: Bool { state.isLeaning }
    var isSlouching: Bool { state.isSlouching }
    var warningIntensity: Double { state.warningIntensity }
    var didStartSlouchEpisode: Bool { effects.contains(.recordSlouchEvent) }
}

// MARK: - Engine

/// Dorso's `PostureEngine.processReading`, with side effects expressed as
/// values instead of callbacks so the whole function stays testable.
enum PostureResponse {
    static func process(
        _ reading: PostureResponseReading,
        state: PostureResponseState,
        config: PostureResponseConfig,
        now: Date? = nil
    ) -> PostureResponseResult {
        let config = config.normalized
        let now = now ?? reading.timestamp
        var newState = state
        var effects: [PostureResponseEffect] = []

        if reading.isBadPosture {
            newState.consecutiveBadSamples += 1
            newState.consecutiveGoodSamples = 0

            if newState.consecutiveBadSamples >= config.badSampleThreshold {
                newState.isLeaning = true
                if newState.badStartTime == nil {
                    newState.badStartTime = now
                }

                let startedAt = newState.badStartTime ?? now
                let onsetDelay = max(0, config.warningOnsetDelay)
                if now.timeIntervalSince(startedAt) >= onsetDelay {
                    if !newState.isSlouching {
                        newState.isSlouching = true
                        effects.append(.recordSlouchEvent)
                        effects.append(.updatePresentation)
                    }

                    // Dorso's intensity curve: low intensity flattens the ramp,
                    // high intensity makes a small slouch read as a strong one.
                    let rawIntensity = config.intensity
                    let intensity = rawIntensity > 0 ? rawIntensity : 1
                    let clampedSeverity = min(1, max(0, reading.severity))
                    newState.warningIntensity = pow(clampedSeverity, 1 / intensity)
                }
            }
        } else {
            newState.consecutiveGoodSamples += 1
            newState.consecutiveBadSamples = 0
            newState.badStartTime = nil
            newState.warningIntensity = 0

            if newState.consecutiveGoodSamples >= config.goodSampleThreshold, newState.isLeaning {
                newState.isLeaning = false
                newState.isSlouching = false
                effects.append(.updatePresentation)
            }
        }

        return PostureResponseResult(state: newState, effects: effects)
    }
}
