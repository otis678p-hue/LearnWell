import AppKit
import SwiftUI

/// One navigable row in the settings sidebar.
struct SettingsSidebarItem: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
}

/// A titled group of sidebar rows; the title is optional so "About" can sit
/// alone at the bottom without a heading.
struct SettingsSidebarSection: Identifiable {
    let id: String
    let title: String?
    let items: [SettingsSidebarItem]
}

/// The settings window's left column.
///
/// Split out of SettingsRootView so the collapse animation lives in one place
/// and can be rendered on its own. The collapse runs through an explicit
/// transaction (see toggle) rather than an animation modifier on this view:
/// the hairline and the detail pane are siblings, so unless the transaction is
/// pushed from the state change they jump to their final width instantly while
/// the column is still sliding — that is what tore the edge apart before.
struct SettingsSidebar: View {
    let title: String
    let subtitle: String
    let sections: [SettingsSidebarSection]
    let footer: [SettingsSidebarItem]
    @Binding var selection: String
    @Binding var collapsed: Bool
    let language: AppLanguage
    /// Already reduced-motion aware; supplied by the window.
    let animation: Animation

    @State private var hovered: String?

    static let expandedWidth: CGFloat = 216
    static let collapsedWidth: CGFloat = 64
    /// Width, label fade and icon re-centring share this curve so none of them
    /// arrives before the others.
    static let collapseAnimation = Animation.timingCurve(0.22, 0.72, 0, 1, duration: 0.24)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ForEach(sections) { section in
                sectionView(section)
            }

            Spacer(minLength: 12)

            sectionView(SettingsSidebarSection(id: "footer", title: nil, items: footer))
                .padding(.bottom, 4)
        }
        .frame(width: collapsed ? Self.collapsedWidth : Self.expandedWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        // Nothing may spill past the hairline while the column is narrowing.
        .clipped()
        .animation(animation, value: collapsed)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if !collapsed {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(NotchDesign.Palette.text)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(NotchDesign.Palette.eyebrow)
                }
                .lineLimit(1)
                // Shrinks like everything else in the column: a fixed minimum
                // width here would push the whole window past its frame and
                // cut the column off at the screen edge instead.
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .transition(.opacity)
            }

            Button(action: toggle) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help(language.localized(collapsed ? "Expand sidebar" : "Collapse sidebar"))
            .accessibilityLabel(language.localized(collapsed ? "Expand sidebar" : "Collapse sidebar"))
            .accessibilityIdentifier("settings.sidebar.toggle")
        }
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .padding(.horizontal, collapsed ? 12 : 20)
        .padding(.top, 26)
        .padding(.bottom, 22)
    }

    private func toggle() {
        withAnimation(animation) {
            collapsed.toggle()
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SettingsSidebarSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let heading = section.title, !collapsed {
                Text(LocalizedStringKey(heading))
                    .font(NotchDesign.Typography.eyebrow)
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(NotchDesign.Palette.eyebrow)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .padding(.horizontal, 22)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            ForEach(section.items) { item in
                row(item)
            }
        }
        .padding(.bottom, 16)
    }

    private func row(_ item: SettingsSidebarItem) -> some View {
        let isSelected = selection == item.id
        let isHovered = hovered == item.id
        return Button {
            selection = item.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: collapsed ? 14 : 12, weight: .medium))
                    .frame(width: 16)

                if !collapsed {
                    Text(LocalizedStringKey(item.title))
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Flexible, clipped frame: the label is cut at the
                        // row edge instead of pushing the icon off-centre or
                        // bleeding past the sidebar while it slides shut.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                        .transition(.opacity)
                }
            }
            .foregroundStyle(isSelected ? Color.white : NotchDesign.Palette.text)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .frame(height: collapsed ? 40 : 32)
            .background(
                isSelected
                    ? NotchDesign.Palette.selected
                    : (isHovered ? Color.black.opacity(0.05) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(language.localized(item.title))
        .accessibilityLabel(language.localized(item.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.navigation.\(item.id)")
        .onHover { inside in
            if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
        }
        .padding(.horizontal, 10)
    }
}
