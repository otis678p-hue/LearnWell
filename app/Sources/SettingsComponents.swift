import SwiftUI

/// Page scaffold: eyebrow, large title, subtitle, then cards.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var eyebrow: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: NotchDesign.Spacing.section) {
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow {
                    Text(LocalizedStringKey(eyebrow))
                        .font(NotchDesign.Typography.eyebrow)
                        .tracking(0.9)
                        .textCase(.uppercase)
                        .foregroundStyle(NotchDesign.Palette.eyebrow)
                }

                Text(LocalizedStringKey(title))
                    .font(NotchDesign.Typography.pageTitle)
                    .foregroundStyle(NotchDesign.Palette.text)

                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(NotchDesign.Typography.pageSubtitle)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hairline card that holds a set of rows.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(LocalizedStringKey(title))
                    .font(NotchDesign.Typography.eyebrow)
                    .tracking(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(NotchDesign.Palette.eyebrow)
                    .padding(.leading, 2)
            }

            VStack(alignment: .leading, spacing: NotchDesign.Spacing.row) {
                content()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()

            if let footnote {
                Text(LocalizedStringKey(footnote))
                    .font(NotchDesign.Typography.caption)
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Title + subtitle + leading glyph, used on the left of a row.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var statusMark: PostureStatusMark.State? = nil
    var tint: Color = NotchDesign.Palette.secondaryText

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let statusMark {
                PostureStatusMark(state: statusMark)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(NotchDesign.Typography.cardTitle)
                    .foregroundStyle(NotchDesign.Palette.text)

                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Colour-coded status line with a trailing dot.
struct SettingsStatusRow: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var statusMark: PostureStatusMark.State? = nil
    var tint: Color = .green

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowLabel(
                title: title,
                subtitle: subtitle,
                symbol: symbol,
                statusMark: statusMark,
                tint: tint
            )

            Spacer(minLength: 12)

            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
        }
    }
}

/// Hairline between rows inside a card.
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(NotchDesign.Palette.hairline)
            .frame(height: 1)
            .padding(.leading, 32)
    }
}
