import Foundation

/// User-adjustable blur controls, kept separate from posture and LED thresholds.
struct PostureBlurSettings: Codable, Equatable {
    static let preferenceKey = "notch.posture.blurSettings"
    var intensity: Double = 1
    var distanceEnabled = true
    var startDistanceCM: Double = 50
    var fullDistanceCM: Double = 25
    var awayEnabled = false
    var awayDelay: TimeInterval = 5

    var normalized: Self {
        var value = self
        value.intensity = intensity.isFinite ? min(2, max(0.5, intensity)) : 1
        value.startDistanceCM = startDistanceCM.isFinite ? min(100, max(20, startDistanceCM)) : 50
        value.fullDistanceCM = fullDistanceCM.isFinite ? min(value.startDistanceCM - 5, max(5, fullDistanceCM)) : min(25, value.startDistanceCM - 5)
        value.awayDelay = awayDelay.isFinite ? min(60, max(1, awayDelay)) : 5
        return value
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.normalized
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }

    /// Dorso's strength curve; zero always stays clear.
    func adjustedIntensity(_ severity: Double) -> Double {
        guard severity.isFinite, severity > 0 else { return 0 }
        return pow(min(1, severity), 1 / normalized.intensity)
    }
}

/// The Arduino's ultrasonic sensor is the app's only *proportional* posture
/// input: the camera classifier answers good/bad, but a distance in centimetres
/// says how far past the line someone has leaned. The progressive blur uses it
/// as its severity ramp.
enum PostureDistanceResponse {
    /// Same line the firmware and the ring use for "too close".
    static let nearThresholdCM: Double = 50
    /// Distance over which the warning ramps from nothing to full strength.
    static let rampCM: Double = 25

    /// 0 at the threshold, 1 at `nearThresholdCM - rampCM` and beyond.
    static func severity(distanceCM: Double, startCM: Double = nearThresholdCM, fullCM: Double = nearThresholdCM - rampCM) -> Double {
        guard distanceCM.isFinite, distanceCM > 0, startCM.isFinite, fullCM.isFinite,
              fullCM > 0, startCM > fullCM else { return 0 }
        let over = startCM - distanceCM
        guard over > 0 else { return 0 }
        return min(1, over / (startCM - fullCM))
    }

    /// Severity held back until the pose has lasted the reminder delay, mirroring
    /// the camera path: no blur for a passing lean towards the keyboard.
    static func blurIntensity(distanceCM: Double, badSince: Date?, delay: TimeInterval, now: Date,
                              startCM: Double = nearThresholdCM, fullCM: Double = nearThresholdCM - rampCM) -> Double {
        let severity = severity(distanceCM: distanceCM, startCM: startCM, fullCM: fullCM)
        guard severity > 0, let badSince else { return 0 }
        let elapsed = now.timeIntervalSince(badSince)
        guard elapsed >= max(0, delay) else { return 0 }
        return severity
    }
}
