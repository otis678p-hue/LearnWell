import AppKit
import SwiftUI

/// Ring colour reports posture; the central glyph independently reports Arduino.
struct PostureStatusRing: View {
    let snapshot: PostureSnapshot
    var diameter: CGFloat = 22
    var colors: PostureColors = .classic
    var lineWidth: CGFloat? = nil

    private var tint: Color {
        colors.color(for: snapshot.posture)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(NotchDesign.Palette.track, lineWidth: strokeWidth + 2)

            Circle()
                .trim(from: 0, to: 0.999)
                .stroke(
                    tint.opacity(snapshot.isRunning ? 1 : 0.35),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: snapshot.arduino.symbol)
                .font(.system(size: diameter * 0.34, weight: .semibold))
                .foregroundStyle(
                    snapshot.arduino == .connected ? tint.opacity(0.9) : Color.white.opacity(0.35)
                )
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(Text(LocalizedStringKey(snapshot.title))) · \(Text(LocalizedStringKey(snapshot.arduino.title)))")
        )
    }

    private var strokeWidth: CGFloat {
        lineWidth ?? max(2.2, diameter * 0.11)
    }
}

struct PostureHoverStatus: View {
    @ObservedObject var model: AppModel
    let side: NotchWingSide

    var body: some View {
        HStack(spacing: 8) {
            if side == .left {
                PostureStatusRing(snapshot: model.posture, diameter: 18, colors: model.postureColors)
            }

            VStack(alignment: side == .left ? .leading : .trailing, spacing: 1) {
                Text(model.localized(model.posture.title))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.postureColors.color(for: model.posture.posture))
                Text(model.postureDetailText)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            if side == .right {
                PostureStatusRing(snapshot: model.posture, diameter: 18, colors: model.postureColors)
            }
        }
    }
}

// MARK: - Settings card

struct PostureSettingsGroup: View {
    @ObservedObject var model: AppModel

    private var sensitivityBinding: Binding<PostureSensitivity> {
        Binding(
            get: { model.postureSensitivity },
            set: { model.setPostureSensitivity($0) }
        )
    }

    private var repeatBinding: Binding<PostureAlertRepeat> {
        Binding(
            get: { model.postureAlertRepeat },
            set: { model.setPostureAlertRepeat($0) }
        )
    }

    private var delayBinding: Binding<Double> {
        Binding(
            get: { model.postureBadDelay },
            set: { model.setPostureBadDelay($0) }
        )
    }

