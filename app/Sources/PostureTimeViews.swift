import AppKit
import SwiftUI

/// Today's posture totals and good/bad split; the weekly profile lives in PostureHeatmapCard.
///
/// The reference design used a hero number plus a bar strip; this keeps that
/// rhythm but uses the app's own card, hairline and rounded-numeral language.
struct PostureTimeStatsCard: View {
    @ObservedObject var model: AppModel

    private var stats: PostureStats { model.postureStats }

    private var percentGood: Int {
        Int((stats.goodFraction * 100).rounded())
    }

    var body: some View {
        SettingsGroup(
            title: "Posture time",
            footnote: stats.trackedSeconds < 60
                ? "Not enough detected time yet today; turn on background detection to start counting."
                : nil
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 26) {
                metric(
                    title: "Good",
                    value: stats.goodText,
                    tint: model.postureColors.good
                )

                metric(
                    title: "Bad",
                    value: stats.badText,
                    tint: model.postureColors.bad
                )

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(percentGood)%")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchDesign.Palette.text)
                        .monospacedDigit()
                    Text("Good share")
                        .font(NotchDesign.Typography.eyebrow)
                        .foregroundStyle(NotchDesign.Palette.eyebrow)
                }
            }

            splitBar

            HStack {
                Spacer(minLength: 0)
                Button("Reset today") { model.resetPostureStats() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
            }
        }
    }

    private func metric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(LocalizedStringKey(title))
                    .font(NotchDesign.Typography.eyebrow)
                    .tracking(0.6)
                    .foregroundStyle(NotchDesign.Palette.eyebrow)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchDesign.Palette.text)
                .monospacedDigit()
        }
    }

    private var splitBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = stats.trackedSeconds < 1 ? 0 : stats.goodFraction
            ZStack(alignment: .leading) {
                Capsule().fill(NotchDesign.Palette.track)
                if width > 0, fraction > 0 {
                    Capsule()
                        .fill(model.postureColors.good)
                        .frame(width: max(6, width * fraction))
                }
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(LocalizedStringKey("Good")) + Text(" \(stats.goodText), ")
                + Text(LocalizedStringKey("Bad")) + Text(" \(stats.badText)")
        )
    }


}
