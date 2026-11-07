import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chart

struct ClassroomSeries: Identifiable {
    var id: String { name }
    let name: String
    let color: Color
    let points: [ClassroomPoint]
}

/// Hairline line chart: enough for loss and mAP curves, cheap to redraw while
/// training streams in.
struct ClassroomLineChart: View {
    var series: [ClassroomSeries]
    var height: CGFloat = 130
    var valueFormat: (Double) -> String = { String(format: "%.2f", $0) }

    private var bounds: (min: Double, max: Double) {
        let values = series.flatMap { $0.points.map(\.value) }
        guard let low = values.min(), let high = values.max() else { return (0, 1) }
        let span = max(high - low, 0.0001)
        return (low - span * 0.12, high + span * 0.12)
    }

    private var maxEpoch: Int {
        max(series.flatMap { $0.points.map(\.epoch) }.max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Canvas { context, size in
                let inset = EdgeInsets(top: 8, leading: 34, bottom: 16, trailing: 6)
                let plot = CGRect(
                    x: inset.leading,
                    y: inset.top,
                    width: max(size.width - inset.leading - inset.trailing, 1),
                    height: max(size.height - inset.top - inset.bottom, 1)
                )
                let low = bounds.min
                let span = max(bounds.max - low, 0.0001)

                func point(_ epoch: Int, _ value: Double) -> CGPoint {
                    let x = plot.minX + plot.width * CGFloat(epoch - 1) / CGFloat(max(maxEpoch - 1, 1))
                    let y = plot.maxY - plot.height * CGFloat((value - low) / span)
                    return CGPoint(x: x, y: y)
                }

                for index in 0...3 {
                    let fraction = CGFloat(index) / 3
                    let y = plot.maxY - plot.height * fraction
                    var line = Path()
                    line.move(to: CGPoint(x: plot.minX, y: y))
                    line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(NotchDesign.Palette.hairline), lineWidth: 1)
                    context.draw(
                        Text(valueFormat(low + span * Double(fraction)))
                            .font(.system(size: 8, design: .rounded))
                            .foregroundColor(NotchDesign.Palette.eyebrow),
                        at: CGPoint(x: plot.minX - 5, y: y),
                        anchor: .trailing
                    )
                }

                context.draw(
                    Text("1").font(.system(size: 8, design: .rounded))
                        .foregroundColor(NotchDesign.Palette.eyebrow),
                    at: CGPoint(x: plot.minX, y: plot.maxY + 8),
                    anchor: .center
                )
                context.draw(
                    Text("\(maxEpoch)").font(.system(size: 8, design: .rounded))
                        .foregroundColor(NotchDesign.Palette.eyebrow),
                    at: CGPoint(x: plot.maxX, y: plot.maxY + 8),
                    anchor: .center
                )

                for item in series where !item.points.isEmpty {
                    var path = Path()
                    for (index, pointValue) in item.points.enumerated() {
                        let position = point(pointValue.epoch, pointValue.value)
                        if index == 0 {
                            path.move(to: position)
                        } else {
                            path.addLine(to: position)
                        }
                    }
                    context.stroke(
                        path,
                        with: .color(item.color),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
                    if let last = item.points.last {
                        let position = point(last.epoch, last.value)
                        context.fill(
                            Path(ellipseIn: CGRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4)),
                            with: .color(item.color)
                        )
                    }
                }
            }
            .frame(height: height)

            if series.count > 1 {
                HStack(spacing: 10) {
                    ForEach(series) { item in
                        HStack(spacing: 4) {
                            Circle().fill(item.color).frame(width: 5, height: 5)
                            Text(item.name)
                                .font(.system(size: 9))
                                .foregroundStyle(NotchDesign.Palette.secondaryText)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Step 3

struct ClassroomTrainStep: View {
    @ObservedObject var store: ClassroomStore
    @State private var showAdvanced = false

    var body: some View {
        ClassroomColumns(leadingWidth: 320) {
            settingsCard
            monitorCard.layoutValue(key: ClassroomColumn.self, value: 1)
            curvesCard.layoutValue(key: ClassroomColumn.self, value: 1)
            logCard
        }
    }

    private var settingsCard: some View {
        ClassroomCard {
            ClassroomCardTitle(
                text: "Training settings",
                detail: "Recommended settings — just press start",
                trailing: AnyView(
                    ClassroomStatusChip(
                        text: store.progress.isRunning ? "Training…" : "Ready",
                        tint: store.progress.isRunning ? ClassroomStyle.accent : NotchDesign.Palette.eyebrow
                    )
                )
            )

            VStack(spacing: 6) {
                presetRow(label: "Model", value: "YOLO26n", symbol: "cpu")
                presetRow(label: "Epochs", value: "\(store.config.epochs)", symbol: "repeat")
                presetRow(label: "Image size", value: "\(store.config.imgsz) px", symbol: "square.resize")
                presetRow(label: "Batch", value: "\(store.config.batch)", symbol: "square.stack.3d.down.right")
                presetRow(
                    label: "Device",
                    value: store.capabilities.checked ? store.capabilities.device : store.config.device,
                    symbol: "bolt.fill"
                )
            }

            Text(LocalizedStringKey("fine-tuned from the posture model"))
                .font(.system(size: 10))
                .foregroundStyle(NotchDesign.Palette.eyebrow)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(LocalizedStringKey("Advanced settings")).font(.system(size: 10.5, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(NotchDesign.Palette.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        stepperField(title: "Epochs", value: Binding(
                            get: { store.config.epochs },
                            set: { store.config.epochs = max(1, min(300, $0)); store.saveProject() }
                        ), range: 1...300)
                        stepperField(title: "Batch", value: Binding(
                            get: { store.config.batch },
                            set: { store.config.batch = max(1, min(64, $0)); store.saveProject() }
                        ), range: 1...64)
                    }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LocalizedStringKey("Image size"))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(NotchDesign.Palette.eyebrow)
                            Picker("", selection: Binding(
                                get: { store.config.imgsz },
                                set: { store.config.imgsz = $0; store.saveProject() }
                            )) {
                                Text("320").tag(320)
                                Text("480").tag(480)
                                Text("640").tag(640)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                        }
                        stepperField(title: "Early stop patience", value: Binding(
                            get: { store.config.patience },
                            set: { store.config.patience = max(3, min(100, $0)); store.saveProject() }
                        ), range: 3...100)
                    }
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey("Python executable"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(NotchDesign.Palette.secondaryText)
                        Spacer(minLength: 6)
                        Text(store.pythonDisplayPath)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(NotchDesign.Palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ClassroomSecondaryButton(title: "Choose…") { choosePython() }
                    }
                }
                .transition(.opacity)
            }

            if store.progress.isRunning {
                ClassroomPrimaryButton(title: "Stop training", symbol: "stop.fill", tint: ClassroomStyle.bad) {
                    store.stopTraining()
                }
            } else {
                ClassroomPrimaryButton(
                    title: "Train model",
                    symbol: "bolt.fill",
                    enabled: store.datasetReady
                ) {
                    store.startTraining()
                }
            }

            if !store.datasetReady {
                Text(LocalizedStringKey("Build the dataset in step 1 first."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(ClassroomStyle.warning)
            }
        }
    }

    private func choosePython() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = store.t("Choose the Python executable")
        if panel.runModal() == .OK, let url = panel.url {
            store.choosePython(url)
        }
    }

    private func presetRow(label: String, value: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(NotchDesign.Palette.eyebrow)
                .frame(width: 14)
            Text(LocalizedStringKey(label))
                .font(.system(size: 11))
                .foregroundStyle(NotchDesign.Palette.secondaryText)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchDesign.Palette.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(NotchDesign.Palette.track, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func stepperField(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(NotchDesign.Palette.eyebrow)
            HStack(spacing: 3) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(NotchDesign.Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .monospacedDigit()
                Stepper("", value: value, in: range)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(NotchDesign.Palette.track, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var monitorCard: some View {
        ClassroomCard {
            ClassroomCardTitle(
                text: "Training progress",
                detail: store.progress.isRunning
                    ? String(format: store.t("Epoch %d / %d"), store.progress.epoch, max(store.progress.epochs, 1))
                    : store.t("Waiting to start"),
                trailing: AnyView(
                    ClassroomStatusChip(
                        text: store.progress.isRunning ? "Training…" : "Ready",
                        tint: store.progress.isRunning ? ClassroomStyle.accent : NotchDesign.Palette.eyebrow
                    )
                )
            )

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchDesign.Palette.track)
                    Capsule()
                        .fill(ClassroomStyle.accent)
                        .frame(width: max(5, proxy.size.width * fraction))
                }
            }
            .frame(height: 7)

            HStack(spacing: 8) {
                ClassroomStatTile(
                    title: "Epochs",
                    value: "\(store.progress.epoch)/\(max(store.progress.epochs, store.config.epochs))"
                )
                ClassroomStatTile(
                    title: "mAP50",
                    value: metricText(store.progress.metrics["metrics/mAP50(B)"]),
                    tint: ClassroomStyle.accent
                )
                ClassroomStatTile(
                    title: "Loss",
                    value: String(format: "%.2f", store.progress.losses.values.reduce(0, +)),
                    tint: ClassroomStyle.warning
                )
                ClassroomStatTile(title: "Time left", value: timeText(store.progress.eta))
            }
        }
    }

    private var fraction: Double {
        guard store.progress.epochs > 0 else { return 0 }
        return min(1, Double(store.progress.epoch) / Double(store.progress.epochs))
    }

    private var curvesCard: some View {
        ClassroomCard {
            ClassroomCardTitle(text: "Live curves", detail: "Curves appear once training starts")
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Average loss (lower is better)"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                    ClassroomLineChart(
                        series: [ClassroomSeries(name: store.t("Loss"), color: ClassroomStyle.warning, points: store.lossHistory)]
                    )
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("mAP50 (higher is better)"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                    ClassroomLineChart(
                        series: [ClassroomSeries(name: "mAP50", color: ClassroomStyle.accent, points: store.metricHistory)]
                    )
                }
            }
        }
    }

    private var logCard: some View {
        ClassroomCard {
            ClassroomCardTitle(text: "Training log")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(store.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(ClassroomStyle.mono)
                                .foregroundStyle(NotchDesign.Palette.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 140)
                .background(NotchDesign.Palette.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: store.logLines.count) { _, count in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(max(count - 1, 0), anchor: .bottom)
                    }
                }
            }
        }
    }

    private func metricText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f", value)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)" + store.t("s") }
        return "\(total / 60)" + store.t("m ") + "\(total % 60)" + store.t("s")
    }
}

// MARK: - Step 4

struct ClassroomRecordsStep: View {
    @ObservedObject var store: ClassroomStore

    private var selected: [ClassroomRun] {
        store.runs.filter { store.selectedRuns.contains($0.name) }
    }

    var body: some View {
        VStack(spacing: 14) {
            tableCard
            detailCard
        }
    }

    private var tableCard: some View {
        ClassroomCard {
            ClassroomCardTitle(
                text: "Runs",
                detail: "Pick a run on the left to see details; compare up to 3 at once.",
                trailing: AnyView(ClassroomStatusChip(text: "\(store.runs.count)", tint: NotchDesign.Palette.eyebrow))
            )

            if store.runs.isEmpty {
                ClassroomEmptyState(
                    title: "No experiments yet",
                    message: "Finish a training run and its results will show up here.",
                    symbol: "chart.xyaxis.line"
                )
                .frame(height: 120)
            } else {
                VStack(spacing: 1) {
                    headerRow
                    ForEach(store.runs) { run in row(run) }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey("Runs")).frame(minWidth: 56, maxWidth: 96, alignment: .leading)
            Text("best mAP50").frame(minWidth: 64, maxWidth: 96, alignment: .leading)
            Text("mAP50-95").frame(minWidth: 60, maxWidth: 96, alignment: .leading)
            Text(LocalizedStringKey("Epochs")).frame(minWidth: 34, maxWidth: 56, alignment: .leading)
            Text(LocalizedStringKey("Device")).frame(minWidth: 40, maxWidth: 68, alignment: .leading)
            Text(LocalizedStringKey("When")).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(NotchDesign.Palette.eyebrow)
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
    }

    private func row(_ run: ClassroomRun) -> some View {
        let isSelected = store.selectedRuns.contains(run.name)
        return Button {
            store.toggleRunSelection(run)
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? ClassroomStyle.accent : NotchDesign.Palette.eyebrow)
                    Text(run.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchDesign.Palette.text)
                }
                .frame(minWidth: 56, maxWidth: 96, alignment: .leading)

                Text(String(format: "%.3f", run.map50))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchDesign.Palette.text)
                    .monospacedDigit()
                    .frame(minWidth: 64, maxWidth: 96, alignment: .leading)

                Text(String(format: "%.3f", run.map50to95))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .monospacedDigit()
                    .frame(minWidth: 60, maxWidth: 96, alignment: .leading)

                Text("\(run.epochs)")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .frame(minWidth: 34, maxWidth: 56, alignment: .leading)

                Text(run.device)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .frame(minWidth: 40, maxWidth: 68, alignment: .leading)

                Text(run.finishedAt)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                isSelected ? ClassroomStyle.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detailCard: some View {
        ClassroomCard {
            ClassroomCardTitle(
                text: "Curve comparison",
                detail: selected.isEmpty
                    ? store.t("Pick a run above.")
                    : selected.map(\.name).joined(separator: " · "),
                trailing: AnyView(
                    HStack(spacing: 5) {
                        if let first = selected.first {
                            ClassroomSecondaryButton(title: "Train again with these settings", symbol: "arrow.clockwise") {
                                store.reuseConfig(first)
                            }
                        }
                    }
                )
            )

            if selected.isEmpty {
                ClassroomEmptyState(
                    title: "Pick a run",
                    message: "Choose a run to see its per-epoch loss curve.",
                    symbol: "chart.line.uptrend.xyaxis"
                )
                .frame(height: 160)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        comparisonChart
                        comparisonLegend
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        comparisonChart
                        comparisonLegend
                    }
                }
            }
        }
    }

    private var comparisonChart: some View {
        ClassroomLineChart(
            series: selected.prefix(3).enumerated().map { index, run in
                ClassroomSeries(
                    name: run.name,
                    color: [ClassroomStyle.accent, ClassroomStyle.good, ClassroomStyle.warning][index],
                    points: store.runCurve(run)
                )
            },
            height: 140
        )
    }

    private var comparisonLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(selected.enumerated()), id: \.element.id) { index, run in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill([ClassroomStyle.accent, ClassroomStyle.good, ClassroomStyle.warning][index % 3])
                                    .frame(width: 6, height: 6)
                                Text(run.name).font(.system(size: 10.5, weight: .semibold))
                                Text(String(format: "mAP50 %.3f", run.map50))
                                    .font(.system(size: 10.5, design: .rounded))
                                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                                    .monospacedDigit()
                                Spacer(minLength: 0)
                                Text(run.durationText(store.language))
                                    .font(.system(size: 10))
                                    .foregroundStyle(NotchDesign.Palette.eyebrow)
                            }
                        }
        }
        .frame(minWidth: 160, maxWidth: 220)
    }
}

