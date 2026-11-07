import AppKit
import SwiftUI

struct ExpandedPanelSurface: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ExpandedPanel(model: model)
            .environment(\.appearsActive, true)
            .panelSurface(
                cornerRadius: NotchDesign.Radius.panel,
                contentSize: CGSize(
                    width: NotchLayout.expandedPanelWidth,
                    height: model.postureExpandedPanelHeight
                )
            )
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 8)
            .task {
                await Task.yield()
                guard !model.isPanelClosing else { return }
                withAnimation(reduceMotion ? .linear(duration: 0.12) : NotchDesign.Motion.panelOpen) {
                    isVisible = true
                }
            }
            .onChange(of: model.isPanelClosing) { _, closing in
                if closing {
                    withAnimation(
                        reduceMotion
                            ? .linear(duration: 0.12)
                            : NotchDesign.Motion.panelClose
                    ) {
                        isVisible = false
                    }
                } else if model.isExpanded {
                    withAnimation(
                        reduceMotion
                            ? .linear(duration: 0.12)
                            : NotchDesign.Motion.panelOpen
                    ) {
                        isVisible = true
                    }
                }
            }
    }
}

struct ExpandedPanel: View {
    private enum Layout {
        static let outerInset = NotchDesign.Spacing.panelInset
    }

    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Layout.outerInset) {
            header

            ScrollView(.vertical) {
                PostureDashboardView(model: model)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(Layout.outerInset)
        .frame(
            width: NotchLayout.expandedPanelWidth,
            height: model.postureExpandedPanelHeight
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "figure.seated.side")
                    .font(.system(size: 12, weight: .semibold))
                Text("Posture")
                    .font(.system(size: 14, weight: .semibold))
            }

            Spacer(minLength: 0)

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help(model.localized("Open settings"))
            .accessibilityLabel(model.localized("Open settings"))
        }
        .frame(height: 28)
    }
}
