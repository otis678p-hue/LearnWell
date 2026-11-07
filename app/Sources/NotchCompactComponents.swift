import AppKit
import SwiftUI

/// One wing of the compact notch, sized for its selected sensor reading.
struct CompactWingSlot: View {
    @ObservedObject var model: AppModel
    let content: NotchWingContent

    var body: some View {
        Group {
            switch content {
            case .posture:
                PostureStatusRing(
                    snapshot: model.posture,
                    diameter: 22,
                    colors: model.postureColors
                )
                    .frame(width: 37, height: 37)
                    .foregroundStyle(.white)
                    .help(model.postureDetailText)
                    .accessibilityLabel(
                        Text(LocalizedStringKey(model.posture.title))
                    )
            case .temperature, .humidity:
                NotchClimateReading(model: model, content: content)
            case .temperatureHumidity:
                NotchCombinedClimateReading(model: model)
            case .hidden:
                Color.clear
            }
        }
        .frame(width: NotchLayout.compactWingWidth(for: content), height: 37)
    }
}

/// Shared with the appearance preview so it matches the real notch exactly.
struct NotchClimateReading: View {
    @ObservedObject var model: AppModel
    let content: NotchWingContent
    var expanded = false

    private var value: String { content.climateValueText(in: model.posture) }
    private var description: String {
        "\(model.localized(content.title)): \(value) · \(model.environmentDetailText)"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: content.symbol)
                .font(.system(size: expanded ? 11 : 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.localized(content.title))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    reading.font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            } else {
                reading.font(.system(size: 11, weight: .semibold, design: .rounded))
            }
        }
        .padding(.horizontal, expanded ? 0 : 5)
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
    }

    private var reading: some View {
        Text(value)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(model.posture.environmentState == .live ? 0.95 : 0.45))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

/// Both measurements fit in one wing as two compact rows.
struct NotchCombinedClimateReading: View {
    @ObservedObject var model: AppModel

    private var description: String {
        "\(model.localized(NotchWingContent.temperature.title)): \(NotchWingContent.temperature.climateValueText(in: model.posture)), \(model.localized(NotchWingContent.humidity.title)): \(NotchWingContent.humidity.climateValueText(in: model.posture)) · \(model.environmentDetailText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            NotchClimateReading(model: model, content: .temperature)
            NotchClimateReading(model: model, content: .humidity)
        }
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
    }
}
