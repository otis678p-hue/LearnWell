import AppKit
import Combine
import Foundation
import OSLog
import SwiftUI

/// Notch Triage is a posture monitor: this model owns the notch panel, the
/// posture service and the small amount of appearance/lifecycle state that the
/// notch UI needs.
@MainActor
final class AppModel: ObservableObject {
    let training = PostureTrainingController()
    let log = Logger(subsystem: "com.hyacinth.notchtriage", category: "panel")

    enum PreferenceKey {
        static let appLanguage = "notch.appLanguage"
        static let leftWingContent = "notch.leftWingContent"
        static let rightWingContent = "notch.rightWingContent"
        static let restReminderMode = "notch.posture.restReminderMode"
    }

    @Published private(set) var panelState = PanelState() {
        didSet { updatePosturePreviewVisibility() }
    }
    @Published var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(
                appLanguage.rawValue,
                forKey: PreferenceKey.appLanguage
            )
        }
    }
    @Published var menuBarHeight: CGFloat = 37
    @Published var notchWidth: CGFloat = 186
    @Published var posture = PostureSnapshot.offline
    @Published var posturePreview: NSImage?
    @Published private(set) var posturePreviewHeight = PosturePreviewSizing.load()
    @Published var posturePreviewFullFrame =
        UserDefaults.standard.object(forKey: PosturePreviewSizing.fullFrameKey) == nil
        ? true : UserDefaults.standard.bool(forKey: PosturePreviewSizing.fullFrameKey) {
        didSet { UserDefaults.standard.set(posturePreviewFullFrame, forKey: PosturePreviewSizing.fullFrameKey) }
    }
    @Published var postureMaximumPanelHeight: CGFloat = 700

    var postureExpandedPanelHeight: CGFloat {
        PosturePreviewSizing.expandedHeight(previewHeight: posturePreviewHeight,
            environmentVisible: postureArduinoEnabled && !postureCalibration.isActive,
            availableHeight: postureMaximumPanelHeight)
    }

    func setPosturePreviewHeight(_ height: CGFloat) {
        let value = PosturePreviewSizing.normalized(height)
        guard posturePreviewHeight != value else { return }
        posturePreviewHeight = value
        UserDefaults.standard.set(Double(value), forKey: PosturePreviewSizing.heightKey)
    }

    func resetPosturePreviewSize() { setPosturePreviewHeight(PosturePreviewSizing.defaultHeight) }

    @Published var postureCalibration: PostureCalibrationState =
        PostureManualReference.load() == nil ? .idle : .complete
    @Published var postureBlurEnabled = PostureMonitorService.savedBlurEnabled {
        didSet { postureService.setBlurEnabled(postureBlurEnabled) }
    }
    @Published var postureBlurSettings = PostureBlurSettings.load() {
        didSet { postureService.setBlurSettings(postureBlurSettings) }
    }
    @Published var postureRuntime = PostureRuntimeState.stopped
    @Published var postureMonitoringEnabled = UserDefaults.standard.bool(forKey: PostureMonitorService.enabledPreferenceKey) {
        didSet {
            UserDefaults.standard.set(postureMonitoringEnabled, forKey: PostureMonitorService.enabledPreferenceKey)
            applyDetectionAction(detectionPolicy.setUserEnabled(postureMonitoringEnabled))
        }
    }

    /// Single source of truth for "should the camera be running": the user's
    /// switch AND the system not being locked or asleep.
    lazy var detectionPolicy = BackgroundDetectionPolicy(
        userEnabled: UserDefaults.standard.bool(forKey: PostureMonitorService.enabledPreferenceKey)
    )
    @Published var postureArduinoEnabled = PostureMonitorService.savedArduinoEnabled {
        didSet {
            UserDefaults.standard.set(postureArduinoEnabled, forKey: PostureArduinoLink.enabledPreferenceKey)
            postureService.setArduinoEnabled(postureArduinoEnabled)
        }
    }
    @Published private(set) var postureBadDelay = PostureMonitorService.savedBadDelay {
        didSet { postureService.badDelay = postureBadDelay }
    }
    @Published var postureAlertsEnabled = PostureMonitorService.savedAlertsEnabled {
        didSet {
            UserDefaults.standard.set(postureAlertsEnabled, forKey: PostureMonitorService.alertsPreferenceKey)
            postureService.setAlertsEnabled(postureAlertsEnabled)
        }
    }
    @Published private(set) var postureSensitivity = PostureMonitorService.savedSensitivity {
        didSet { postureService.setSensitivity(postureSensitivity) }
    }

    @Published private(set) var posturePoseFallbackEnabled =
        PostureMonitorService.savedPoseFallbackEnabled {
        didSet { postureService.setPoseFallbackEnabled(posturePoseFallbackEnabled) }
    }
    @Published var postureGoodAlertsEnabled = PostureMonitorService.savedGoodAlertsEnabled {
        didSet {
            UserDefaults.standard.set(postureGoodAlertsEnabled, forKey: PostureMonitorService.goodAlertsPreferenceKey)
            postureService.setGoodAlertsEnabled(postureGoodAlertsEnabled)
        }
    }
    @Published private(set) var postureAlertRepeat = PostureMonitorService.savedAlertRepeat {
        didSet { postureService.setAlertRepeat(postureAlertRepeat) }
    }
    @Published var postureColors = PostureMonitorService.savedColors {
        didSet { PostureMonitorService.saveColors(postureColors) }
    }
    @Published var leftWingContent: NotchWingContent {
        didSet {
            UserDefaults.standard.set(
                leftWingContent.rawValue,
                forKey: PreferenceKey.leftWingContent
            )
        }
    }
    @Published var rightWingContent: NotchWingContent {
        didSet {
            UserDefaults.standard.set(
                rightWingContent.rawValue,
                forKey: PreferenceKey.rightWingContent
            )
        }
    }
    @Published private(set) var postureStats = PostureStats.empty
    @Published private(set) var postureHistory = PostureHistory()
    @Published private(set) var postureGoal = PostureGoal()
    @Published private(set) var postureCycle = PostureCycle.idle
    @Published private(set) var postureStreak = 0
    @Published private(set) var postureGoalMet = false
    @Published var restReminderEnabled = PostureMonitorService.savedRestReminderEnabled {
        didSet {
            UserDefaults.standard.set(
                restReminderEnabled,
                forKey: PostureMonitorService.restReminderEnabledKey
            )
        }
    }
    @Published var restReminderMinutes = PostureMonitorService.savedRestReminderMinutes {
        didSet {
            UserDefaults.standard.set(
                restReminderMinutes,
                forKey: PostureMonitorService.restReminderMinutesKey
            )
        }
    }
    /// True when the interval comes from the free-form value instead of a preset.
    @Published var restReminderUsesCustom = PostureMonitorService.savedRestReminderUsesCustom {
        didSet {
            UserDefaults.standard.set(
                restReminderUsesCustom,
                forKey: PostureMonitorService.restReminderCustomKey
            )
        }
    }
    @Published var restReminderCustomMinutes = PostureMonitorService.savedRestReminderCustomMinutes {
        didSet {
            UserDefaults.standard.set(
                restReminderCustomMinutes,
                forKey: PostureMonitorService.restReminderCustomMinutesKey
            )
        }
    }
    /// Which flavour of "stand up" reminder is armed; see restReminderActive.
    @Published var restReminderMode: PostureRestReminderMode {
        didSet {
            UserDefaults.standard.set(
                restReminderMode.rawValue,
                forKey: PreferenceKey.restReminderMode
            )
        }
    }
    @Published var isBackgroundRefreshPaused = false
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginRequiresApproval = false
    @Published var launchAtLoginHealth: ServiceHealth = .loading("Reading login item status")

    lazy var postureService = PostureMonitorService(
        onSnapshot: { [weak self] snapshot in
            guard self?.posture != snapshot else { return }
            self?.posture = snapshot
        },
        onPreview: { [weak self] image in self?.posturePreview = image },
        onState: { [weak self] state in self?.postureRuntime = state },
        onAlert: { [weak self] alert in self?.presentPostureAlert(alert) },
        onCalibration: { [weak self] state in self?.postureCalibration = state }
    )

    let postureSession = PostureSessionTracker()
    private var postureStatsTask: Task<Void, Never>?
    var systemHUDDismissTask: Task<Void, Never>?
    var hoverCollapseTask: Task<Void, Never>?
    var panelCloseTask: Task<Void, Never>?
    var settingsWindowTask: Task<Void, Never>?
    var settingsWindowOpener: (() -> Void)?
    private var acceptsSystemHUDEvents = false
    var areApplicationServicesRunning = false

    let launchAtLoginService = LaunchAtLoginService()
    /// The six-step classroom keeps its own state so a running fine-tune
    /// survives switching panes.
    lazy var classroom = ClassroomStore(appModel: self)

    private lazy var activityMonitor = AppActivityMonitor { [weak self] paused, reason in
        self?.setBackgroundRefreshPaused(paused, reason: reason)
    }

    init() {
        let defaults = UserDefaults.standard
        let restoredLanguage = AppLanguage(
            rawValue: defaults.string(forKey: PreferenceKey.appLanguage) ?? ""
        ) ?? AppLanguage.defaultLanguage
        appLanguage = restoredLanguage
        // postureService is lazy: forcing it here starts detection machinery
        // too early. It picks up the language itself at creation instead.
        leftWingContent = NotchWingContent(
            rawValue: defaults.string(forKey: PreferenceKey.leftWingContent) ?? ""
        ) ?? .posture
        rightWingContent = NotchWingContent(
            rawValue: defaults.string(forKey: PreferenceKey.rightWingContent) ?? ""
        ) ?? .posture
        // Older builds kept the two reminders as separate switches; a running
        // rhythm is the one that was actually armed, so it seeds the mode.
        restReminderMode = PostureRestReminderMode(
            rawValue: defaults.string(forKey: PreferenceKey.restReminderMode) ?? ""
        ) ?? (postureSession.settings.enabled ? .cycle : PostureRestReminderMode.defaultMode)
    }

    /// Proper noun: never translated, used next to localised words.
    let productName = "LearnWell"

    func replacePanelState(_ state: PanelState) {
        panelState = state
    }

    func setAppLanguage(_ language: AppLanguage) {
        appLanguage = language
        postureService.overlayLanguage = language
    }

    func localized(_ source: String) -> String {
        appLanguage.localized(source)
    }

    func localizedFormat(_ source: String, _ arguments: CVarArg...) -> String {
        String(
            format: appLanguage.localized(source),
            locale: appLanguage.locale,
            arguments: arguments
        )
    }

    func motion(_ animation: Animation) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .linear(duration: 0.01)
            : animation
    }

    func setPosturePoseFallbackEnabled(_ enabled: Bool) {
        guard enabled != posturePoseFallbackEnabled else { return }
        posturePoseFallbackEnabled = enabled
    }

    func setPostureSensitivity(_ value: PostureSensitivity) {
        guard value != postureSensitivity else { return }
        postureSensitivity = value
    }

    func applyPostureColorTheme(_ theme: PostureColorTheme) {
        guard theme.colors != postureColors else { return }
        withAnimation(motion(NotchDesign.Motion.value)) {
            postureColors = theme.colors
        }
    }

    func setPostureColor(_ color: Color, for role: PostureColorRole) {
        var updated = postureColors
        switch role {
        case .good: updated.goodHex = color.hexString
        case .bad: updated.badHex = color.hexString
        case .warning: updated.warningHex = color.hexString
        }
        guard updated != postureColors else { return }
        postureColors = updated
    }

    func setPostureAlertRepeat(_ repeatMode: PostureAlertRepeat) {
        guard repeatMode != postureAlertRepeat else { return }
        postureAlertRepeat = repeatMode
    }

    func setPostureBadDelay(_ value: Double) {
        guard value != postureBadDelay else { return }
        postureBadDelay = value
    }

    private func updatePosturePreviewVisibility() {
        postureService.setPreviewVisible(isExpanded)
    }

    func start() {
        areApplicationServicesRunning = true
        postureService.badDelay = postureBadDelay
        postureService.sensitivity = postureSensitivity
        postureService.poseFallbackEnabled = posturePoseFallbackEnabled
        postureService.alertsEnabled = postureAlertsEnabled
        postureService.goodAlertsEnabled = postureGoodAlertsEnabled
        postureService.alertRepeat = postureAlertRepeat
        postureService.start(enabled: detectionPolicy.shouldRun)
        updatePosturePreviewVisibility()
        acceptsSystemHUDEvents = true
        startPostureStats()
        refreshLaunchAtLoginStatus()
        activityMonitor.start()
    }

    /// Turns the policy's verdict into a call on the detection service. The
    /// service is the only thing that owns the capture session, so this is what
    /// actually releases the camera and stops inference.
    func applyDetectionAction(_ action: BackgroundDetectionPolicy.Action) {
        switch action {
        case .none:
            break
        case .start:
            postureService.setEnabled(true)
        case .stop:
            postureService.setEnabled(false)
        }
    }

    func stop() {
        postureSession.flushHistory()
        areApplicationServicesRunning = false
        postureService.stop()
        posture = .offline
        acceptsSystemHUDEvents = false
        activityMonitor.stop()
        postureStatsTask?.cancel()
        postureStatsTask = nil
        systemHUDDismissTask?.cancel()
        hoverCollapseTask?.cancel()
        panelCloseTask?.cancel()
        settingsWindowTask?.cancel()
        sendPanelEvent(.reset)
    }

    func toggleExpanded() {
        log.notice("notch click: expanded=\(self.isExpanded, privacy: .public)")
        if isExpanded {
            collapseExpanded()
            return
        }
        guard !isPanelClosing else { return }
        sendPanelEvent(.workspaceOpened)
    }

    func collapseExpanded() {
        guard isExpanded, !isPanelClosing else { return }
        sendPanelEvent(.workspaceCloseRequested)
    }

    func setLeftWingContent(_ content: NotchWingContent) {
        withAnimation(motion(NotchDesign.Motion.value)) {
            leftWingContent = content
        }
    }

    func setRightWingContent(_ content: NotchWingContent) {
        withAnimation(motion(NotchDesign.Motion.value)) {
            rightWingContent = content
        }
    }

    func swapWingContents() {
        let previousLeft = leftWingContent
        withAnimation(motion(NotchDesign.Motion.value)) {
            leftWingContent = rightWingContent
            rightWingContent = previousLeft
        }
    }

    func resetWingContents() {
        withAnimation(motion(NotchDesign.Motion.value)) {
            leftWingContent = .posture
            rightWingContent = .posture
        }
    }

    func setNotchHovered(_ hovered: Bool) {
        if hovered {
            withAnimation(motion(NotchDesign.Motion.hover)) {
                sendPanelEvent(.pointerEntered)
            }
        } else {
            sendPanelEvent(.pointerExited)
        }
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func openSettings() {
        let shouldWaitForPanel = isExpanded || isPanelClosing
        if isExpanded {
            collapseExpanded()
        }

        settingsWindowTask?.cancel()
        settingsWindowTask = Task { [weak self] in
            if shouldWaitForPanel {
                try? await Task.sleep(for: .milliseconds(420))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled, let self else { return }
            if let settingsWindowOpener = self.settingsWindowOpener {
                settingsWindowOpener()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(
                    Selector(("showSettingsWindow:")),
                    to: nil,
                    from: nil
                )
            }
        }
    }

    // MARK: - Posture time

    /// Copies what the tracker read from disk into the published properties.
    /// Detection does not have to be running for this, which is what the
    /// screenshot tools rely on.
    func loadStoredStatistics() {
        postureStats = postureSession.stats
        postureHistory = postureSession.history
        postureGoal = postureSession.goal
        postureCycle = postureSession.cycle
        postureStreak = postureSession.streak
        postureGoalMet = postureSession.todayMet
    }

    private func startPostureStats() {
        loadStoredStatistics()

        postureSession.onChange = { [weak self] stats in
            self?.refreshPostureGoalState(stats)
        }
        postureSession.onHistoryChange = { [weak self] history in
            self?.postureHistory = history
            self?.postureStreak = self?.postureSession.streak ?? 0
        }
        postureSession.onCycleEvent = { [weak self] cycle in
            self?.presentCycleEvent(cycle)
        }
        postureSession.onCycleTick = { [weak self] cycle in
            self?.postureCycle = cycle
        }
        postureSession.onGoalChange = { [weak self] goal in
            self?.postureGoal = goal
            self?.refreshPostureGoalState(self?.postureSession.stats ?? .empty)
        }
        postureSession.onRestReminder = { [weak self] minutes in
            self?.presentRestReminder(minutes: minutes)
        }

        postureStatsTask?.cancel()
        postureStatsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let running = self.posture.isRunning
                self.postureSession.tick(
                    state: running && self.posture.confirmed ? self.posture.posture : nil,
                    isRunning: running
                )
                if self.restReminderEnabled, !self.postureSession.settings.enabled,
                   self.postureSession.reminderDue(
                       interval: self.restReminderMinutes
                   ),
                   !self.isBackgroundRefreshPaused {
                    let minutes = self.postureStats.sittingSeconds / 60
                    self.presentRestReminder(minutes: minutes)
                    // Restart the countdown so the next nudge comes one interval
                    // later while the totals for the day keep accumulating.
                    self.postureSession.takeBreak()
                    self.postureStats = self.postureSession.stats
                }
            }
        }
    }

    private func refreshPostureGoalState(_ stats: PostureStats) {
        postureStats = stats
        postureCycle = postureSession.cycle
        postureGoalMet = stats.meets(postureGoal)
        postureStreak = postureSession.streak
        postureHistory = postureSession.history
    }

    var postureCycleSettings: PostureCycleSettings { postureSession.settings }

    func setPostureCycleEnabled(_ enabled: Bool) {
        postureSession.setCycleEnabled(enabled)
        postureCycle = postureSession.cycle
        postureStats = postureSession.stats
        if !enabled, systemHUD?.kind == .cycle {
            sendPanelEvent(.hudDismissDelayElapsed(revision: panelState.effectRevisions.hud))
        }
    }

    func setPostureCycleFocus(_ minutes: Double) {
        postureSession.setCycleDurations(focus: minutes, breakLength: nil)
        postureCycle = postureSession.cycle
    }

    func setPostureCycleBreak(_ minutes: Double) {
        postureSession.setCycleDurations(focus: nil, breakLength: minutes)
        postureCycle = postureSession.cycle
    }

    func startPostureBreakNow() {
        postureSession.startBreakNow()
        postureCycle = postureSession.cycle
    }

    func skipPostureRest() {
        postureSession.skipRest()
        postureCycle = postureSession.cycle
    }

    func setPostureGoalShare(_ share: Double) {
        postureSession.setGoalTarget(share: share)
        postureGoal = postureSession.goal
        refreshPostureGoalState(postureSession.stats)
    }

    func selectRestReminderPreset(_ minutes: Double) {
        restReminderUsesCustom = false
        restReminderMinutes = minutes
    }

    func selectRestReminderCustom() {
        restReminderUsesCustom = true
        restReminderMinutes = restReminderCustomMinutes
    }

    func setRestReminderCustomMinutes(_ minutes: Int) {
        let clamped = min(max(minutes, 1), 600)
        restReminderCustomMinutes = Double(clamped)
        restReminderUsesCustom = true
        restReminderMinutes = Double(clamped)
    }

    /// One switch for both reminder flavours: the selected mode is the only
    /// one that runs.
    var restReminderActive: Bool {
        restReminderMode == .cycle ? postureCycleSettings.enabled : restReminderEnabled
    }

    func setRestReminderActive(_ active: Bool) {
        switch restReminderMode {
        case .cycle:
            setPostureCycleEnabled(active)
            if active { restReminderEnabled = false }
        case .interval:
            restReminderEnabled = active
            if active { setPostureCycleEnabled(false) }
        }
    }

    /// Switching modes hands the on/off state over instead of leaving two
    /// reminders armed at once.
    func setRestReminderMode(_ mode: PostureRestReminderMode) {
        guard mode != restReminderMode else { return }
        let wasActive = restReminderActive
        switch mode {
        case .cycle:
            restReminderEnabled = false
        case .interval:
            setPostureCycleEnabled(false)
        }
        restReminderMode = mode
        guard wasActive else { return }
        switch mode {
        case .cycle:
            setPostureCycleEnabled(true)
        case .interval:
            restReminderEnabled = true
        }
    }

    func resetPostureStats() {
        postureSession.resetToday()
        postureStats = postureSession.stats
    }

    /// Shared by the hover HUD and phase-change announcements; reads live countdown state.
    var postureCycleHUD: SystemHUDSnapshot {
        let cycle = postureCycle
        let subtitle: String
        if cycle.phase == .rest {
            subtitle = localized("Get up and move")
        } else if !posture.isRunning || !posture.confirmed || posture.posture == .unknown {
            subtitle = localized("Focus paused · Waiting for detection")
        } else {
            subtitle = localizedFormat("%d min focus · %d min break",
                Int(postureCycleSettings.focusMinutes), Int(postureCycleSettings.breakMinutes))
        }
        return SystemHUDSnapshot(
            kind: .cycle,
            title: "\(localized(cycle.phase.title)) \(cycle.countdownText)",
            subtitle: subtitle,
            symbol: cycle.phase == .rest ? "figure.walk" : "timer",
            value: cycle.progress,
            accent: cycle.phase == .rest ? .warning : .positive
        )
    }

    private func presentCycleEvent(_ cycle: PostureCycle) {
        postureCycle = cycle
        log.notice("cycle event -> \(cycle.phase.rawValue, privacy: .public)")
        showSystemHUD(postureCycleHUD)
    }

    private func presentRestReminder(minutes: Double) {
        guard restReminderEnabled else { return }
        log.notice("rest reminder after \(Int(minutes.rounded()), privacy: .public) min")
        showSystemHUD(
            .restReminder(
                title: localized("Time to move"),
                subtitle: localizedFormat("Sitting for %d minutes", Int(minutes.rounded()))
            )
        )
    }

    /// Posture alerts surface as a short notch HUD.
    private func presentPostureAlert(_ alert: PostureAlert) {
        guard alert.isPositive ? postureGoodAlertsEnabled : postureAlertsEnabled else { return }
        showSystemHUD(.posture(alert))
    }

    private func showSystemHUD(_ snapshot: SystemHUDSnapshot) {
        guard acceptsSystemHUDEvents,
              !isBackgroundRefreshPaused else { return }
        let isContinuousUpdate = systemHUD?.kind == snapshot.kind

        withAnimation(
            motion(
                isContinuousUpdate
                    ? NotchDesign.Motion.value
                    : NotchDesign.Motion.panelOpen
            )
        ) {
            sendPanelEvent(.hudReceived(snapshot))
        }
    }
}
