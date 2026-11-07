import SwiftUI

/// Quiet, monochrome glyphs aligned with the other settings-row icons.
struct PostureStatusMark: View {
    enum State {
        case running
        case paused
    }

    var state: State
    var size: CGFloat = 20

    var body: some View {
        Group {
            switch state {
            case .running: leaf
            case .paused: pause
            }
        }
        .foregroundStyle(NotchDesign.Palette.secondaryText)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Glyphs

    /// The folded upper edge and sweeping stem keep the small outline organic.
    private var leaf: some View {
        Path { path in
            path.move(to: point(0.16, 0.20))
            path.addCurve(
                to: point(0.58, 0.27),
                control1: point(0.29, 0.35), control2: point(0.41, 0.23)
            )
            path.addCurve(
                to: point(0.83, 0.55),
                control1: point(0.77, 0.28), control2: point(0.86, 0.39)
            )
            path.addCurve(
                to: point(0.48, 0.78),
                control1: point(0.81, 0.72), control2: point(0.66, 0.81)
            )
            path.addCurve(
                to: point(0.16, 0.20),
                control1: point(0.22, 0.77), control2: point(0.11, 0.51)
            )
            path.closeSubpath()

            path.move(to: point(0.34, 0.44))
            path.addCurve(
                to: point(0.88, 0.85),
                control1: point(0.56, 0.48), control2: point(0.76, 0.58)
            )
        }
        .stroke(style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round, lineJoin: .round))
    }

    /// A flat pause glyph in the same visual weight as the leaf.
    private var pause: some View {
        HStack(spacing: size * 0.115) {
            bar
            bar
        }
    }

    private var bar: some View {
        Capsule(style: .continuous)
            .frame(width: size * 0.135, height: size * 0.52)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: size * x, y: size * y)
    }
}
