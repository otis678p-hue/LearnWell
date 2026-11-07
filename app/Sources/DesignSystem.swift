import AppKit
import SwiftUI

/// Shared visual language for every surface of the app.
///
/// The redesign is deliberately quiet: a warm off-white canvas, hairline
/// outlined cards with no shadows, one accent per posture state, and numerals
/// set in a rounded monospaced face so values line up.
enum NotchDesign {
    enum Spacing {
        static let panelInset: CGFloat = 22
        static let section: CGFloat = 26
        static let group: CGFloat = 10
        static let row: CGFloat = 14
    }

    enum Radius {
        static let panel: CGFloat = 24
        static let card: CGFloat = 16
        static let control: CGFloat = 9
        static let compactGroup: CGFloat = 12
    }

    enum Palette {
        /// Warm off-white canvas behind the cards.
        static let canvas = Color(red: 0.965, green: 0.957, blue: 0.945)
        static let card = Color.white
        static let hairline = Color.black.opacity(0.09)
        static let text = Color(red: 0.078, green: 0.078, blue: 0.086)
        static let secondaryText = Color(red: 0.42, green: 0.42, blue: 0.44)
        static let eyebrow = Color(red: 0.52, green: 0.51, blue: 0.50)
        static let selected = Color(red: 0.078, green: 0.078, blue: 0.086)
        static let track = Color.black.opacity(0.05)
        /// Teaching surfaces (the classroom steps) use one calm blue accent.
        static let accent = Color(red: 0.243, green: 0.482, blue: 0.980)
    }

    enum Typography {
        static let pageTitle = Font.system(size: 27, weight: .semibold)
        static let pageSubtitle = Font.system(size: 12.5, weight: .regular)
        static let eyebrow = Font.system(size: 10, weight: .semibold)
        static let cardTitle = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 12, weight: .regular)
        static let caption = Font.system(size: 11, weight: .regular)
        static let value = Font.system(size: 12.5, weight: .medium, design: .rounded)
        static let metric = Font.system(size: 26, weight: .semibold, design: .rounded)
    }

    enum Motion {
        static let value = Animation.easeInOut(duration: 0.18)
        static let hover = Animation.timingCurve(0.22, 0.72, 0, 1, duration: 0.28)
        static let panelOpen = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.38)
        static let panelClose = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.30)
        static let sectionChange = Animation.easeInOut(duration: 0.20)
    }
}

extension View {
    /// Hairline outlined card used by the settings pages and the notch panel.
    func cardSurface(
        cornerRadius: CGFloat = NotchDesign.Radius.card
    ) -> some View {
        background(NotchDesign.Palette.card, in: RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(NotchDesign.Palette.hairline, lineWidth: 1)
        }
    }

    /// Compact inner surface used for the notchy black previews.
    func insetSurface(
        cornerRadius: CGFloat = NotchDesign.Radius.control
    ) -> some View {
        background(NotchDesign.Palette.track, in: RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        ))
    }

    /// The expanded notch panel: white card floating over the desktop.
    func panelSurface(
        cornerRadius: CGFloat,
        contentSize: CGSize
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(NotchDesign.Palette.card)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(NotchDesign.Palette.hairline, lineWidth: 1)
                }
        }
        .environment(\.colorScheme, .light)
        .frame(width: contentSize.width, height: contentSize.height)
    }

    func panelGroupSurface(
        cornerRadius: CGFloat = NotchDesign.Radius.card
    ) -> some View {
        insetSurface(cornerRadius: cornerRadius)
    }
}
