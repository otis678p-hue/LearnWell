import AppKit
import Foundation

extension AppModel {
    /// Localised secondary line for the ring hover preview and panel header.
    var postureDetailText: String {
        detailText(for: posture)
    }

    func detailText(for snapshot: PostureSnapshot) -> String {
        switch snapshot.detail {
        case .confidence(let value):
            return "\(localized("Confidence")) \(Int((value * 100).rounded()))%"
        case .people(let count):
            return "\(localized("Multiple people detected")) · \(count)"
        case .arduino(let key), .message(let key):
            return localized(key)
        }
    }

    var environmentDetailText: String {
        if !postureMonitoringEnabled { return localized("Enable background monitoring to read temperature and humidity") }
        switch posture.arduino {
        case .disabled: return localized("Enable Arduino sensors")
        case .disconnected, .starting: return localized(posture.arduino.title)
        case .connected, .unresponsive: return localized(posture.environmentState.title)
        }
    }

    /// Restarts detection, asking for camera access again when the system allows it.
    func launchPostureMonitor() {
        if postureMonitoringEnabled {
            postureService.restart(enabled: detectionPolicy.shouldRun)
        } else {
            // Even when the switch flips on, the policy keeps the camera dark
            // while the screen is locked or the system is asleep.
            postureMonitoringEnabled = true
        }
    }


    func openPostureCameraPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}