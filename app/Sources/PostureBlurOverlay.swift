import AppKit

/// Dorso's progressive blur ramp, with a public NSVisualEffectView fallback.
/// Windows pass through all input and are removed as soon as tracking pauses.
@MainActor
protocol PostureBlurPresenting: AnyObject {
    func update(intensity: Double)
    func clear()
}

@MainActor
final class PostureBlurOverlay: PostureBlurPresenting {
    private var windows: [NSWindow] = []
    private var effects: [NSVisualEffectView] = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var current: Double = 0
    private var target: Double = 0
    private static let connection: (@convention(c) () -> UInt32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> UInt32).self)
    }()
    private static let setRadius: (@convention(c) (UInt32, UInt32, Int32) -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (UInt32, UInt32, Int32) -> Int32).self)
    }()

    func update(intensity: Double) {
        target = intensity.isFinite ? min(1, max(0, intensity)) : 0
        guard target > 0 else { clear(); return }
        if windows.isEmpty { createWindows() }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func clear() {
        timer?.invalidate()
        timer = nil
        current = 0
        target = 0
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        effects.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func createWindows() {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            effect.blendingMode = .behindWindow
            effect.material = .fullScreenUI
            effect.state = .active
            effect.alphaValue = 0
            window.contentView = effect
            window.orderFrontRegardless()
            windows.append(window)
            effects.append(effect)
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let intensity = self.target
                self.clear()
                self.update(intensity: intensity)
            }
        }
    }

    private func step() {
        current += min(1.0 / 64, max(-3.0 / 64, target - current))
        for (index, window) in windows.enumerated() {
            if let connection = Self.connection, let setRadius = Self.setRadius,
               setRadius(connection(), UInt32(window.windowNumber), Int32(current * 64)) == 0 {
                effects[index].alphaValue = 0
            } else {
                effects[index].alphaValue = min(1, sqrt(current) * 1.2)
            }
        }
    }
}
