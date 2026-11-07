import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService {
    struct Snapshot: Equatable {
        let isRequested: Bool
        let requiresApproval: Bool
        let description: String
        let health: ServiceHealth
    }

    func snapshot() -> Snapshot {
        switch SMAppService.mainApp.status {
        case .enabled:
            return Snapshot(
                isRequested: true,
                requiresApproval: false,
                description: "Enabled",
                health: .ready("Starts automatically after login")
            )
        case .requiresApproval:
            return Snapshot(
                isRequested: true,
                requiresApproval: true,
                description: "Waiting for system approval",
                health: .warning("Approve LearnWell in System Settings › Login Items")
            )
        case .notRegistered:
            return Snapshot(
                isRequested: false,
                requiresApproval: false,
                description: "Off",
                health: .ready("Launch at login is off")
            )
        case .notFound:
            return Snapshot(
                isRequested: false,
                requiresApproval: false,
                description: "Unavailable in this build",
                health: .warning("Run the app from the Applications folder, then enable this")
            )
        @unknown default:
            return Snapshot(
                isRequested: false,
                requiresApproval: false,
                description: "Unknown state",
                health: .warning("The system did not return the login item status")
            )
        }
    }

    func setEnabled(_ enabled: Bool) -> Snapshot {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return snapshot()
        } catch {
            return Snapshot(
                isRequested: snapshot().isRequested,
                requiresApproval: snapshot().requiresApproval,
                description: "Setup failed",
                health: .failed(Self.localizedFailure(error))
            )
        }
    }

    /// The failure sentence carries a system error, so it can never match a
    /// string-table key. Localise the sentence here and append the detail.
    private static func localizedFailure(_ error: Error) -> String {
        let language = AppLanguage(
            rawValue: UserDefaults.standard.string(
                forKey: AppModel.PreferenceKey.appLanguage
            ) ?? ""
        ) ?? AppLanguage.defaultLanguage
        return language.localizedFormat("Could not change launch at login: %@", error.localizedDescription)
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
