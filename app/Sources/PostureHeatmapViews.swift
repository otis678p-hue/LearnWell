import SwiftUI

/// Independent of the live tracker so previews never need camera access.
struct PostureHeatmapView: View {
    let heatmap: PostureHeatmap
    let tint: Color
    @Environment(\.locale) private var locale
    @State private var selectedID: String?
    @State private var hoveredID: String?
    private var language: AppLanguage {
        locale.language.languageCode?.identifier == "en" ? .english : .traditionalChinese
    }
    private var activeCell: PostureHeatmapCell? {
        let id = hoveredID ?? selectedID
        return heatmap.cells.first { $0.id == id } ?? heatmap.worst
    }

    var body: some View {
        SettingsGroup(
            title: "Time heatmap · this week",
            footnote: "Darker cells mean a higher bad-posture share. Cells need 3 minutes of detection to show color. Hover or select for details; the outline marks this week’s highest share."
        ) {
            HStack {
                Text("Weekday × hour").font(NotchDesign.Typography.cardTitle)
                Spacer()
                if let first = heatmap.dates.first, let last = heatmap.dates.last {
                    Text(first.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(locale))
                         + " – " + last.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(locale)))
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                }
            }
            grid
            legend
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                if let cell = activeCell {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(hoveredID == nil && selectedID == nil ? "Most slouching" : "Time slot details"))
                            .foregroundStyle(NotchDesign.Palette.secondaryText)
                        Text(slotTitle(cell)).fontWeight(.medium)
                        Spacer(minLength: 0)
                        Text(status(cell))
                            .foregroundStyle(cell.isQualified ? tint : NotchDesign.Palette.secondaryText)
                    }
                    if cell.hasData {
                        Text(language.localizedFormat(
                            "Good %@ · Bad %@ · Tracked %@",
                            duration(cell.good), duration(cell.bad), duration(cell.total)
                        )).foregroundStyle(NotchDesign.Palette.secondaryText)
                    }
                } else {
                    Text(LocalizedStringKey(heatmap.hasData
                        ? "No bad-posture slots with at least 3 minutes tracked yet."
                        : "No detection data this week. Enable background detection to start filling the heatmap."))
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                }
            }
            .font(NotchDesign.Typography.caption)
            .monospacedDigit()
            .frame(minHeight: 34, alignment: .topLeading)
        }
        .foregroundStyle(NotchDesign.Palette.text)
        .onChange(of: heatmap.dates.first) { _, _ in selectedID = nil; hoveredID = nil }
    }

    private var grid: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 4) {
            GridRow {
                Color.clear.frame(width: 30, height: 12)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 || hour == 23 ? String(format: "%02d", hour) : "")
                        .font(.system(size: 8, design: .rounded))
                        .foregroundStyle(NotchDesign.Palette.eyebrow)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<7, id: \.self) { weekday in
                GridRow {
                    Text(LocalizedStringKey(PostureHeatmap.weekdayTitles[weekday]))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                        .frame(width: 30, alignment: .leading)
                    ForEach(heatmap.cells.filter { $0.weekday == weekday }) { cell in cellButton(cell) }
                }
            }
        }
    }

    private func cellButton(_ cell: PostureHeatmapCell) -> some View {
        let highlighted = cell.id == activeCell?.id
        return Button {
            selectedID = selectedID == cell.id ? nil : cell.id
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(cell.isQualified ? tint.opacity(0.12 + 0.88 * cell.badFraction) : NotchDesign.Palette.track)
                .overlay {
                    if !cell.isQualified {
                        Text(cell.isFuture ? "–" : cell.hasData ? "·" : "")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(NotchDesign.Palette.eyebrow)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            highlighted ? NotchDesign.Palette.text : cell.id == heatmap.worst?.id ? tint : .clear,
                            lineWidth: 1.5
                        )
                }
                .frame(maxWidth: .infinity).frame(height: 20)
                .opacity(cell.isFuture ? 0.45 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? cell.id : (hoveredID == cell.id ? nil : hoveredID) }
        .help(details(cell))
        .accessibilityLabel(details(cell))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { scaleLegend; Spacer(minLength: 0); missingLegend }
            VStack(alignment: .leading, spacing: 6) { scaleLegend; missingLegend }
        }
        .font(.system(size: 10))
        .foregroundStyle(NotchDesign.Palette.secondaryText)
    }
    private var scaleLegend: some View {
        HStack(spacing: 5) {
            Text("Bad share")
            Text("0%")
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint.opacity(0.12 + 0.88 * Double(step) / 4))
                    .frame(width: 13, height: 8)
            }
            Text("100%")
        }
    }
    private var missingLegend: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(NotchDesign.Palette.track).frame(width: 10, height: 8)
            Text("No data")
            Text("·").fontWeight(.bold)
            Text("Under 3 min")
            Text("–")
            Text("Upcoming")
        }
    }
    private func slotTitle(_ cell: PostureHeatmapCell) -> String {
        language.localized(PostureHeatmap.weekdayTitles[cell.weekday]) + " " + cell.timeTitle
    }
    private func status(_ cell: PostureHeatmapCell) -> String {
        if cell.isFuture { return language.localized("Upcoming") }
        if !cell.hasData { return language.localized("No data") }
        let share = language.localizedFormat("Bad %d%%", cell.badPercent)
        return cell.isQualified ? share : share + " · " + language.localized("Under 3 min")
    }
    private func duration(_ seconds: Double) -> String {
        if seconds < 60 { return language.localizedFormat("%d sec", Int(seconds.rounded())) }
        return PostureStats.empty.minutes(seconds)
    }
    private func details(_ cell: PostureHeatmapCell) -> String {
        let base = cell.day + " · " + slotTitle(cell) + " · " + status(cell)
        guard cell.hasData else { return base }
        return base + " · " + language.localizedFormat(
            "Good %@ · Bad %@ · Tracked %@", duration(cell.good), duration(cell.bad), duration(cell.total)
        )
    }
}
