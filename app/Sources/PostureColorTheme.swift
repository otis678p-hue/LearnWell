import AppKit
import SwiftUI

/// A concrete set of posture colours: healthy, unhealthy and "too close".
///
/// Presets provide quick choices, but every channel stays customisable — the
/// value is what every surface renders, the presets only seed it.
struct PostureColors: Equatable, Sendable {
    var goodHex: String
    var badHex: String
    var warningHex: String

    static let classic = PostureColorTheme.classic.colors

    var good: Color { Color(hex: goodHex) ?? .green }
    var bad: Color { Color(hex: badHex) ?? .red }
    var warning: Color { Color(hex: warningHex) ?? .orange }
    var neutral: Color { Color(white: 0.55) }

    func color(for state: PostureState) -> Color {
        switch state {
        case .good: return good
        case .bad: return bad
        case .unknown: return neutral
        }
    }

    func color(for accent: SystemHUDAccent) -> Color {
        switch accent {
        case .positive: return good
        case .negative: return bad
        case .warning: return warning
        case .neutral: return neutral
        }
    }

    var matchingTheme: PostureColorTheme? {
        PostureColorTheme.allCases.first { $0.colors == self }
    }
}

/// Colour pairing presets used by every posture surface: the compact ring,
/// hover text, panel accents and the notch alert HUD.
enum PostureColorTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case classic
    case mintCoral
    case tealOrange
    case blueAmber
    case violetRose

    static let defaultTheme: PostureColorTheme = .classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Green & Red"
        case .mintCoral: return "Mint Coral"
        case .tealOrange: return "Teal Orange"
        case .blueAmber: return "Blue Amber"
        case .violetRose: return "Violet Rose"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: return "System green / system red, highest contrast"
        case .mintCoral: return "Soft mint / coral, calmer on dark backgrounds"
        case .tealOrange: return "Teal / orange, still distinguishable with red-green colour blindness"
        case .blueAmber: return "Blue / amber, a high-contrast cool and warm pair"
        case .violetRose: return "Violet / rose, a cooler pairing"
        }
    }

    var colors: PostureColors {
        switch self {
        case .classic:
            return PostureColors(
                goodHex: "#30D159",
                badHex: "#FF453B",
                warningHex: "#FF9E0A"
            )
        case .mintCoral:
            return PostureColors(
                goodHex: "#5CE8C4",
                badHex: "#FF7A6E",
                warningHex: "#FFBF6B"
            )
        case .tealOrange:
            return PostureColors(
                goodHex: "#2ED4D1",
                badHex: "#FF8A00",
                warningHex: "#FFC93D"
            )
        case .blueAmber:
            return PostureColors(
                goodHex: "#4FA8FF",
                badHex: "#FFC200",
                warningHex: "#FF9E0A"
            )
        case .violetRose:
            return PostureColors(
                goodHex: "#9E8CFF",
                badHex: "#FF5CA3",
                warningHex: "#FF99C7"
            )
        }
    }
}

/// The three editable colour channels.
enum PostureColorRole: String, CaseIterable, Identifiable, Sendable {
    case good
    case bad
    case warning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .good: return "Good posture"
        case .bad: return "Bad posture"
        case .warning: return "Too close"
        }
    }

    var subtitle: String {
        switch self {
        case .good: return "Normal ring and alert icon colour"
        case .bad: return "Ring and alert colour for bad posture"
        case .warning: return "Alert colour when the sensor reports too close"
        }
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else {
            return nil
        }
        self.init(
            .sRGB,
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
            opacity: 1
        )
    }

    /// `#RRGGBB` in sRGB, suitable for persistence.
    var hexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
