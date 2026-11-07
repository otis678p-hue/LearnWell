import AppKit
import SwiftUI

/// Every "stand up" reminder lives in one card: the plain interval, and the
/// focus / rest rhythm. They used to be two cards that swapped places on the
/// Health page, and turning the rhythm on silently replaced the interval — so
/// the choice is now one switch plus an explicit mode.
struct PostureRestRhythmCard: View {
    @ObservedObject var model: AppModel

    /// Pending text for the interval mode's free-form field; it only reaches
    /// the model when the user confirms, so a half-typed value never arms a
    /// reminder.
    @State private var draftMinutes: Int = 0

    private var mode: PostureRestReminderMode { model.restReminderMode }
    private var cycle: PostureCycle { model.postureCycle }
    private var settings: PostureCycleSettings { model.postureCycleSettings }
    private var stats: PostureStats { model.postureStats }

    private var isResting: Bool { cycle.phase == .rest }

    private var tint: Color {
        isResting ? model.postureColors.warning : model.postureColors.good
    }

    private static let intervalPresets: [Int] = [20, 30, 45, 60]
    private static let minimumMinutes = 1
    private static let maximumMinutes = 600

    var body: some View {
        SettingsGroup(title: "Rest reminder", footnote: footnote) {
            masterRow

            SettingsRowDivider()

            modeRow

            if model.restReminderActive {
                SettingsRowDivider()

                if mode == .cycle {
                    cycleDetails
                } else {
                    intervalDetails
                }
            }
        }
    }

    // MARK: - Rows