// MARK: - Step 5

struct ClassroomTestStep: View {
    @ObservedObject var store: ClassroomStore

    var body: some View {
        ClassroomColumns(leadingWidth: 300) {
            settingsCard
            previewCard.layoutValue(key: ClassroomColumn.self, value: 1)
        }
    }

    private var settingsCard: some View {
        ClassroomCard {
            ClassroomCardTitle(text: "Test settings", detail: "Quiz the model with unseen photos")

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey("Weights"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(NotchDesign.Palette.eyebrow)
                Picker("", selection: Binding(
                    get: { store.testWeight },
                    set: { store.testWeight = $0 }
                )) {
                    ForEach(store.runs) { run in
                        Text("\(run.name) · mAP50 \(String(format: "%.3f", run.map50))").tag(run.best)
                    }
                    if let bundled = ClassroomStore.startingWeights() {
                        Text(LocalizedStringKey("Built-in posture model")).tag(bundled.path)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(LocalizedStringKey("Confidence threshold"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(NotchDesign.Palette.eyebrow)
                    Spacer()
                    Text(String(format: "%.2f", store.testConfidence))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchDesign.Palette.text)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { store.testConfidence },
                    set: { store.testConfidence = $0 }
                ), in: 0.05...0.9)
                .controlSize(.small)
                Text(LocalizedStringKey("A lower threshold makes the model guess more; a higher one keeps only confident answers."))
                    .font(.system(size: 10))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ClassroomSecondaryButton(title: "Choose a test photo", symbol: "photo") { chooseImage() }

            ClassroomPrimaryButton(
                title: "Run test",
                symbol: "viewfinder",
                enabled: !store.testImagePath.isEmpty && !store.testBusy
            ) {
                store.runTest()
            }

            if !store.testNote.isEmpty {
                Text(store.testNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
            }
        }
    }

    private var previewCard: some View {
        ClassroomCard {
            ClassroomCardTitle(
                text: "Test preview",
                detail: "Results show up here",
                trailing: AnyView(
                    ClassroomStatusChip(
                        text: store.testBusy ? "Running…" : (store.testNote.isEmpty ? "Not tested" : store.testNote),
                        tint: store.testBusy ? ClassroomStyle.accent : NotchDesign.Palette.eyebrow
                    )
                )
            )

            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(NotchDesign.Palette.track)

                if !store.testImagePath.isEmpty {
                    ClassroomPhoto(url: URL(fileURLWithPath: store.testImagePath), maximumPixelSize: 1600) { nsImage in
                        GeometryReader { geo in
                            let frame = fitted(nsImage.size, in: geo.size)
                            ZStack(alignment: .topLeading) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                                ForEach(store.detections) { detection in
                                    let rect = CGRect(
                                        x: frame.minX + detection.rect.minX * frame.width,
                                        y: frame.minY + detection.rect.minY * frame.height,
                                        width: detection.rect.width * frame.width,
                                        height: detection.rect.height * frame.height
                                    )
                                    let color = color(for: detection.label)
                                    Rectangle()
                                        .strokeBorder(color, lineWidth: 2)
                                        .frame(width: rect.width, height: rect.height)
                                        .offset(x: rect.minX, y: rect.minY)
                                        .overlay(alignment: .topLeading) {
                                            Text(verbatim: "\(store.displayName(detection.label)) \(Int(detection.conf * 100))%")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(color, in: RoundedRectangle(cornerRadius: 3))
                                                .offset(x: rect.minX, y: max(rect.minY - 14, 0))
                                        }
                                }
                            }
                        }
                    }
                } else {
                    ClassroomEmptyState(
                        title: "No test photo yet",
                        message: "Use Choose a test photo on the left.",
                        symbol: "viewfinder"
                    )
                }
            }
            .frame(height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func color(for label: String) -> Color {
        if let index = store.classes.firstIndex(where: { $0.name == label }) {
            return store.classes[index].color
        }
        return label.lowercased().contains("bad") ? ClassroomStyle.bad : ClassroomStyle.good
    }

    private func fitted(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / size.width, container.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2, width: width, height: height)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            store.chooseTestImage(url)
        }
    }
}

// MARK: - Step 6

struct ClassroomExportStep: View {
    @ObservedObject var store: ClassroomStore
    @ObservedObject var training: PostureTrainingController

    private struct Option: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let available: Bool
        let note: String?
    }

    private var options: [Option] {
        [
            Option(id: "coreml", title: "CoreML (for apps)", detail: "Applied straight to this app",
                   symbol: "apple.logo", available: store.capabilities.coreml, note: nil),
            Option(id: "onnx", title: "ONNX (cross-platform)", detail: "Runs on Windows, Linux and the web",
                   symbol: "square.on.square", available: store.capabilities.onnx,
                   note: store.t("Install the onnx package to export this format.")),
            Option(id: "torchscript", title: "TorchScript (PyTorch native)", detail: "Load it straight from Python",
                   symbol: "flame", available: true, note: nil),
            Option(id: "rknn", title: "RKNN (Rockchip boards)", detail: "For boards like rk3588",
                   symbol: "cpu", available: store.capabilities.rknn,
                   note: store.t("Install rknn-toolkit2 to export this format."))
        ]
    }

    var body: some View {
        ClassroomColumns {
            configCard
            resultCard.layoutValue(key: ClassroomColumn.self, value: 1)
            activeModelCard
        }
    }

    /// Which model the detector is using right now, and the way back to the
    /// bundled one — the old training page used to own this switch.
    private var activeModelCard: some View {
        ClassroomCard {
            ClassroomCardTitle(text: "Current detection model")
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
                Text(LocalizedStringKey(
                    training.activeModelPath == nil ? "Bundled SittingPosture model" : "Custom trained model"
                ))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(NotchDesign.Palette.text)
                Spacer(minLength: 6)
                if training.activeModelPath != nil {
                    ClassroomSecondaryButton(title: "Restore bundled model", symbol: "arrow.uturn.backward") {
                        training.restoreBundledModel()
                        if store.appModel.postureMonitoringEnabled {
                            store.appModel.launchPostureMonitor()
                        }
                    }
                    .disabled(training.phase.isBusy)
                }
            }
        }
    }

