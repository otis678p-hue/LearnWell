import SwiftUI

/// Calendar bars can be previewed using sample records without the live app.
struct PostureTrendView: View {
    let records: [PostureDayRecord]
    let today: PostureStats
    @Binding var range: PostureTrendRange
    let goodColor: Color
    let badColor: Color
    var now: Date = Date()
    @Environment(\.locale) private var locale
    @State private var anchor: Date?
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var showingDatePicker = false
    @State private var pickerDate = Date()

    private var language: AppLanguage {
        locale.language.languageCode?.identifier == "en" ? .english : .traditionalChinese
    }
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }
    private var trend: PostureTrend {
        PostureTrendBuilder.trend(range: range, records: records, today: today, anchor: anchor, now: now)
    }
    private var navigation: PostureTrendNavigation {
        PostureTrendNavigation(records: records, now: now, calendar: calendar)
    }

    var body: some View {
        let trend = self.trend
        SettingsGroup(
            title: "Trends",
            footnote: "Bar height shows tracked time; colors show the good/bad split. Best and worst compare each hour’s combined share in this period after at least 3 minutes of detection. Both may be the same slot."
        ) {
            HStack {
                rangePicker
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(trend.hasData ? "\(Int((trend.goodFraction * 100).rounded()))%" : "—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("Good share").font(NotchDesign.Typography.eyebrow)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                }
            }
            periodPicker(trend)
            chart(trend)
            legend(trend)
            detail(trend)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                slot(title: "Best slot", value: trend.best, isBest: true)
                slot(title: "Worst slot", value: trend.worst, isBest: false)
            }
        }
        .foregroundStyle(NotchDesign.Palette.text)
        .onChange(of: range) { _, _ in clearSelection() }
        .onChange(of: trend.start) { _, _ in clearSelection() }
    }

    private var rangePicker: some View {
        HStack(spacing: 5) {
            ForEach(PostureTrendRange.allCases) { option in
                Button { range = option } label: {
                    Text(LocalizedStringKey(option.title))
                        .font(.system(size: 11, weight: range == option ? .semibold : .regular))
                        .foregroundStyle(range == option ? .white : NotchDesign.Palette.text)
                        .frame(minWidth: 30, minHeight: 24)
                        .background(range == option ? NotchDesign.Palette.selected : NotchDesign.Palette.track,
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(range == option ? .isSelected : [])
            }
        }
    }

    private func periodPicker(_ trend: PostureTrend) -> some View {
        return HStack(spacing: 10) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
                .disabled(navigation.shifted(-1, range: range, anchor: anchor) == nil)
                .help(Text("Previous period"))
                .accessibilityLabel(Text("Previous period"))
                .accessibilityIdentifier("posture.trend.previous")
            Button {
                pickerDate = navigation.clamped(anchor ?? now)
                showingDatePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(periodTitle(trend)).monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 9).frame(height: 28)
                .background(NotchDesign.Palette.track, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .help(Text("Choose date"))
            .accessibilityLabel(Text("Choose date"))
            .accessibilityValue(periodTitle(trend))
            .accessibilityIdentifier("posture.trend.date")
            .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) { datePicker }
            Button { move(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
                .disabled(navigation.shifted(1, range: range, anchor: anchor) == nil)
                .help(Text("Next period"))
                .accessibilityLabel(Text("Next period"))
                .accessibilityIdentifier("posture.trend.next")
            Spacer(minLength: 0)
            if anchor != nil {
                Button("Current period") { anchor = nil; clearSelection() }
                    .font(NotchDesign.Typography.caption)
                    .accessibilityIdentifier("posture.trend.current")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(NotchDesign.Palette.secondaryText)
    }

    private var datePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose date").font(.headline)
            DatePicker("Choose date", selection: $pickerDate,
                       in: navigation.minimumDate...navigation.maximumDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .accessibilityIdentifier("posture.trend.calendar")
            HStack {
                Button("Today") {
                    anchor = nil
                    showingDatePicker = false
                    clearSelection()
                }
                Spacer()
                Button("Apply") {
                    anchor = navigation.clamped(pickerDate)
                    showingDatePicker = false
                    clearSelection()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("posture.trend.applyDate")
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func chart(_ trend: PostureTrend) -> some View {
        let peak = max(1, trend.bars.map(\.total).max() ?? 0)
        let activeID = hoveredID ?? selectedID
        return VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(trend.bars) { bar in
                    Button { selectedID = selectedID == bar.id ? nil : bar.id } label: {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(NotchDesign.Palette.track).frame(height: 4)
                            if bar.hasData {
                                let height = max(4, 96 * bar.total / peak)
                                VStack(spacing: 0) {
                                    badColor.frame(height: height * (1 - bar.goodFraction))
                                    goodColor.frame(height: height * bar.goodFraction)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        .padding(.horizontal, trend.bars.count < 13 ? 5 : 0)
                        .frame(maxWidth: .infinity).frame(height: 100, alignment: .bottom)
                        .background(activeID == bar.id ? NotchDesign.Palette.track : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredID = $0 ? bar.id : (hoveredID == bar.id ? nil : hoveredID) }
                    .help(barDetails(bar))
                    .accessibilityLabel(barDetails(bar))
                    .accessibilityAddTraits(activeID == bar.id ? .isSelected : [])
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(trend.bars.enumerated()), id: \.element.id) { index, bar in
                    Text(axisTitle(bar, index: index))
                        .font(.system(size: range == .week ? 10 : 8, weight: bar.isCurrent ? .bold : .regular))
                        .foregroundStyle(bar.isCurrent ? NotchDesign.Palette.text : NotchDesign.Palette.eyebrow)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func legend(_ trend: PostureTrend) -> some View {
        HStack(spacing: 6) {
            Circle().fill(goodColor).frame(width: 6, height: 6)
            Text("Good")
            Text(duration(trend.good))
            Circle().fill(badColor).frame(width: 6, height: 6).padding(.leading, 8)
            Text("Bad")
            Text(duration(trend.bad))
            Spacer(minLength: 0)
            Text(language.localizedFormat("Tracked %@", duration(trend.trackedSeconds)))
        }
        .font(NotchDesign.Typography.caption)
        .foregroundStyle(NotchDesign.Palette.secondaryText)
        .monospacedDigit()
    }

    private func detail(_ trend: PostureTrend) -> some View {
        let id = hoveredID ?? selectedID
        let active = trend.bars.first { $0.id == id }
        return Text(active.map(barDetails) ?? language.localized(trend.hasData
            ? "Hover or select a bar to see its tracked time and posture split."
            : "No detection data for this period. Enable background detection to start tracking."))
            .font(NotchDesign.Typography.caption)
            .foregroundStyle(NotchDesign.Palette.secondaryText)
            .frame(minHeight: 28, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func slot(title: String, value: PostureSlotSummary?, isBest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title)).font(NotchDesign.Typography.eyebrow)
                .foregroundStyle(NotchDesign.Palette.eyebrow)
            if let value {
                Text(value.title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(language.localizedFormat(isBest ? "Good %d%%" : "Bad %d%%", isBest ? value.percent : value.badPercent)
                     + " · " + language.localizedFormat("Tracked %@", duration(value.total)))
                    .font(NotchDesign.Typography.caption)
                    .foregroundStyle(isBest ? goodColor : badColor)
            } else {
                Text("—").font(.system(size: 13, weight: .semibold))
                Text("Shown after 3 minutes of tracked time per slot").font(NotchDesign.Typography.caption)
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func axisTitle(_ bar: PostureTrendBar, index: Int) -> String {
        if range == .week {
            return language.localized(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][index])
        }
        // Numeric hour/day labels need no translation; the week initials resolve
        // through language.localized so English never shows Chinese characters.
        if bar.label.isEmpty { return bar.label }
        return language.localized(bar.label)
    }
    private func duration(_ seconds: Double) -> String {
        seconds < 60 ? language.localizedFormat("%d sec", Int(seconds.rounded())) : PostureStats.empty.minutes(seconds)
    }
    private func barDetails(_ bar: PostureTrendBar) -> String {
        guard bar.hasData else { return bar.title + " · " + language.localized("No data") }
        return bar.title + " · " + language.localizedFormat("Good %d%%", Int((bar.goodFraction * 100).rounded()))
            + " · " + language.localizedFormat("Good %@ · Bad %@ · Tracked %@", duration(bar.good), duration(bar.bad), duration(bar.total))
    }
    private func periodTitle(_ trend: PostureTrend) -> String {
        switch range {
        case .day: return dayKey(trend.start)
        case .week: return dayKey(trend.start) + " – " + dayKey(calendar.date(byAdding: .day, value: -1, to: trend.end)!)
        case .month: return String(dayKey(trend.start).prefix(7))
        case .year: return String(dayKey(trend.start).prefix(4))
        }
    }
    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    private func move(_ step: Int) {
        guard let date = navigation.shifted(step, range: range, anchor: anchor) else { return }
        anchor = date
        clearSelection()
    }
    private func clearSelection() { selectedID = nil; hoveredID = nil }
}
