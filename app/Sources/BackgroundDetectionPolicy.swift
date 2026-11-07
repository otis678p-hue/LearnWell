import Foundation

/// Decides whether camera detection should be running right now.
///
/// Two independent inputs feed it: the user's master switch and the system's
/// lock/sleep state. Keeping that decision in one small value type means the
/// suspend path can be verified without a camera, and the badge in settings,
/// the detection service and the stored preference cannot drift apart.
struct BackgroundDetectionPolicy: Equatable {
    /// What the caller has to do to the detection service.
    enum Action: Equatable {
        case none
        case start
        case stop
    }

    /// The master switch. Recorded even while suspended so the preference the
    /// user chose survives a lock or a sleep cycle.
    private(set) var userEnabled: Bool
    private(set) var isSuspended: Bool
    /// Whether the service should currently be capturing and inferring.
    private(set) var shouldRun: Bool

    init(userEnabled: Bool, isSuspended: Bool = false) {
        self.userEnabled = userEnabled
        self.isSuspended = isSuspended
        self.shouldRun = userEnabled && !isSuspended
    }

    /// Applies the master switch.
    mutating func setUserEnabled(_ enabled: Bool) -> Action {
        userEnabled = enabled
        return settle()
    }

    /// Applies a lock/sleep change. Waking only starts detection again when the
    /// master switch is still on.
    mutating func setSuspended(_ suspended: Bool) -> Action {
        isSuspended = suspended
        return settle()
    }

    private mutating func settle() -> Action {
        let desired = userEnabled && !isSuspended
        guard desired != shouldRun else { return .none }
        shouldRun = desired
        return desired ? .start : .stop
    }
}
