import AppKit
import Foundation
import SwiftUI

enum NotchWingContent: String, CaseIterable, Identifiable {
    case posture
    case temperature
    case humidity
    case temperatureHumidity
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posture: return "Posture detection"
        case .temperature: return "Temperature"
        case .humidity: return "Humidity"
        case .temperatureHumidity: return "Temperature & Humidity"
        case .hidden: return "Hidden"
        }
    }

    var symbol: String {
        switch self {
        case .posture: return "figure.seated.side"
        case .temperature: return "thermometer.medium"
        case .humidity: return "humidity"
        case .temperatureHumidity: return "thermometer.medium"
        case .hidden: return "eye.slash"
        }
    }

    /// Missing or expired climate data never appears as a current measurement.
    func climateValueText(in snapshot: PostureSnapshot) -> String {
        guard snapshot.environmentState == .live else { return "—" }
        switch self {
        case .temperature:
            guard let value = snapshot.temperatureC, value.isFinite else { return "—" }
            return String(format: "%.1f°C", value)
        case .humidity:
            guard let value = snapshot.humidityPercent, value.isFinite else { return "—" }
            return String(format: "%.1f%%", value)
        case .temperatureHumidity:
            return "\(Self.temperature.climateValueText(in: snapshot)) · \(Self.humidity.climateValueText(in: snapshot))"
        case .posture, .hidden:
            return "—"
        }
    }

}




enum AppPromptRecovery {
    case resetAccessibility
}

struct AppUpdatePrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let recovery: AppPromptRecovery?

    init(
        title: String,
        message: String,
        recovery: AppPromptRecovery? = nil
    ) {
        self.title = title
        self.message = message
        self.recovery = recovery
    }
}


/// How the notch reminds you to get up. Both modes share one switch, so only
/// one of them can ever be armed.
enum PostureRestReminderMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case interval
    case cycle

    static let defaultMode: PostureRestReminderMode = .interval

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interval: return "Interval reminder"
        case .cycle: return "Focus / rest rhythm"
        }
    }

    var symbol: String {
        switch self {
        case .interval: return "figure.walk"
        case .cycle: return "circle.hexagongrid"
        }
    }
}

enum SystemHUDKind: Hashable {
    case posture
    case cycle
}

enum SystemHUDAccent: Equatable {
    case neutral
    case positive
    case negative
    /// Neither good nor bad, e.g. "Too close".
    case warning
}

struct SystemHUDSnapshot: Identifiable, Equatable {
    let id = UUID()
    let kind: SystemHUDKind
    let title: String
    let subtitle: String
    let symbol: String
    let value: Double?
    var accent: SystemHUDAccent = .neutral

    static func restReminder(title: String, subtitle: String) -> SystemHUDSnapshot {
        SystemHUDSnapshot(
            kind: .posture,
            title: title,
            subtitle: subtitle,
            symbol: "figure.walk",
            value: nil,
            accent: .warning
        )
    }

    static func posture(_ alert: PostureAlert) -> SystemHUDSnapshot {
        SystemHUDSnapshot(
            kind: .posture,
            title: alert.title,
            subtitle: alert.subtitle,
            symbol: alert.kind == .tooClose ? "ruler" : "figure.seated.side",
            value: nil,
            accent: alert.isPositive
                ? .positive
                : (alert.kind == .tooClose ? .warning : .negative)
        )
    }

}

enum ServiceHealth: Equatable {
    case loading(String)
    case ready(String)
    case warning(String)
    case failed(String)

    var message: String {
        switch self {
        case .loading(let message), .ready(let message),
             .warning(let message), .failed(let message):
            return message
        }
    }

    var symbol: String {
        switch self {
        case .loading:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .loading:
            return .secondaryLabelColor
        case .ready:
            return .systemGreen
        case .warning:
            return .systemOrange
        case .failed:
            return .systemRed
        }
    }
}

