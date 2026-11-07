import SwiftUI

struct SystemHUDContent: View {
    let snapshot: SystemHUDSnapshot
    let menuBarHeight: CGFloat
    var colors: PostureColors = .classic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentVisible = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: menuBarHeight)

            SystemHUDRow(snapshot: snapshot, colors: colors)
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity)
                .opacity(contentVisible ? 1 : 0)
                .offset(y: reduceMotion || contentVisible ? 0 : -3)
        }
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(reduceMotion ? .linear(duration: 0.12) : NotchDesign.Motion.panelOpen) {
                contentVisible = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey(snapshot.title)) + Text("，") + Text(LocalizedStringKey(snapshot.subtitle)))
    }
}

/// The HUD body without the menu-bar offset, so settings can preview it.
struct SystemHUDRow: View {
    let snapshot: SystemHUDSnapshot
    var colors: PostureColors = .classic

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: snapshot.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(snapshot.title))
                    .monospacedDigit()
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(LocalizedStringKey(snapshot.subtitle))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if snapshot.kind == .cycle {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: min(max(snapshot.value ?? 0, 0), 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            } else {
                Image(systemName: isPositive
                      ? "checkmark.circle.fill"
                      : (snapshot.accent == .warning
                         ? "ruler.fill"
                         : "exclamationmark.triangle.fill"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .foregroundStyle(.white)
    }

    private var isPositive: Bool {
        snapshot.accent == .positive
    }

    private var tint: Color {
        colors.color(for: snapshot.accent)
    }
}