    private var masterRow: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(
                title: "Enable rest reminder",
                subtitle: mode == .cycle
                    ? "After a stretch of focus the notch asks you to rest, then returns you to focus."
                    : "Based on continuous sitting time, not the daily total.",
                symbol: mode.symbol
            )

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { model.restReminderActive },
                set: { model.setRestReminderActive($0) }
            ))
            .labelsHidden()
            .accessibilityLabel(model.localized("Enable rest reminder"))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var modeRow: some View {
        HStack(spacing: 12) {
            Text("Reminder mode")
                .font(NotchDesign.Typography.cardTitle)
                .foregroundStyle(NotchDesign.Palette.text)

            Spacer(minLength: 12)

            Picker("Reminder mode", selection: Binding(
                get: { mode },
                set: { model.setRestReminderMode($0) }
            )) {
                ForEach(PostureRestReminderMode.allCases) { option in
                    Text(LocalizedStringKey(option.title)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 260)
            .accessibilityLabel(model.localized("Reminder mode"))
        }
    }

    // MARK: - Focus / rest rhythm

    private var cycleDetails: some View {
        VStack(alignment: .leading, spacing: NotchDesign.Spacing.row) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(cycle.countdownText)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchDesign.Palette.text)
                        .monospacedDigit()
                    Text(model.localized(cycle.phase.title))
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    progressBar

                    Text(model.localizedFormat(
                        "%d cycles completed today",
                        cycle.completedToday
                    ))
                    .font(NotchDesign.Typography.eyebrow)
                    .foregroundStyle(NotchDesign.Palette.eyebrow)
                }

                Spacer(minLength: 0)

                Button(isResting
                       ? model.localized("Skip break")
                       : model.localized("Take a break now")) {
                    if isResting {
                        model.skipPostureRest()
                    } else {
                        model.startPostureBreakNow()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            PostureCycleDurationPicker(
                title: "Focus",
                minutes: settings.focusMinutes,
                presets: PostureCycleSettings.focusPresets,
                language: model.appLanguage,
                onSelect: model.setPostureCycleFocus
            )

            PostureCycleDurationPicker(
                title: "Break",
                minutes: settings.breakMinutes,
                presets: PostureCycleSettings.breakPresets,
                language: model.appLanguage,
                onSelect: model.setPostureCycleBreak
            )
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(NotchDesign.Palette.track)
                if cycle.progress > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * cycle.progress))
                }
            }
        }
        .frame(height: 8)
    }

    // MARK: - Interval reminder

    private var intervalDetails: some View {
        VStack(alignment: .leading, spacing: NotchDesign.Spacing.row) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats.countdownText(until: model.restReminderMinutes))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchDesign.Palette.text)
                        .monospacedDigit()
                    (Text(LocalizedStringKey("Until next reminder · sitting"))
                        + Text(" " + stats.sittingText))
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                }

                Spacer(minLength: 12)

                intervalChips
            }

            if intervalIsCustom {
                customIntervalRow
            }
        }
    }

    /// What the field shows: the pending draft, or the remembered custom value.
    private var effectiveDraft: Int {
        let stored = draftMinutes == 0
            ? Int(model.restReminderCustomMinutes.rounded())
            : draftMinutes
        return min(max(stored, Self.minimumMinutes), Self.maximumMinutes)
    }

    /// True when the field holds a value that has not been applied yet.
    private var hasPendingEdit: Bool {
        model.restReminderUsesCustom
            && effectiveDraft != Int(model.restReminderMinutes.rounded())
    }

    private var intervalMinutes: Int {
        Int(model.restReminderMinutes.rounded())
    }

    private var intervalIsCustom: Bool {
        model.restReminderUsesCustom || !Self.intervalPresets.contains(intervalMinutes)
    }

    private var customMinutes: Binding<Int> {
        Binding(
            get: { effectiveDraft },
            set: { draftMinutes = min(max($0, Self.minimumMinutes), Self.maximumMinutes) }
        )
    }

    private var intervalChips: some View {
        HStack(spacing: 5) {
            ForEach(Self.intervalPresets, id: \.self) { value in
                chip(
                    label: "\(value)",
                    selected: !intervalIsCustom && intervalMinutes == value
                ) {
                    model.selectRestReminderPreset(Double(value))
                }
            }
            chip(label: "Custom", selected: intervalIsCustom) {
                draftMinutes = Int(model.restReminderCustomMinutes.rounded())
                model.selectRestReminderCustom()
            }
        }
    }

    private var customIntervalRow: some View {
        HStack(spacing: 8) {
            Text("Custom interval")
                .font(NotchDesign.Typography.caption)
                .foregroundStyle(NotchDesign.Palette.secondaryText)

            TextField("", value: customMinutes, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 54)
                .controlSize(.small)

            Text("min")
                .font(NotchDesign.Typography.caption)
                .foregroundStyle(NotchDesign.Palette.secondaryText)

            Stepper(
                "Custom interval",
                value: customMinutes,
                in: Self.minimumMinutes...Self.maximumMinutes,
                step: 1
            )
            .labelsHidden()
            .controlSize(.small)

            if hasPendingEdit {
                Button("Confirm") {
                    model.setRestReminderCustomMinutes(effectiveDraft)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
    }

    private func chip(
        label: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : NotchDesign.Palette.text)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(
                    selected
                        ? NotchDesign.Palette.selected
                        : NotchDesign.Palette.track,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Copy

    private var footnote: String {
        switch (mode, model.restReminderActive) {
        case (.cycle, true):
            return model.localized("Replaces interval reminders. Focus counts detected sitting time and resets after 2 minutes away. Breaks continue through sleep and app restarts.")
        case (.cycle, false):
            return model.localized("Replaces the plain interval reminder. Standing up or leaving the frame for 2 minutes restarts the focus phase; the break counts down in real time.")
        case (.interval, true):
            return model.localized("Once you have sat for the set time the notch asks you to stand up; leaving the frame for 2 minutes restarts the count. Confirm applies a new interval.")
        case (.interval, false):
            return model.localized("When on, the notch asks you to stand up once you have sat for the set time.")
        }
    }
}

/// Keep typing separate from the live timer; only a valid, explicitly applied value changes it.
private struct PostureCycleDurationPicker: View {
    let title: String
    let minutes: Double
    let presets: [Int]
    let language: AppLanguage
    let onSelect: (Double) -> Void
    @State private var customSelected = false
    @State private var draft: String?

    private var isCustom: Bool {
        customSelected || !presets.contains(where: { Double($0) == minutes })
    }

    private var input: Binding<String> {
        Binding(
            get: { draft ?? String(Int(minutes)) },
            set: { draft = $0 }
        )
    }

    private var validMinutes: Int? {
        guard let value = Int(input.wrappedValue.trimmingCharacters(in: .whitespaces)),
              PostureCycleSettings.minuteRange.contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(LocalizedStringKey(title))
                    .font(NotchDesign.Typography.cardTitle)
                    .foregroundStyle(NotchDesign.Palette.text)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    ForEach(presets, id: \.self) { value in
                        chip(language.localizedFormat("%d min", value),
                             selected: !isCustom && minutes == Double(value)) {
                            customSelected = false
                            draft = nil
                            onSelect(Double(value))
                        }
                    }
                    chip(language.localized("Custom"), selected: isCustom) {
                        if !isCustom { draft = String(Int(minutes)) }
                        customSelected = true
                    }
                }
            }

            if isCustom {
                HStack(spacing: 8) {
                    Text("Custom time")
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)

                    TextField("", text: input)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 62)
                        .controlSize(.small)
                        .accessibilityLabel(language.localizedFormat("Custom %@ duration in minutes", language.localized(title)))
                        .onSubmit(apply)

                    Text("min")
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)

                    Button("Apply", action: apply)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(validMinutes == nil || Double(validMinutes ?? 0) == minutes)

                    Text(language.localizedFormat("%d–%d min",
                        PostureCycleSettings.minuteRange.lowerBound,
                        PostureCycleSettings.minuteRange.upperBound))
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(validMinutes == nil ? Color.red : NotchDesign.Palette.secondaryText)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func apply() {
        guard let value = validMinutes else { return }
        draft = String(value)
        onSelect(Double(value))
    }

    private func chip(
        _ label: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