    private var previewKinds: [PostureAlert.Kind] {
        var kinds: [PostureAlert.Kind] = []
        if model.postureAlertsEnabled { kinds.append(.badPosture) }
        if model.postureArduinoEnabled { kinds.append(.tooClose) }
        if model.postureGoodAlertsEnabled { kinds.append(.good) }
        return kinds.isEmpty ? [.badPosture] : kinds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchDesign.Spacing.section) {
            statusCard
            SettingsGroup(title: "Temperature & Humidity") {
                PostureEnvironmentView(model: model)
            }
            cameraCard
            detectionCard
            blurCard
            alertCard
        }
    }

    // MARK: status

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 18) {
            PostureStatusRing(
                snapshot: model.posture,
                diameter: 46,
                colors: model.postureColors,
                lineWidth: 5
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(model.localized(statusTitle))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        model.posture.isRunning
                            ? model.postureColors.color(for: model.posture.posture)
                            : NotchDesign.Palette.text
                    )

                Text(model.localized(statusSubtitle))
                    .font(NotchDesign.Typography.caption)
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
            }

            Spacer(minLength: 12)

            if let distance = model.posture.distanceCM {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f", distance))
                        .font(NotchDesign.Typography.metric)
                        .foregroundStyle(NotchDesign.Palette.text)
                    Text("cm")
                        .font(NotchDesign.Typography.eyebrow)
                        .foregroundStyle(NotchDesign.Palette.eyebrow)
                }
            }

            Button {
                model.launchPostureMonitor()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .frame(width: 26, height: 26)
                    .insetSurface(cornerRadius: 8)
            }
            .buttonStyle(.plain)
            .help(model.localized("Restart posture detection"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var statusTitle: String {
        if model.postureCalibration.isActive { return "Calibrating posture" }
        if model.posture.isRunning { return model.posture.title }
        switch model.postureRuntime {
        case .stopped: return "Posture detection is not running"
        case .starting: return "Starting posture detection…"
        case .needsPermission: return "Waiting for camera permission"
        case .denied: return "Camera permission denied"
        case .unavailable: return "Posture detection unavailable"
        case .running: return model.posture.title
        }
    }

    private var statusSubtitle: String {
        if model.posture.isRunning {
            return model.postureDetailText
        }
        switch model.postureRuntime {
        case .stopped: return "Turn on background detection to start analysing posture"
        case .starting: return "Preparing the camera and model"
        case .needsPermission: return "Allow camera access in the system prompt"
        case .denied: return "Check the Permissions page for camera status"
        case .unavailable(let message): return message
        case .running:
            return model.posture.isRunning ? model.postureDetailText : "Waiting for the camera feed"
        }
    }

    private var cameraCard: some View {
        SettingsGroup(title: "Posture detection", footnote: "Images are processed locally and are never saved or uploaded.") {
            SettingsRowLabel(
                title: "Camera analysis",
                subtitle: "The YOLO model analyzes camera frames locally.",
                symbol: "video"
            )
            SettingsRowDivider()
            PosturePreviewSizeControls(model: model)
            Text("Drag the handle at the bottom of the preview or use the slider to adjust its height. Your size is saved automatically.")
                .font(NotchDesign.Typography.caption)
                .foregroundStyle(NotchDesign.Palette.secondaryText)
        }
    }

    private var blurCard: some View {
        SettingsGroup(title: "Screen blur reminder") {
            toggleRow("Progressive screen blur", subtitle: "Adjust posture and distance blur strength, or blur the screen when you leave your desk.", isOn: $model.postureBlurEnabled)
            if model.postureBlurEnabled {
                SettingsRowDivider()
                blurSliderRow("Blur intensity", value: blurBinding(\.intensity), range: 0.5...2, step: 0.1,
                              display: String(format: "%.0f%%", model.postureBlurSettings.intensity * 100))
                Text("50% is gentler, 100% is the default, and 200% is stronger. Changes apply immediately.")
                    .font(NotchDesign.Typography.caption)
                    .foregroundStyle(NotchDesign.Palette.secondaryText)

                SettingsRowDivider()
                valueRow("Bad posture alert delay") {
                    Picker("Bad posture alert delay", selection: delayBinding) {
                        ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { value in
                            Text(model.localizedFormat("%d sec", Int(value))).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                SettingsRowDivider()
                toggleRow("Blur for distance", subtitle: "Uses the Arduino ultrasonic sensor. These controls adjust blur; distance alerts and the LED keep their 50 cm threshold.", isOn: blurBinding(\.distanceEnabled))
                if model.postureBlurSettings.distanceEnabled {
                    blurSliderRow("Start blur below", value: blurBinding(\.startDistanceCM), range: 20...100, step: 5,
                                  display: String(format: "%.0f cm", model.postureBlurSettings.startDistanceCM))
                    blurSliderRow("Strongest blur at", value: blurBinding(\.fullDistanceCM),
                                  range: 5...(model.postureBlurSettings.startDistanceCM - 5), step: 5,
                                  display: String(format: "%.0f cm", model.postureBlurSettings.fullDistanceCM))
                    Text("After you stay closer than the starting distance for the reminder delay, blur increases as you move closer.")
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsRowDivider()
                toggleRow("Blur when away", subtitle: "After the camera has seen you, blur begins when no person is detected for the chosen delay. It clears when someone returns.", isOn: blurBinding(\.awayEnabled))
                if model.postureBlurSettings.awayEnabled {
                    blurSliderRow("Away delay", value: blurBinding(\.awayDelay), range: 1...60, step: 1,
                                  display: model.localizedFormat("%d sec", Int(model.postureBlurSettings.awayDelay)))
                    Text("The camera detects when you leave your desk. Blur clears if the camera stops, monitoring pauses, or the screen locks.")
                        .font(NotchDesign.Typography.caption)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Blur applies to all displays. Mouse and keyboard still work, and you can turn it off at any time.")
                    .font(NotchDesign.Typography.caption)
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func blurBinding<Value>(_ keyPath: WritableKeyPath<PostureBlurSettings, Value>) -> Binding<Value> {
        Binding(get: { model.postureBlurSettings[keyPath: keyPath] }, set: { value in
            var settings = model.postureBlurSettings
            settings[keyPath: keyPath] = value
            model.postureBlurSettings = settings.normalized
        })
    }

    private func blurSliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                               step: Double, display: String) -> some View {
        valueRow(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step) { Text(LocalizedStringKey(title)) }
                    .labelsHidden()
                    .frame(width: 135)
                    .accessibilityValue(display)
                Text(display)
                    .font(NotchDesign.Typography.value)
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }

    // MARK: detection

    private var detectionCard: some View {
        SettingsGroup(title: "Detection", footnote: "Bad posture needs 2 continuous seconds; recovery needs 0.6 seconds. The alert delay starts with the initial bad reading, and alerts wait for confirmation.") {
            toggleRow(
                "Start detection with LearnWell",
                subtitle: "Use the camera to keep checking posture in the background after launch.",
                isOn: $model.postureMonitoringEnabled
            )

            SettingsRowDivider()

            toggleRow(
                "Pose assistance and cross-checking",
                subtitle: "Helps when the model cannot decide and shows Unknown when clear pose evidence conflicts. After manual calibration, also checks possible false bad-posture alerts.",
                isOn: Binding(
                    get: { model.posturePoseFallbackEnabled },
                    set: { model.setPosturePoseFallbackEnabled($0) }
                )
            )

            SettingsRowDivider()

            PostureCalibrationControls(model: model)

            SettingsRowDivider()

            toggleRow(
                "Use Arduino sensors",
                subtitle: "Automatically connects distance and D2 climate sensors; alerts when you sit too close.",
                isOn: $model.postureArduinoEnabled
            )


                SettingsRowDivider()
                valueRow("Detection sensitivity", subtitle: "Strict 0.60 · Regular 0.50 · Relaxed 0.40 · Sensitive 0.30") {
                Picker("Detection sensitivity", selection: sensitivityBinding) {
                    ForEach(PostureSensitivity.allCases) { value in
                        Text(LocalizedStringKey(value.title)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 268)
            }
            
        }
    }

    // MARK: alerts

    private var alertCard: some View {
        SettingsGroup(title: "Notch alerts") {
            toggleRow(
                "Notch alert for bad posture",
                subtitle: "Appears once bad posture has lasted the delay.",
                isOn: $model.postureAlertsEnabled
            )

            SettingsRowDivider()

            toggleRow(
                "Notch alert for good posture",
                subtitle: "Shows once when you sit up straight.",
                isOn: $model.postureGoodAlertsEnabled
            )

            if model.postureAlertsEnabled {
                SettingsRowDivider()

                valueRow("Alert repeat") {
                    Picker("Alert repeat", selection: repeatBinding) {
                        ForEach(PostureAlertRepeat.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 268)
                }

                SettingsRowDivider()

                valueRow("Bad posture alert delay") {
                    Picker("Bad posture alert delay", selection: delayBinding) {
                        ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { value in
                            Text(model.localizedFormat("%d sec", Int(value))).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 268)
                }
            }

            SettingsRowDivider()

            PostureAlertPreview(alertOrder: previewKinds, colors: model.postureColors)
        }
    }

    // MARK: rows

    private func toggleRow(
        _ title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            SettingsRowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func valueRow<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            SettingsRowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 12)
            control()
        }
    }
}

// MARK: - Notch panel
struct PostureDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: NotchDesign.Spacing.group) {
            VStack(spacing: 10) {
                header
                PosturePreview(model: model)
                PostureCalibrationControls(model: model)
                if model.postureArduinoEnabled && !model.postureCalibration.isActive {
                    PostureEnvironmentView(model: model)
                }
                Divider()
                    .opacity(0.32)
                controls
            }
            .padding(14)
            .panelGroupSurface()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 11) {
            PostureStatusRing(
                snapshot: model.posture,
                diameter: 32,
                colors: model.postureColors
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(model.localized(statusTitle))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.posture.isRunning
                                     ? model.postureColors.color(for: model.posture.posture)
                                     : .primary)
                    .lineLimit(1)
                Text(model.localized(subtitle))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let distance = model.posture.distanceCM {
                HStack(spacing: 5) {
                    Image(systemName: "ruler")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(String(format: "%.1f cm", distance))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(model.posture.tooClose ? Color.red : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.primary.opacity(0.06), in: Capsule())
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Toggle("Background detection", isOn: $model.postureMonitoringEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()

            Toggle(isOn: $model.postureAlertsEnabled) {
                Label("Alert", systemImage: "bell")
                    .font(.system(size: 11, weight: .medium))
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            .help(model.localized("Show a notch alert when bad posture lasts past the alert delay; change the frequency in Settings"))
            .accessibilityLabel(model.localized("Bad posture alert"))

            Spacer(minLength: 0)

            Text(model.localized(hint))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var statusTitle: String {
        if model.postureCalibration.isActive { return "Calibrating posture" }
        if model.posture.isRunning { return model.posture.title }
        switch model.postureRuntime {
        case .starting: return "Starting posture detection…"
        case .needsPermission: return "Camera access required"
        case .denied: return "Camera access was denied"
        case .unavailable(let message): return message
        case .stopped: return "Posture detection is not running"
        case .running: return model.posture.title
        }
    }

    private var subtitle: String {
        if model.postureCalibration.isActive { return "Sit upright and follow the guidance below the preview" }
        guard model.posture.isRunning else {
            switch model.postureRuntime {
            case .stopped: return "Turn on background detection to start analysing posture"
            case .running: return "Waiting for the camera preview"
            default: return "Analysed on this Mac; nothing is saved"
            }
        }
        if model.posture.poseAssistanceUnavailable { return "MediaPipe is unavailable. Check the local Python environment." }
        if model.posture.poseConflict { return "Model and pose disagree; posture is temporarily unknown" }
        if model.posture.pendingPosture != nil { return "Confirming a posture change; please hold steady" }
        if model.posture.peopleCount > 1 { return "Several people detected. Keep one person in view." }
        if !model.posture.confirmed {
            if model.posture.bestScore > 0.01 {
                return model.localized("Below confidence") + String(format: " · %.0f%%", model.posture.bestScore * 100)
            }
            if let zone = model.posture.zone { return zone.title }
            if model.posture.peopleCount == 1 { return "Person detected; posture cannot yet be confirmed" }
            return "No single person detected; posture unknown"
        }
        if model.posture.confirmed, model.posture.confidence != nil {
            return "\(model.localized(model.posture.arduino.title)) · \(model.postureDetailText)"
        }
        return model.posture.arduino.title
    }

    private var hint: String {
        if model.postureArduinoEnabled {
            return model.posture.arduino == .connected
                ? "Arduino connected · keeps detecting when collapsed"
                : "Keeps detecting when collapsed · analysed on this Mac"
        }
        return "Analysed on this Mac · never saved or uploaded"
    }
}

private struct PosturePreview: View {
    @ObservedObject var model: AppModel
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        VStack(spacing: 6) {
            cameraImage
            PosturePreviewSizeControls(model: model)
        }
    }

    private var cameraImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black)

            if let image = model.posturePreview {
                // Calibration must show the full frame, so visible shoulders are not
                // accidentally hidden by the dashboard's shallow preview crop.
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: model.postureCalibration.isActive || model.posturePreviewFullFrame ? .fit : .fill)
                    }
                    .accessibilityLabel(model.localized("Live posture camera preview"))
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .frame(height: model.posturePreviewHeight)
        .frame(maxWidth: .infinity)
        // Anchor the status chips to the whole preview, so they cannot overlap on
        // portrait or narrow camera frames.
        .overlay(alignment: .bottomLeading) {
            if model.posturePreview != nil { badge }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.posturePreview != nil { arduinoBadge }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(.white.opacity(0.7))
                .frame(width: 32, height: 3)
                .padding(.horizontal, 15)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .contentShape(Rectangle())
                .padding(.bottom, 4)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = model.posturePreviewHeight }
                        model.setPosturePreviewHeight((dragStartHeight ?? model.posturePreviewHeight)
                            + value.translation.height)
                    }
                    .onEnded { _ in dragStartHeight = nil })
                .onHover { hovering in
                    if hovering { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
                }
                .help(model.localized("Drag to resize the preview height"))
                .accessibilityLabel(model.localized("Resize camera preview"))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.setPosturePreviewHeight(model.posturePreviewHeight + 10)
                    case .decrement: model.setPosturePreviewHeight(model.posturePreviewHeight - 10)
                    @unknown default: break
                    }
                }
        }
        .animation(NotchDesign.Motion.value, value: model.posturePreview == nil)
    }

    private var badge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.postureColors.color(for: model.posture.posture))
                .frame(width: 6, height: 6)
            Text(model.localized(model.posture.title))
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.42), in: Capsule())
        .padding(10)
    }

    private var arduinoBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: model.posture.arduino.symbol)
                .font(.system(size: 9, weight: .bold))
            Text(model.localized(model.posture.arduino.title))
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.42), in: Capsule())
        .padding(10)
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 12) {
            switch model.postureRuntime {
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text("Starting posture detection…")
            case .needsPermission:
                Image(systemName: "camera.badge.ellipsis")
                    .font(.system(size: 26, weight: .light))
                Text("Allow LearnWell to use the camera to start detecting.")
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Allow access") { model.launchPostureMonitor() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            case .denied:
                Image(systemName: "camera.fill")
                    .font(.system(size: 26, weight: .light))
                Text("Camera access was denied. Allow it again in System Settings.")
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Open System Settings") { model.openPostureCameraPrivacySettings() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            case .unavailable(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .light))
                Text(LocalizedStringKey(message))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("Retry") { model.launchPostureMonitor() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            case .stopped:
                Image(systemName: "figure.seated.side")
                    .font(.system(size: 26, weight: .light))
                Text("Turn on background detection to see the live feed and distance here.")
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            case .running:
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for camera preview…")
            }
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.75))
        .padding(24)
    }
}

