import AppKit
import SwiftUI

/// Daily goal plus the streak of days that met it.
struct PostureGoalCard: View {
    @ObservedObject var model: AppModel

    private var stats: PostureStats { model.postureStats }
    private var goal: PostureGoal { model.postureGoal }

    private var percent: Int {
        Int((stats.goodFraction * 100).rounded())
    }

    private var recentDays: [PostureDayCell] {
        model.postureHistory.recentDays(
            7,
            todayKey: stats.dayKey,
            todayMet: model.postureGoalMet
        )
    }

    private var pendingMinutes: Int {
        let remainingSeconds = max(0, goal.minimumMinutes * 60 - stats.trackedSeconds)
        return max(0, Int((remainingSeconds / 60).rounded(.up)))
    }

    var body: some View {
        SettingsGroup(
            title: "Today's goal",
            footnote: model.localizedFormat(
                "The goal only counts after %d minutes of tracked time; days settle at midnight and the last 400 are kept.",
                Int(goal.minimumMinutes)
            )
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(percent)%")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(NotchDesign.Palette.text)
                            .monospacedDigit()
                        Text("Good share")
                            .font(NotchDesign.Typography.eyebrow)
                            .foregroundStyle(NotchDesign.Palette.eyebrow)
                    }

                    Text(statusText)
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(statusTint)
                }

                Spacer(minLength: 12)

                streakBadge
            }

            goalBar

            recentStrip

            SettingsRowDivider()

            HStack(spacing: 12) {
                Text("Daily goal")
                    .font(NotchDesign.Typography.cardTitle)
                    .foregroundStyle(NotchDesign.Palette.text)

                Spacer(minLength: 12)

                HStack(spacing: 5) {
                    ForEach(PostureGoal.presets, id: \.self) { value in
                        goalChip(value)
                    }
                }
            }
        }
    }

    // MARK: pieces

    private var statusText: String {
        if stats.trackedSeconds < goal.minimumMinutes * 60 {
            return model.localizedFormat("%d more minutes to qualify", pendingMinutes)
        }
        if model.postureGoalMet {
            return model.localizedFormat("Goal met · target %d%%", goal.targetPercent)
        }
        let gap = max(0, goal.targetPercent - percent)
        return model.localizedFormat("%d points below target", gap)
    }

    private var statusTint: Color {
        if stats.trackedSeconds < goal.minimumMinutes * 60 {
            return NotchDesign.Palette.secondaryText
        }
        return model.postureGoalMet
            ? model.postureColors.good
            : model.postureColors.bad
    }

    private var streakBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.postureStreak > 0 ? Color.orange : NotchDesign.Palette.eyebrow)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.localizedFormat("%d days in a row", model.postureStreak))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchDesign.Palette.text)
                    .monospacedDigit()
                Text("Goal streak")
                    .font(NotchDesign.Typography.eyebrow)
                    .foregroundStyle(NotchDesign.Palette.eyebrow)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(NotchDesign.Palette.track, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var goalBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(NotchDesign.Palette.track)

                Capsule()
                    .fill(model.postureColors.good)
                    .frame(width: max(6, width * stats.goalProgressShare))

                // target marker
                Rectangle()
                    .fill(NotchDesign.Palette.text.opacity(0.55))
                    .frame(width: 2, height: 16)
                    .offset(x: max(0, width * goal.targetShare - 1))
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(LocalizedStringKey("Good share")) + Text(" \(percent)%")
        )
    }

    private var recentStrip: some View {
        HStack(spacing: 6) {
            ForEach(recentDays) { cell in
                VStack(spacing: 3) {
                    Circle()
                        .fill(cell.met ? model.postureColors.good : NotchDesign.Palette.track)
                        .frame(width: 9, height: 9)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    cell.isToday ? NotchDesign.Palette.text.opacity(0.45) : .clear,
                                    lineWidth: 1
                                )
                        }
                    Text(dayLabel(cell.day))
                        .font(.system(size: 8, design: .rounded))
                        .foregroundStyle(NotchDesign.Palette.eyebrow)
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(LocalizedStringKey("Days met in the last week")) + Text(" \(recentDays.filter(\.met).count)/7")
        )
    }

    private func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return key }
        return String(Int(parts[2]) ?? 0)
    }

    private func goalChip(_ value: Int) -> some View {
        let selected = goal.targetPercent == value
        return Button {
            model.setPostureGoalShare(Double(value) / 100)
        } label: {
            Text("\(value)%")
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : NotchDesign.Palette.text)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(
                    selected ? NotchDesign.Palette.selected : NotchDesign.Palette.track,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}
