import AppKit
import SwiftUI

struct LivingNotch: View {
    @ObservedObject var model: AppModel
    let hoveredHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shoulderRadius = NotchLayout.shoulderRadius

    private var hovering: Bool {
        model.isHoveringNotch
            || model.isExpanded
            || model.isPanelClosing
            || model.systemHUD != nil
    }

    private var leftWidth: CGFloat {
        NotchLayout.compactWingWidth(for: model.leftWingContent)
    }

    private var rightWidth: CGFloat {
        NotchLayout.compactWingWidth(for: model.rightWingContent)
    }

    private var compactWidth: CGFloat {
        leftWidth + model.notchWidth + rightWidth
    }

    private var width: CGFloat {
        NotchLayout.compactSurfaceWidth(
            leftWingWidth: leftWidth,
            notchWidth: model.notchWidth,
            rightWingWidth: rightWidth
        )
    }

    private var height: CGFloat {
        hovering ? hoveredHeight : min(model.menuBarHeight, 40)
    }

    private var showsHoverPreview: Bool {
        hovering && model.systemHUD == nil
    }

    var body: some View {
        NotchSilhouette(
            shoulderRadius: shoulderRadius,
            bottomCornerRadius: hovering ? 22 : 12
        )
        .fill(.black)
        .frame(width: width, height: height, alignment: .top)
        .overlay {
            compactContent
                .opacity(hovering ? 0 : 1)
                .accessibilityHidden(hovering)
        }
        .overlay {
            hoverPreview
                .frame(width: compactWidth, height: height)
                .opacity(showsHoverPreview ? 1 : 0)
                .accessibilityHidden(!showsHoverPreview)
        }
        .overlay {
            if let snapshot = model.systemHUD {
                SystemHUDContent(
                    snapshot: snapshot.kind == .cycle && model.postureCycleSettings.enabled
                        ? model.postureCycleHUD : snapshot,
                    menuBarHeight: model.menuBarHeight,
                    colors: model.postureColors
                )
                .frame(width: compactWidth, height: height)
                .id(snapshot.kind)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .foregroundStyle(.white)
        .animation(
            reduceMotion ? .linear(duration: 0.01) : NotchDesign.Motion.hover,
            value: hovering
        )
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            CompactWingSlot(
                model: model,
                content: model.leftWingContent
            )
            .frame(width: leftWidth, height: height)

            Capsule()
                .fill(.white.opacity(0.12))
                .frame(width: 22, height: 2)
                .padding(.top, max(0, model.menuBarHeight - 9))
                .frame(width: model.notchWidth, height: height, alignment: .top)

            CompactWingSlot(
                model: model,
                content: model.rightWingContent
            )
            .frame(width: rightWidth, height: height)
        }
        .frame(width: compactWidth, height: height)
    }

    private var hoverPreview: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: model.menuBarHeight)

            if model.postureCycleSettings.enabled {
                SystemHUDRow(snapshot: model.postureCycleHUD, colors: model.postureColors)
                    .padding(.horizontal, 20)
                    .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    hoverCell(for: model.leftWingContent, side: .left)
    
                    hoverDivider
    
                    hoverCenterStatus
                        .frame(width: 42)
    
                    hoverDivider
    
                    hoverCell(for: model.rightWingContent, side: .right)
                }
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func hoverCell(
        for content: NotchWingContent,
        side: NotchWingSide
    ) -> some View {
        switch content {
        case .hidden:
            Color.clear.frame(maxWidth: .infinity)
        case .posture:
            PostureHoverStatus(model: model, side: side)
                .frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
        case .temperatureHumidity:
            NotchCombinedClimateReading(model: model)
                .frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
        case .temperature, .humidity:
            NotchClimateReading(model: model, content: content, expanded: true)
                .frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
        }
    }

    private var hoverDivider: some View {
        Capsule()
            .fill(.white.opacity(0.1))
            .frame(width: 1, height: 19)
    }

    private var hoverCenterStatus: some View {
        VStack(spacing: 1) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))

            Text(model.localized("Click to expand"))
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityLabel(model.localized("Click to expand the detailed panel"))
    }
}
