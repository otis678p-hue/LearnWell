import AppKit
import Foundation

extension AppModel {
    /// Screen lock and sleep stop the capture session and the inference loop, so
    /// the machine is not decoding frames nobody can see. The master switch is
    /// left untouched: waking resumes detection only if the user still has it on.
    func setBackgroundRefreshPaused(_ paused: Bool, reason: String) {
        guard paused != isBackgroundRefreshPaused else { return }
        isBackgroundRefreshPaused = paused
        log.notice(
            "background detection \(paused ? "suspended" : "resumed", privacy: .public) (\(reason, privacy: .public))"
        )
        applyDetectionAction(detectionPolicy.setSuspended(paused))

        if paused {
            sendPanelEvent(.activitySuspended)
        } else {
            sendPanelEvent(.activityResumed)
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let snapshot = launchAtLoginService.setEnabled(enabled)
        applyLaunchAtLoginSnapshot(snapshot)
    }

    func refreshLaunchAtLoginStatus() {
        applyLaunchAtLoginSnapshot(launchAtLoginService.snapshot())
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    var launchAtLoginStatusDescription: String {
        if launchAtLoginRequiresApproval { return "Waiting for system approval" }
        return launchAtLoginEnabled ? "Enabled" : launchAtLoginHealth.message
    }

    private func applyLaunchAtLoginSnapshot(_ snapshot: LaunchAtLoginService.Snapshot) {
        launchAtLoginEnabled = snapshot.isRequested
        launchAtLoginRequiresApproval = snapshot.requiresApproval
        launchAtLoginHealth = snapshot.health
    }
}