// MARK: - Alert preview

/// Shows the notch reminder exactly as it appears, so the switches above have
/// something concrete to point at.
struct PostureAlertPreview: View {
    let alertOrder: [PostureAlert.Kind]
    var colors: PostureColors = .classic
    @State private var selected: PostureAlert.Kind = .badPosture

    private var activeKind: PostureAlert.Kind {
        alertOrder.contains(selected) ? selected : (alertOrder.first ?? .badPosture)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Alert preview")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black)

                SystemHUDRow(
                    snapshot: .posture(PostureAlert(kind: activeKind)),
                    colors: colors
                )
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
            .frame(height: 54)
            .frame(maxWidth: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            }
            .animation(NotchDesign.Motion.value, value: activeKind)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(LocalizedStringKey(PostureAlert(kind: activeKind).title))
                    + Text(" ")
                    + Text(LocalizedStringKey("Alert preview"))
            )

            if alertOrder.count > 1 {
                Picker("Alert preview", selection: $selected) {
                    ForEach(alertOrder) { kind in
                        Text(LocalizedStringKey(PostureAlert(kind: kind).title)).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }

            Text(LocalizedStringKey(hint(for: activeKind)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hint(for kind: PostureAlert.Kind) -> String {
        switch kind {
        case .badPosture: return "Shown in the notch once bad posture lasts past the alert delay."
        case .tooClose: return "Shown when the Arduino sensor reads closer than 50 cm."
        case .good: return "Shown once after you sit up straight, as positive feedback."
        }
    }
}

// MARK: - Alert colours card (appearance settings)

struct PostureColorSettingsCard: View {
    @ObservedObject var model: AppModel

    private func colorBinding(for role: PostureColorRole) -> Binding<Color> {
        Binding(
            get: {
                switch role {
                case .good: return model.postureColors.good
                case .bad: return model.postureColors.bad
                case .warning: return model.postureColors.warning
                }
            },
            set: { model.setPostureColor($0, for: role) }
        )
    }

    private var activePreset: PostureColorTheme? {
        model.postureColors.matchingTheme
    }

    var body: some View {
        SettingsGroup(
            title: "Alert colours",
            footnote: activePreset.map { model.localized($0.subtitle) }
                ?? model.localized("Custom colours: presets are just a starting point — each of the three states can be adjusted.")
        ) {
            HStack(spacing: 8) {
                ForEach(PostureColorTheme.allCases) { theme in
                    Button {
                        model.applyPostureColorTheme(theme)
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 3) {
                                Circle().fill(theme.colors.good).frame(width: 10, height: 10)
                                Circle().fill(theme.colors.bad).frame(width: 10, height: 10)
                                Circle().fill(theme.colors.warning).frame(width: 10, height: 10)
                            }
                            Text(LocalizedStringKey(theme.title))
                                .font(.system(
                                    size: 9.5,
                                    weight: activePreset == theme ? .semibold : .medium
                                ))
                                // The selected chip paints a near-black background,
                                // so its label has to flip to white — a semantic
                                // .secondary would stay dark and disappear.
                                .foregroundStyle(
                                    activePreset == theme
                                        ? Color.white
                                        : NotchDesign.Palette.secondaryText
                                )
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Equal-height chips: English preset names are wider
                        // than the Chinese ones, so a wrapped label must not
                        // leave one chip taller than its neighbours.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .background(
                            activePreset == theme
                                ? NotchDesign.Palette.selected
                                : NotchDesign.Palette.track,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    activePreset == theme
                                        ? Color.clear
                                        : NotchDesign.Palette.hairline,
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(activePreset == theme ? .isSelected : [])
                }
            }

            SettingsRowDivider()

            ForEach(PostureColorRole.allCases) { role in
                HStack(spacing: 12) {
                    Circle()
                        .fill(colorBinding(for: role).wrappedValue)
                        .frame(width: 9, height: 9)
                    Text(LocalizedStringKey(role.title))
                        .font(NotchDesign.Typography.cardTitle)
                        .foregroundStyle(NotchDesign.Palette.text)
                    Spacer(minLength: 12)
                    ColorPicker(LocalizedStringKey(role.title), selection: colorBinding(for: role), supportsOpacity: false)
                        .labelsHidden()
                }
            }

            SettingsRowDivider()

            // Live preview of every reminder kind, painted with the colours above.
            PostureAlertPreview(
                alertOrder: PostureAlert.Kind.allCases,
                colors: model.postureColors
            )
        }
    }
}

// Shared climate readout for the expanded panel and posture settings.
struct PostureEnvironmentView: View {
    @ObservedObject var model: AppModel


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                metric("Temperature", symbol: "thermometer.medium",
                       value: model.posture.temperatureC.map { String(format: "%.1f °C", $0) })
                Spacer(minLength: 0)
                metric("Humidity", symbol: "humidity",
                       value: model.posture.humidityPercent.map { String(format: "%.1f %%", $0) })
            }
            Text(model.environmentDetailText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, symbol: String, value: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.localized(title))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value ?? "—")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// Shared by the live panel and detection settings so progress survives switching views.
struct PostureCalibrationControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button {
                    model.postureService.startCalibration()
                } label: {
                    Label(model.localized("Sit upright and calibrate"), systemImage: "figure.seated.side.air.upper")
                }
                .controlSize(.small)
                .disabled(model.postureRuntime != .running || !model.posturePoseFallbackEnabled ||
                          model.postureCalibration.isActive)
                Spacer(minLength: 0)
                if model.postureCalibration.isActive {
                    Button(model.localized("Cancel")) { model.postureService.cancelCalibration() }
                        .controlSize(.small)
                }
            }
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if let progress = model.postureCalibration.progress {
                ProgressView(value: Double(progress), total: 100)
                    .controlSize(.mini)
                    .accessibilityLabel(model.localized("Calibration progress"))
            }
        }
    }

    private var statusText: String {
        switch model.postureCalibration {
        case .preparing(let remaining):
            return String(format: model.localized("Sit upright and relax your shoulders. Starting in %d s"), remaining)
        case .collecting(let progress):
            return String(format: model.localized("Capturing. Stay upright · %d%%"), progress)
        case .waiting(let issue, let progress):
            return model.localized(issue.message) + String(format: " · %d%%", progress)
        case .complete:
            return model.localized("Personal baseline saved. Recalibrate after moving the camera.")
        case .failed:
            return model.localized("Calibration incomplete. Adjust your framing and retry. Existing baselines are kept.")
        case .failedWithReason(let issue):
            return model.localized("Calibration incomplete: ") + model.localized(issue.message)
        case .idle:
            if model.postureRuntime != .running || !model.posturePoseFallbackEnabled {
                return model.localized("Enable background detection and pose fallback before calibrating.")
            }
            return model.localized("Sit upright, then calibrate: a 3 s countdown followed by a 6 s capture.")
        }
    }
}


struct PosturePreviewSizeControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.and.down")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { model.posturePreviewHeight },
                                  set: { model.setPosturePreviewHeight($0) }),
                   in: PosturePreviewSizing.range) {
                Text(model.localized("Camera preview height"))
            }
            .labelsHidden()
            .accessibilityValue("\(Int(model.posturePreviewHeight)) pt")
            Text("\(Int(model.posturePreviewHeight)) pt")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Toggle(model.localized("Full frame"), isOn: Binding(
                get: { model.postureCalibration.isActive || model.posturePreviewFullFrame },
                set: { model.posturePreviewFullFrame = $0 }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .disabled(model.postureCalibration.isActive)
            Button { model.resetPosturePreviewSize() } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help(model.localized("Reset preview size"))
            .accessibilityLabel(model.localized("Reset preview size"))
        }
        .controlSize(.mini)
        .font(.caption2)
    }
}
