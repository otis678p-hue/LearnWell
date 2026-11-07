import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var panelGeometry: NotchPanelGeometryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointerRegion = NotchPointerRegion.outside
    private let hoveredNotchHeight = NotchLayout.hoveredHeight

    var body: some View {
        VStack(spacing: NotchLayout.expandedGap) {
            collapsedBar
                .frame(height: compactHeight)

            if model.isExpanded || model.isPanelClosing {
                ExpandedPanelSurface(model: model)
            }
        }
        // AppKit owns the panel's frame. Keep SwiftUI's proposed root size
        // aligned with the controller's target to prevent NSHostingView from
        // feeding changing ideal sizes back into the window during layout.
        .frame(
            width: panelGeometry.size.width,
            height: panelGeometry.size.height,
            alignment: .top
        )
        .background {
            if model.isExpanded || model.isPanelClosing {
                // Keep the expanded window's transparent gutters hit-testable
                // so a click beside the glass surface can dismiss the panel.
                Color.clear
                    .contentShape(Rectangle())
            }
        }
        .animation(NotchDesign.Motion.value, value: model.leftWingContent)
        .animation(NotchDesign.Motion.value, value: model.rightWingContent)
        .environment(\.locale, model.appLanguage.locale)
    }

    private var compactHeight: CGFloat {
        model.isHoveringNotch
            || model.isExpanded
            || model.isPanelClosing
            || model.systemHUD != nil

            ? hoveredNotchHeight
            : model.menuBarHeight
    }

    private var collapsedBar: some View {
        ZStack(alignment: .top) {
            Button {
                model.toggleExpanded()
            } label: {
                LivingNotch(
                    model: model,
                    hoveredHeight: hoveredNotchHeight
                )
            }
            .buttonStyle(StableNotchButtonStyle())
            .contextMenu {
                Button {
                    model.openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }

                Divider()

                Button(role: .destructive) {
                    model.quitApplication()
                } label: {
                    Label("Quit LearnWell", systemImage: "power")
                }
            }
            .background {
                NotchHoverTracker { location in
                    updatePointerRegion(at: location)
                }
            }
            .offset(x: compactAlignmentOffset)
            .accessibilityLabel(
                model.localized(
                    model.isExpanded ? "Collapse LearnWell" : "Expand LearnWell"
                )
            )

        }
        .frame(maxWidth: .infinity, alignment: .top)
    }


    private var leftWingWidth: CGFloat {
        NotchLayout.compactWingWidth(for: model.leftWingContent)
    }

    private var rightWingWidth: CGFloat {
        NotchLayout.compactWingWidth(for: model.rightWingContent)
    }

    private var compactAlignmentOffset: CGFloat {
        return NotchLayout.compactSurfaceHorizontalOffset(
            leftWingWidth: leftWingWidth,
            rightWingWidth: rightWingWidth
        )
    }



    private func updatePointerRegion(at location: CGPoint?) {
        let region = pointerRegion(at: location)
        guard region != pointerRegion else { return }
        pointerRegion = region

        switch region {
        case .outside:
            model.setNotchHovered(false)
        case .notch:
            model.setNotchHovered(true)
        }
    }

    private func pointerRegion(at location: CGPoint?) -> NotchPointerRegion {
        guard location != nil else { return .outside }
        return .notch
    }


}

struct NotchSilhouette: Shape {
    let shoulderRadius: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let shoulder = min(
            shoulderRadius,
            min(rect.width / 4, rect.height / 3)
        )
        let bodyLeft = rect.minX + shoulder
        let bodyRight = rect.maxX - shoulder
        let bottomRadius = min(
            bottomCornerRadius,
            min(
                (bodyRight - bodyLeft) / 2,
                max(0, rect.height - shoulder)
            )
        )
        let bottom = rect.maxY

        var path = Path()
        // Extend the top edge slightly past the view bounds so antialiasing
        // can never reveal a seam against the physical display notch.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY - 1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - 1))

        // The display notch flares outward where it meets the top bezel.
        // These concave shoulders replace the abrupt 90-degree junction.
        path.addCurve(
            to: CGPoint(x: bodyRight, y: rect.minY + shoulder),
            control1: CGPoint(
                x: rect.maxX - shoulder * 0.58,
                y: rect.minY - 1
            ),
            control2: CGPoint(
                x: bodyRight,
                y: rect.minY + shoulder * 0.42
            )
        )
        path.addLine(
            to: CGPoint(x: bodyRight, y: bottom - bottomRadius)
        )
        path.addCurve(
            to: CGPoint(x: bodyRight - bottomRadius, y: bottom),
            control1: CGPoint(
                x: bodyRight,
                y: bottom - bottomRadius * 0.45
            ),
            control2: CGPoint(
                x: bodyRight - bottomRadius * 0.45,
                y: bottom
            )
        )
        path.addLine(
            to: CGPoint(x: bodyLeft + bottomRadius, y: bottom)
        )
        path.addCurve(
            to: CGPoint(x: bodyLeft, y: bottom - bottomRadius),
            control1: CGPoint(
                x: bodyLeft + bottomRadius * 0.45,
                y: bottom
            ),
            control2: CGPoint(
                x: bodyLeft,
                y: bottom - bottomRadius * 0.45
            )
        )
        path.addLine(
            to: CGPoint(x: bodyLeft, y: rect.minY + shoulder)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY - 1),
            control1: CGPoint(
                x: bodyLeft,
                y: rect.minY + shoulder * 0.42
            ),
            control2: CGPoint(
                x: rect.minX + shoulder * 0.58,
                y: rect.minY - 1
            )
        )
        path.closeSubpath()
        return path
    }
}

private struct StableNotchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct NotchHoverTracker: NSViewRepresentable {
    let onPointerLocation: (CGPoint?) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onPointerLocation = onPointerLocation
        return view
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        nsView.onPointerLocation = onPointerLocation
    }
}

@MainActor
private final class HoverTrackingView: NSView {
    var onPointerLocation: ((CGPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var pendingPointerLocation: CGPoint?
    private var hasPendingPointerLocation = false
    private var pointerDeliveryScheduled = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // inVisibleRect keeps this area synchronized with the view bounds.
        // Replacing it during every constraint pass can itself cause another
        // enter/move callback while SwiftUI is resizing the compact notch.
        guard hoverArea == nil else { return }

        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeAlways,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        reportLocation(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        reportLocation(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        schedulePointerLocation(nil)
    }

    private func reportLocation(for event: NSEvent) {
        schedulePointerLocation(convert(event.locationInWindow, from: nil))
    }

    private func schedulePointerLocation(_ location: CGPoint?) {
        pendingPointerLocation = location
        hasPendingPointerLocation = true
        guard !pointerDeliveryScheduled else { return }
        pointerDeliveryScheduled = true

        // The callback changes SwiftUI layout. Deliver it after AppKit has
        // completed the current event/constraint pass and coalesce any mouse
        // movement generated by that same layout change.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pointerDeliveryScheduled = false
            guard self.hasPendingPointerLocation else { return }

            let location = self.pendingPointerLocation
            self.pendingPointerLocation = nil
            self.hasPendingPointerLocation = false
            self.onPointerLocation?(location)
        }
    }
}

enum NotchWingSide: Equatable {
    case left
    case right
}

private enum NotchPointerRegion: Equatable {
    case outside
    case notch
}
