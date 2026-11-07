import SwiftUI

struct SettingsRootView: View {
    private enum Destination: String, Hashable, CaseIterable {
        case appearance
        case posture
        case training
        case health
        case permissions
        case behavior
        case about

        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .posture: return "Posture"
            case .training: return "Training"
            case .health: return "Health"
            case .permissions: return "Permissions"
            case .behavior: return "General"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "square.on.square"
            case .posture: return "figure.seated.side"
            case .training: return "cpu"
            case .health: return "heart.text.square"
            case .permissions: return "lock"
            case .behavior: return "slider.horizontal.3"
            case .about: return "info.circle"
            }
        }
    }

    @ObservedObject var model: AppModel
    let onPaneChange: @MainActor (String) -> Void
    @AppStorage("INT4154.Settings.selectedPane") private var selectedPane = "appearance"
    @AppStorage("INT4154.Settings.sidebarCollapsed") private var sidebarCollapsed = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(NotchDesign.Palette.hairline)
                .frame(width: 1)

            GeometryReader { viewport in
                let inset: CGFloat = viewport.size.width < 700 ? 24 : 46
                ScrollView {
                    detailView
                        .frame(width: max(0, viewport.size.width - inset * 2), alignment: .leading)
                        .padding(.horizontal, inset)
                        .padding(.top, 40)
                        .padding(.bottom, 46)
                }
            }
        }
        .background(NotchDesign.Palette.canvas)
        .frame(minWidth: 780, idealWidth: 900, minHeight: 560, idealHeight: 660)
        .environment(\.locale, model.appLanguage.locale)
        .onAppear {
            model.refreshLaunchAtLoginStatus()
            onPaneChange(localizedSettingsWindowTitle)
        }
        .onChange(of: selectedPane) { _, rawValue in
            let destination = Destination(rawValue: rawValue) ?? .appearance
            onPaneChange(localizedSettingsWindowTitle(for: destination))
        }
        .onChange(of: model.appLanguage) { _, _ in
            onPaneChange(localizedSettingsWindowTitle)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        SettingsSidebar(
            title: "LearnWell",
            subtitle: "INT4154 Project",
            sections: sidebarSections,
            footer: sidebarItems(for: [.about]),
            selection: $selectedPane,
            collapsed: $sidebarCollapsed,
            language: model.appLanguage,
            animation: model.motion(SettingsSidebar.collapseAnimation)
        )
    }

    private var sidebarSections: [SettingsSidebarSection] {
        [
            SettingsSidebarSection(
                id: "monitoring",
                title: "Monitoring",
                items: sidebarItems(for: [.appearance, .posture, .training, .health])
            ),
            SettingsSidebarSection(
                id: "app",
                title: "App",
                items: sidebarItems(for: [.permissions, .behavior])
            )
        ]
    }

    private func sidebarItems(for destinations: [Destination]) -> [SettingsSidebarItem] {
        destinations.map {
            SettingsSidebarItem(id: $0.rawValue, title: $0.title, symbol: $0.symbol)
        }
    }

    // MARK: - Pages

    private var currentDestination: Destination {
        // "classroom" was this pane's stored value before it became Training.
        if selectedPane == "classroom" { return .training }
        return Destination(rawValue: selectedPane) ?? .appearance
    }

    private var localizedSettingsWindowTitle: String {
        localizedSettingsWindowTitle(for: currentDestination)
    }

    private func localizedSettingsWindowTitle(for destination: Destination) -> String {
        "\(model.productName) \(model.localized("Settings")) — \(model.localized(destination.title))"
    }

    @ViewBuilder
    private var detailView: some View {
        switch currentDestination {
        case .appearance: appearancePage
        case .posture: posturePage
        case .training: ClassroomPage(model: model, store: model.classroom)
        case .health: healthPage
        case .permissions: permissionsPage
        case .behavior: behaviorPage
        case .about: aboutPage
        }
    }

    private var appearancePage: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "Choose what each side of the notch shows, and the alert colours."
        ) {
            SettingsGroup(title: "Notch Layout", footnote: "Choose posture, temperature, humidity or combined temperature and humidity for each side. Climate readings require a DHT11 on D2 and Arduino sensors enabled.") {
                notchPreview
                    .padding(.vertical, 6)

                SettingsRowDivider()

                HStack(spacing: 14) {
                    wingSelector("Left", selection: Binding(
                        get: { model.leftWingContent },
                        set: { model.setLeftWingContent($0) }
                    ))

                    Button { model.swapWingContents() } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(NotchDesign.Palette.secondaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(model.localized("Swap Sides"))

                    wingSelector("Right", selection: Binding(
                        get: { model.rightWingContent },
                        set: { model.setRightWingContent($0) }
                    ))
                }

                SettingsRowDivider()

                HStack {
                    Button("Restore default layout") { model.resetWingContents() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NotchDesign.Palette.text)
                    Spacer(minLength: 0)
                }
            }

            PostureColorSettingsCard(model: model)
        }
    }

    private var notchPreview: some View {
        SettingsNotchPreview(
            notchWidth: model.notchWidth,
            height: min(model.menuBarHeight, 40),
            leftWingWidth: NotchLayout.compactWingWidth(for: model.leftWingContent),
            rightWingWidth: NotchLayout.compactWingWidth(for: model.rightWingContent)
        ) {
            CompactWingSlot(model: model, content: model.leftWingContent)
        } rightWing: {
            CompactWingSlot(model: model, content: model.rightWingContent)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(model.localized("Notch layout preview"))
    }

    private func wingSelector(_ title: String, selection: Binding<NotchWingContent>) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5))
                .foregroundStyle(NotchDesign.Palette.secondaryText)

            Picker(LocalizedStringKey(title), selection: selection) {
                ForEach(NotchWingContent.allCases) { content in
                    Text(LocalizedStringKey(content.title)).tag(content)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 180)
        }
        .frame(maxWidth: .infinity)
    }

    private var healthPage: some View {
        SettingsPage(
            title: "Health",
            subtitle: "Posture time, trends, time slots and the recovery you have built up today."
        ) {
            PostureGoalCard(model: model)
            PostureTimeStatsCard(model: model)
            PostureTrendCard(model: model)
            PostureHeatmapCard(model: model)
            PostureRestRhythmCard(model: model)
        }
    }

    private var posturePage: some View {
        SettingsPage(
            title: "Posture",
            subtitle: "Detect posture with the camera and show reminders through the notch and progressive blur."
        ) {
            PostureSettingsGroup(model: model)
        }
    }

    private var behaviorPage: some View {
        SettingsPage(
            title: "General",
            subtitle: "Controls the interface language and how the app starts after login."
        ) {
            SettingsGroup(title: "Language") {
                HStack(spacing: 12) {
                    SettingsRowLabel(
                        title: "Interface language",
                        subtitle: "Choose the display language for LearnWell.",
                        symbol: "globe"
                    )
                    Spacer(minLength: 12)
                    Picker("Interface language", selection: Binding(
                        get: { model.appLanguage },
                        set: { model.setAppLanguage($0) }
                    )) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(LocalizedStringKey(language.title)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 152)
                }
            }

            SettingsGroup(title: "Login Items") {
                HStack(spacing: 12) {
                    SettingsRowLabel(
                        title: "Launch LearnWell at login",
                        subtitle: model.launchAtLoginStatusDescription,
                        symbol: "power"
                    )
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if model.launchAtLoginRequiresApproval {
                    SettingsRowDivider()
                    Button {
                        model.openLoginItemsSettings()
                    } label: {
                        SettingsRowLabel(
                            title: "Approve Login Item",
                            subtitle: "System Settings needs to confirm the LearnWell login item.",
                            symbol: "checkmark.shield"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            SettingsGroup(title: "Background detection") {
                SettingsRowLabel(
                    title: model.isBackgroundRefreshPaused ? "Detection paused" : "Detection running",
                    subtitle: model.isBackgroundRefreshPaused
                        ? "Camera analysis pauses while the screen is locked or the system sleeps."
                        : "Pauses automatically on lock or sleep to avoid wasting power.",
                    statusMark: model.isBackgroundRefreshPaused ? .paused : .running
                )
            }
        }
    }

    private var permissionsPage: some View {
        SettingsPage(
            title: "Permissions",
            subtitle: "Posture detection requires camera access."
        ) {
            SettingsGroup(title: "Camera") {
                SettingsStatusRow(
                    title: "Camera access",
                    subtitle: cameraStatusDescription,
                    symbol: "camera",
                    tint: cameraStatusTint
                )

                SettingsRowDivider()

                HStack(spacing: 10) {
                    Button("Request or retry") { model.launchPostureMonitor() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Open System Settings…") { model.openPostureCameraPrivacySettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                    Spacer(minLength: 0)
                }
            }

            SettingsGroup(title: "Permission Details") {
                SettingsRowLabel(
                    title: "Camera",
                    subtitle: "Frames are read only while background detection is on and are analysed locally; nothing is written to disk or uploaded.",
                    symbol: "video"
                )
                SettingsRowDivider()
                SettingsRowLabel(
                    title: "Notifications and automation",
                    subtitle: "This build only detects posture; it no longer reads notifications, playback or battery data.",
                    symbol: "hand.raised"
                )
            }
        }
    }

    private var cameraStatusDescription: String {
        switch model.postureRuntime {
        case .stopped: return "Not running; the camera is requested once background detection is on"
        case .starting: return "Starting the camera…"
        case .running: return "Authorised and running"
        case .needsPermission: return "Waiting for you to allow camera access"
        case .denied: return "Denied in System Settings"
        case .unavailable(let reason): return reason
        }
    }

    private var cameraStatusTint: Color {
        switch model.postureRuntime {
        case .running: return .green
        case .denied, .unavailable: return .red
        case .needsPermission, .starting: return .orange
        case .stopped: return NotchDesign.Palette.eyebrow
        }
    }

    /// Matches the notices in licenses/ and Sources/ThirdParty/.
    private static let openSourceReferences: [(name: String, license: String, url: String)] = [
        ("Ultralytics YOLO (YOLO26)", "AGPL-3.0", "https://github.com/ultralytics/ultralytics"),
        ("Google MediaPipe", "Apache-2.0", "https://github.com/google-ai-edge/mediapipe"),
        ("PyTorch", "BSD-3-Clause", "https://github.com/pytorch/pytorch"),
        ("OpenCV", "Apache-2.0", "https://github.com/opencv/opencv"),
        ("Core ML Tools", "BSD-3-Clause", "https://github.com/apple/coremltools"),
        ("Dorso", "MIT", "https://github.com/tldev/dorso"),
        ("Adafruit DHT Sensor Library", "MIT", "https://github.com/adafruit/DHT-sensor-library")
    ]

    private var aboutPage: some View {
        SettingsPage(
            title: "About",
            subtitle: "Turn the notch into a posture hint you can read at a glance."
        ) {
            SettingsGroup {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("LearnWell")
                            .font(NotchDesign.Typography.cardTitle)
                            .foregroundStyle(NotchDesign.Palette.text)
                        Text(verbatim: "INT4154 Project")
                            .font(NotchDesign.Typography.caption)
                            .foregroundStyle(NotchDesign.Palette.secondaryText)
                        Text("Posture, climate and study comfort")
                            .font(NotchDesign.Typography.caption)
                            .foregroundStyle(NotchDesign.Palette.secondaryText)
                    }
                    Spacer(minLength: 0)
                }

                SettingsRowDivider()

                Text("The model, camera and serial link all run inside the app: the camera is granted once, and alerts appear as a notch HUD.")
                    .font(NotchDesign.Typography.caption)
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(title: "Open-Source References", footnote: "This project uses the following open-source projects, each under its own license.") {
                ForEach(Self.openSourceReferences, id: \.name) { reference in
                    Link(destination: URL(string: reference.url)!) {
                        HStack {
                            Text(verbatim: reference.name)
                                .foregroundStyle(NotchDesign.Palette.text)
                            Spacer(minLength: 8)
                            Text(verbatim: reference.license)
                                .foregroundStyle(NotchDesign.Palette.secondaryText)
                        }
                        .font(NotchDesign.Typography.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            SettingsGroup(title: "Quick Actions") {
                Button {
                    model.quitApplication()
                } label: {
                    SettingsRowLabel(
                        title: "Quit LearnWell",
                        symbol: "power",
                        tint: .red
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
