import AppKit

enum NotchScreen {
    /// The display that owns the notch: the built-in screen when present,
    /// otherwise the current main screen.
    static var preferred: NSScreen? {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? screens.first
    }
}
