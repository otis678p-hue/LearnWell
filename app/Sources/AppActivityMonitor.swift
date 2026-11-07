import AppKit
import Foundation

@MainActor
final class AppActivityMonitor {
    enum SuspensionReason: Hashable {
        case sessionInactive
        case screenAsleep
        case systemAsleep
    }

    private let onSuspensionChanged: @MainActor (Bool, String) -> Void
    private var observers: [NSObjectProtocol] = []
    private var reasons = Set<SuspensionReason>()

    init(onSuspensionChanged: @escaping @MainActor (Bool, String) -> Void) {
        self.onSuspensionChanged = onSuspensionChanged
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, reason: .systemAsleep, suspended: true, center: center)
        observe(NSWorkspace.didWakeNotification, reason: .systemAsleep, suspended: false, center: center)
        observe(NSWorkspace.screensDidSleepNotification, reason: .screenAsleep, suspended: true, center: center)
        observe(NSWorkspace.screensDidWakeNotification, reason: .screenAsleep, suspended: false, center: center)
        observe(NSWorkspace.sessionDidResignActiveNotification, reason: .sessionInactive, suspended: true, center: center)
        observe(NSWorkspace.sessionDidBecomeActiveNotification, reason: .sessionInactive, suspended: false, center: center)
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        reasons.removeAll()
    }

    private func observe(
        _ name: NSNotification.Name,
        reason: SuspensionReason,
        suspended: Bool,
        center: NotificationCenter
    ) {
        observers.append(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.set(reason, active: suspended)
                }
            }
        )
    }

    private func set(_ reason: SuspensionReason, active: Bool) {
        let wasSuspended = !reasons.isEmpty
        if active {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        let isSuspended = !reasons.isEmpty
        guard wasSuspended != isSuspended else { return }
        onSuspensionChanged(
            isSuspended,
            isSuspended ? "Screen locked or system asleep" : "Session resumed"
        )
    }
}
