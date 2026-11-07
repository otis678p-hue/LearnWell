import SwiftUI

/// Uses the same silhouette, slot widths, ring sizes and center indicator as
/// LivingNotch. Keep the physical notch centered as either wing changes.
struct SettingsNotchPreview<LeftWing: View, RightWing: View>: View {
    let notchWidth: CGFloat
    let height: CGFloat
    let leftWingWidth: CGFloat
    let rightWingWidth: CGFloat
    var concealedSide: NotchWingSide?
    @ViewBuilder var leftWing: () -> LeftWing
    @ViewBuilder var rightWing: () -> RightWing

    var body: some View {
        NotchSilhouette(
            shoulderRadius: NotchLayout.shoulderRadius,
            bottomCornerRadius: 12
        )
        .fill(.black)
        .frame(
            width: NotchLayout.compactSurfaceWidth(
                leftWingWidth: leftWingWidth,
                notchWidth: notchWidth,
                rightWingWidth: rightWingWidth
            ),
            height: height
        )
        .overlay {
            HStack(spacing: 0) {
                leftWing()
                    .frame(width: leftWingWidth, height: height)
                    .opacity(concealedSide == .left ? 0 : 1)

                Capsule()
                    .fill(.white.opacity(0.12))
                    .frame(width: 22, height: 2)
                    .padding(.top, max(0, height - 9))
                    .frame(width: notchWidth, height: height, alignment: .top)

                rightWing()
                    .frame(width: rightWingWidth, height: height)
                    .opacity(concealedSide == .right ? 0 : 1)
            }
        }
        .offset(x: NotchLayout.compactSurfaceHorizontalOffset(
            leftWingWidth: leftWingWidth,
            rightWingWidth: rightWingWidth
        ))
    }
}