    private var configCard: some View {
        ClassroomCard {
            ClassroomCardTitle(text: "Export settings", detail: "Turn the .pt into a file other platforms understand")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(options) { option in
                    Button {
                        store.exportFormat = option.id
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Image(systemName: option.symbol).font(.system(size: 10, weight: .medium))
                                Spacer(minLength: 0)
                                if store.exportFormat == option.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(ClassroomStyle.accent)
                                }
                            }
                            Text(LocalizedStringKey(option.title))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(NotchDesign.Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(LocalizedStringKey(option.detail))
                                .font(.system(size: 9))
                                .foregroundStyle(NotchDesign.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                        .background(
                            store.exportFormat == option.id ? ClassroomStyle.accentSoft : NotchDesign.Palette.track,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    store.exportFormat == option.id ? ClassroomStyle.accent : Color.clear,
                                    lineWidth: 1
                                )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(option.available ? 1 : 0.55)
                    .help(option.note ?? "")
                }
            }

            Toggle(isOn: Binding(
                get: { store.exportHalf },
                set: { store.exportHalf = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey("Half precision (FP16)"))
                        .font(.system(size: 11, weight: .medium))
                    Text(LocalizedStringKey("Half the size with almost the same accuracy — good for apps."))
                        .font(.system(size: 9.5))
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            ClassroomPrimaryButton(
                title: store.exportBusy ? "Exporting…" : "Export the model",
                symbol: "shippingbox",
                enabled: !store.exportBusy
            ) {
                store.runExport()
            }
        }
    }

    private var resultCard: some View {
        ClassroomCard {
            ClassroomCardTitle(
                text: "Export result",
                trailing: AnyView(
                    ClassroomStatusChip(
                        text: store.exportPath.isEmpty ? "Not exported" : "Done",
                        tint: store.exportPath.isEmpty ? NotchDesign.Palette.eyebrow : ClassroomStyle.good
                    )
                )
            )

            if store.exportPath.isEmpty {
                ClassroomEmptyState(
                    title: "Nothing exported yet",
                    message: "Pick a format, then press Export model.",
                    symbol: "shippingbox"
                )
                .frame(height: 130)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(store.exportPath)
                        .font(ClassroomStyle.mono)
                        .foregroundStyle(NotchDesign.Palette.text)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        ClassroomSecondaryButton(title: "Show in Finder", symbol: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.exportPath)])
                        }
                        if store.exportFormat == "coreml" {
                            ClassroomSecondaryButton(title: "Apply to app", symbol: "checkmark.shield") {
                                store.installExportedModel()
                            }
                        }
                        if !store.installState.isEmpty {
                            if training.phase == .failed, let error = training.error {
                                Text(store.t(error))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(ClassroomStyle.warning)
                            } else {
                                Text(store.installState)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(ClassroomStyle.good)
                            }
                        }
                    }
                }
            }

            ClassroomDivider()

            Text(LocalizedStringKey("Export log"))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(NotchDesign.Palette.eyebrow)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(store.exportLog.suffix(200).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(ClassroomStyle.mono)
                            .foregroundStyle(NotchDesign.Palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(height: 110)
            .background(NotchDesign.Palette.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
