import AppKit
import Combine
import CoreML
import Foundation
import SwiftUI

// MARK: - Steps

enum ClassroomStep: Int, CaseIterable, Identifiable {
    case dataset, annotate, train, records, test, export

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .dataset: return "Build a dataset"
        case .annotate: return "Annotate photos"
        case .train: return "Train the model"
        case .records: return "Experiment records"
        case .test: return "Test the model"
        case .export: return "Export the model"
        }
    }

    /// One sentence a 12-year-old can follow.
    var blurb: String {
        switch self {
        case .dataset: return "Collect photos first: every class needs examples so the model can tell them apart."
        case .annotate: return "Draw a box around the person in each photo and say whether it is good or bad posture."
        case .train: return "Let the model practise on the photos and watch it improve."
        case .records: return "Compare each practice run and keep the best settings."
        case .test: return "Quiz the model with photos it has never seen."
        case .export: return "Package the trained model and apply it to this app."
        }
    }
}

// MARK: - Values

struct ClassroomClass: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var hex: String

    var color: Color { Color(hex: hex) ?? ClassroomStyle.accent }
}

struct ClassroomBox: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var classIndex: Int
    /// Normalised, top-left origin.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct ClassroomImage: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var fileName: String
    var className: Int
    var boxes: [ClassroomBox] = []

    var isLabeled: Bool { !boxes.isEmpty }
}

struct ClassroomConfig: Codable, Equatable {
    var epochs: Int = 40
    var imgsz: Int = 640
    var batch: Int = 8
    var patience: Int = 15
    var device: String = "auto"
}

struct ClassroomProgress: Equatable {
    var epoch: Int = 0
    var epochs: Int = 0
    var losses: [String: Double] = [:]
    var metrics: [String: Double] = [:]
    var eta: Double = 0
    var elapsed: Double = 0
    var isRunning = false
}

struct ClassroomPoint: Identifiable, Hashable {
    var id: Int { epoch }
    let epoch: Int
    let value: Double
}

struct ClassroomRun: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let epochs: Int
    let imgsz: Int
    let batch: String
    let device: String
    let seconds: Double
    let best: String
    let metrics: [String: Double]
    let finishedAt: String

    var map50: Double { metrics["metrics/mAP50(B)"] ?? 0 }
    var map50to95: Double { metrics["metrics/mAP50-95(B)"] ?? 0 }
    var precision: Double { metrics["metrics/precision(B)"] ?? 0 }
    var recall: Double { metrics["metrics/recall(B)"] ?? 0 }

    func durationText(_ language: AppLanguage) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) " + language.localized("s") }
        return "\(total / 60) " + language.localized("m ") + "\(total % 60) " + language.localized("s")
    }
}

struct ClassroomDetection: Identifiable, Hashable {
    var id = UUID()
    let label: String
    let conf: Double
    let rect: CGRect
}

struct ClassroomCapabilities: Equatable {
    var checked = false
    var ultralytics: String = ""
    var device: String = "auto"
    var mps = false
    var coreml = false
    var onnx = false
    var rknn = false
}

// MARK: - Store

/// Drives the six classroom steps from inside the posture app: photos, boxes,
/// dataset folders, a Python fine-tune job, run records and the export that can
/// be installed as the app's detection model.
@MainActor
final class ClassroomStore: ObservableObject {
    @Published var step: ClassroomStep = .dataset

    // Step 1
    @Published var classes: [ClassroomClass] = [
        ClassroomClass(name: "Good posture", hex: "#30D159"),
        ClassroomClass(name: "Bad posture", hex: "#FF453B")
    ]
    @Published var images: [ClassroomImage] = []
    @Published var splitRatio: Double = 0.2
    @Published var datasetReady = false
    @Published var datasetNote = ""

    // Step 2
    @Published var annotateIndex = 0
    @Published var annotateClass = 0

    // Step 3
    @Published var config = ClassroomConfig()
    @Published var progress = ClassroomProgress()
    @Published var logLines: [String] = []
    @Published var lossHistory: [ClassroomPoint] = []
    @Published var metricHistory: [ClassroomPoint] = []
    @Published var runName = "exp-1"

    // Step 4
    @Published var runs: [ClassroomRun] = []
    @Published var selectedRuns: Set<String> = []

    // Step 5
    @Published var testWeight = ""
    @Published var testConfidence: Double = 0.25
    @Published var testImagePath = ""
    @Published var detections: [ClassroomDetection] = []
    @Published var testBusy = false
    @Published var testNote = ""

    // Step 6
    @Published var exportFormat = "coreml"
    @Published var exportHalf = true
    @Published var exportLog: [String] = []
    @Published var exportPath = ""
    @Published var exportBusy = false
    @Published var installState = ""

    @Published var capabilities = ClassroomCapabilities()
    @Published var banner: String?

    let appModel: AppModel
    let root: URL
    private var task: Process?
    private var exportTask: Process?
    private var capabilityProbe: Process?

    init(appModel: AppModel, root: URL? = nil) {
        self.appModel = appModel
        let base = root ?? Self.defaultRoot()
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        loadProject()
        refreshRuns()
    }

    /// CLASSROOM_ROOT lets the preview tools render against a scratch folder
    /// instead of the teacher's real library.
    nonisolated static func defaultRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["CLASSROOM_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("INT4154 Posture Detecion/Classroom", isDirectory: true)
    }

    // MARK: Paths

    var language: AppLanguage { appModel.appLanguage }
    func t(_ source: String) -> String { appModel.localized(source) }
    /// Class names and model labels for display. The bundled model says Bad/Good, and
    /// projects saved before the English-key change keep their Chinese default names.
    /// Names the user typed have no entry and show as typed.
    func displayName(_ label: String) -> String {
        let defaults = ["Bad": "Bad posture", "Good": "Good posture",
                        "不良坐姿": "Bad posture", "良好坐姿": "Good posture"]
        return t(defaults[label] ?? label)
    }

    var libraryURL: URL { root.appendingPathComponent("library", isDirectory: true) }
    var datasetURL: URL { root.appendingPathComponent("dataset", isDirectory: true) }
    var runsURL: URL { root.appendingPathComponent("runs", isDirectory: true) }
    var projectURL: URL { root.appendingPathComponent("project.json") }
    var dataYAMLURL: URL { datasetURL.appendingPathComponent("data.yaml") }

    var labeledCount: Int { images.filter(\.isLabeled).count }
    var allLabeled: Bool { !images.isEmpty && labeledCount == images.count }

    var annotatedImage: ClassroomImage? {
        images.indices.contains(annotateIndex) ? images[annotateIndex] : images.first
    }

    var currentImageURL: URL? {
        annotatedImage.map { libraryURL.appendingPathComponent($0.fileName) }
    }

    var stepOneReady: Bool {
        guard classes.count >= 2, !images.isEmpty else { return false }
        return classes.indices.allSatisfy { index in
            images.contains { $0.className == index }
        }
    }

    func photos(_ count: Int) -> String {
        if language == .traditionalChinese { return "\(count) 張" }
        return count == 1 ? "1 photo" : "\(count) photos"
    }

    func boxCount(_ count: Int) -> String {
        if language == .traditionalChinese { return "\(count) 個框" }
        return count == 1 ? "1 box" : "\(count) boxes"
    }

    func trainingSplit(train: Int, validate: Int) -> String {
        if language == .traditionalChinese { return "訓練 \(train) 張、驗證 \(validate) 張" }
        let training = train == 1 ? "1 training photo" : "\(train) training photos"
        let validation = validate == 1 ? "1 validation photo" : "\(validate) validation photos"
        return training + ", " + validation
    }

    // MARK: Persistence

    private struct ProjectFile: Codable {
        var classes: [ClassroomClass]
        var images: [ClassroomImage]
        var splitRatio: Double
        var config: ClassroomConfig
        var runName: String
        var datasetReady: Bool
    }

    private func loadProject() {
        guard let data = try? Data(contentsOf: projectURL),
              let project = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return }
        classes = project.classes
        images = project.images
        splitRatio = project.splitRatio
        config = project.config
        runName = project.runName
        datasetReady = project.datasetReady
    }

    func saveProject() {
        let project = ProjectFile(
            classes: classes,
            images: images,
            splitRatio: splitRatio,
            config: config,
            runName: runName,
            datasetReady: datasetReady
        )
        if let data = try? JSONEncoder().encode(project) {
            try? data.write(to: projectURL, options: .atomic)
        }
    }

    // MARK: Step 1 — dataset

    func addClass() {
        guard classes.count < 5 else { return }
        let palette = ["#4FA8FF", "#9E8CFF", "#FFC200"]
        classes.append(
            ClassroomClass(
                name: t("New class"),
                hex: palette[(classes.count - 2) % palette.count]
            )
        )
        saveProject()
    }

    func removeClass(at index: Int) {
        guard classes.count > 2, classes.indices.contains(index) else { return }
        classes.remove(at: index)
        for imageIndex in images.indices {
            images[imageIndex].boxes.removeAll { $0.classIndex == index }
            images[imageIndex].boxes = images[imageIndex].boxes.map { box in
                var updated = box
                if box.classIndex > index { updated.classIndex -= 1 }
                return updated
            }
            if images[imageIndex].className >= classes.count {
                images[imageIndex].className = max(0, classes.count - 1)
            }
        }
        saveProject()
    }

    func renameClass(at index: Int, to name: String) {
        guard classes.indices.contains(index), !name.isEmpty else { return }
        classes[index].name = name
        saveProject()
    }

    func importImages(urls: [URL], className: Int) {
        for url in urls {
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
            let name = UUID().uuidString + "." + ext
            let target = libraryURL.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: url, to: target)) != nil {
                images.append(ClassroomImage(fileName: name, className: min(className, classes.count - 1)))
            }
        }
        datasetReady = false
        saveProject()
    }

    func removeImage(_ image: ClassroomImage) {
        try? FileManager.default.removeItem(at: libraryURL.appendingPathComponent(image.fileName))
        images.removeAll { $0.id == image.id }
        if annotateIndex >= images.count { annotateIndex = max(0, images.count - 1) }
        datasetReady = false
        saveProject()
    }

    /// Writes dataset/images + labels + data.yaml that Ultralytics can read.
    func buildDataset() {
        let fm = FileManager.default
        try? fm.removeItem(at: datasetURL)
        var train: [ClassroomImage] = []
        var val: [ClassroomImage] = []
        let stride = max(2, Int((1.0 / max(splitRatio, 0.05)).rounded()))
        for (index, image) in images.enumerated() {
            if index % stride == stride - 1, images.count > 2 {
                val.append(image)
            } else {
                train.append(image)
            }
        }
        if val.isEmpty, let last = train.popLast() { val.append(last) }

        func write(_ set: [ClassroomImage], split: String) {
            let imagesDir = datasetURL.appendingPathComponent("images/\(split)", isDirectory: true)
            let labelsDir = datasetURL.appendingPathComponent("labels/\(split)", isDirectory: true)
            try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: labelsDir, withIntermediateDirectories: true)
            for image in set {
                let source = libraryURL.appendingPathComponent(image.fileName)
                let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
                let stem = image.id.uuidString
                try? fm.copyItem(at: source, to: imagesDir.appendingPathComponent("\(stem).\(ext)"))
                let label = image.boxes.map { box in
                    String(
                        format: "%d %.6f %.6f %.6f %.6f",
                        box.classIndex,
                        box.x + box.width / 2,
                        box.y + box.height / 2,
                        box.width,
                        box.height
                    )
                }.joined(separator: "\n")
                try? label.write(to: labelsDir.appendingPathComponent("\(stem).txt"), atomically: true, encoding: .utf8)
            }
        }

        write(train, split: "train")
        write(val, split: "val")

        var yaml = """
        # Generated by the INT4154 classroom
        path: \(datasetURL.path)
        train: images/train
        val: images/val
        names:
        """
        for (index, item) in classes.enumerated() {
            yaml += "\n  \(index): \(item.name)"
        }
        try? yaml.write(to: dataYAMLURL, atomically: true, encoding: .utf8)

        datasetReady = true
        datasetNote = trainingSplit(train: train.count, validate: val.count)
        saveProject()
    }

    // MARK: Step 2 — annotation

    func selectImage(_ index: Int) {
        annotateIndex = min(max(0, index), max(0, images.count - 1))
    }

    func addBox(_ rect: CGRect, inViewSize size: CGSize, classIndex: Int) {
        guard images.indices.contains(annotateIndex), size.width > 0, size.height > 0 else { return }
        let x = max(0, min(1, rect.minX / size.width))
        let y = max(0, min(1, rect.minY / size.height))
        let w = max(0.02, min(1 - x, rect.width / size.width))
        let h = max(0.02, min(1 - y, rect.height / size.height))
        images[annotateIndex].boxes.append(
            ClassroomBox(classIndex: min(classIndex, classes.count - 1), x: x, y: y, width: w, height: h)
        )
        datasetReady = false
        saveProject()
    }

    func removeLastBox() {
        guard images.indices.contains(annotateIndex), !images[annotateIndex].boxes.isEmpty else { return }
        images[annotateIndex].boxes.removeLast()
        datasetReady = false
        saveProject()
    }

    func clearBoxes() {
        guard images.indices.contains(annotateIndex) else { return }
        images[annotateIndex].boxes.removeAll()
        datasetReady = false
        saveProject()
    }

    /// Uses the app's current posture model to propose a box for this photo.
    func autoLabelCurrent() {
        guard let url = currentImageURL, let weights = Self.startingWeights(),
              images.indices.contains(annotateIndex) else { return }
        // Inference takes seconds; the user may move to another photo meanwhile.
        let imageID = images[annotateIndex].id
        guard let python = Self.pythonPath(), let bridge = Self.bridgeScript() else {
            banner = t("Python or the bridge script is missing; add photos and box them by hand.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            bridge, "test",
            "--weights", weights.path,
            "--source", url.path,
            "--conf", "0.35",
            "--imgsz", "640",
            "--device", capabilities.device
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard (try? process.run()) != nil else {
                await MainActor.run { self?.banner = self?.t("Could not start inference; check the Python environment.") }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            await MainActor.run {
                guard let self else { return }
                guard let event = Self.parseEvents(data).first(where: { ($0["kind"] as? String) == "detections" }),
                      let raw = event["boxes"] as? [[String: Any]], !raw.isEmpty else {
                    self.banner = self.t("No person detected here; box it by hand.")
                    return
                }
                guard let index = self.images.firstIndex(where: { $0.id == imageID }) else { return }
                let width = (event["width"] as? Double) ?? 1
                let height = (event["height"] as? Double) ?? 1
                self.images[index].boxes = raw.prefix(3).map { box in
                    let label = (box["label"] as? String) ?? ""
                    let x1 = (box["x1"] as? Double) ?? 0
                    let y1 = (box["y1"] as? Double) ?? 0
                    let x2 = (box["x2"] as? Double) ?? 0
                    let y2 = (box["y2"] as? Double) ?? 0
                    return ClassroomBox(
                        classIndex: self.classIndex(forModelLabel: label),
                        x: max(0, x1 / width),
                        y: max(0, y1 / height),
                        width: max(0.02, (x2 - x1) / width),
                        height: max(0.02, (y2 - y1) / height)
                    )
                }
                self.datasetReady = false
                self.saveProject()
                self.banner = self.t("The built-in model boxed it; check the box, then press Next.")
            }
        }
    }

    private func classIndex(forModelLabel label: String) -> Int {
        let lower = label.lowercased()
        // Saved projects may use the old Chinese default names.
        if lower.contains("bad") || lower.contains("不良") {
            return classes.firstIndex { $0.name.lowercased().contains("bad") || $0.name.contains("不良") } ?? 0
        }
        return classes.firstIndex { $0.name.lowercased().contains("good") || $0.name.contains("良好") } ?? 0
    }

    // MARK: Step 3 — training

    func chooseNextRunName() {
        let existing = Set(runs.map(\.name))
        var index = runs.count + 1
        while existing.contains("exp-\(index)") { index += 1 }
        runName = "exp-\(index)"
    }

    func startTraining() {
        guard !progress.isRunning else { return }
        guard let python = Self.pythonPath(), let bridge = Self.bridgeScript() else {
            banner = t("No Python environment found, so training cannot start.")
            return
        }
        guard let weights = Self.startingWeights() else {
            banner = t("The starting weights are missing.")
            return
        }
        buildDataset()
        logLines = []
        lossHistory = []
        metricHistory = []
        progress = ClassroomProgress(isRunning: true)
        chooseNextRunName()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            "-u", bridge, "train",
            "--data", dataYAMLURL.path,
            "--model", weights.path,
            "--epochs", String(config.epochs),
            "--imgsz", String(config.imgsz),
            "--batch", String(config.batch),
            "--patience", String(config.patience),
            "--device", config.device,
            "--project", runsURL.path,
            "--name", runName
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.task = process

        do {
            try process.run()
        } catch {
            progress.isRunning = false
            banner = t("Could not start the training process.")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            await Self.streamLines(pipe) { line in
                await MainActor.run { self?.consume(line: line) }
            }
            await MainActor.run {
                guard let self else { return }
                self.progress.isRunning = false
                self.refreshRuns()
                if self.selectedRuns.isEmpty, let latest = self.runs.first {
                    self.selectedRuns = [latest.name]
                }
                self.step = .records
            }
        }
    }

    func stopTraining() {
        task?.terminate()
        task = nil
        progress.isRunning = false
        banner = t("Training stopped; this run will not be recorded.")
    }

    private func consume(line: String) {
        guard line.hasPrefix("@yolo-classroom ") else {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { appendLog(trimmed) }
            return
        }
        guard let event = Self.parseEvent(String(line.dropFirst("@yolo-classroom ".count))),
              let kind = event["kind"] as? String else { return }
        switch kind {
        case "start":
            progress.epochs = int(event["epochs"]) ?? config.epochs
            appendLog(t("Training started: ") + "\(progress.epochs) " + t(" epochs · ") + "\(int(event["imgsz"]) ?? config.imgsz) px")
        case "epoch":
            progress.epoch = int(event["epoch"]) ?? progress.epoch
            progress.epochs = int(event["epochs"]) ?? progress.epochs
            progress.eta = double(event["eta"]) ?? 0
            progress.elapsed = double(event["elapsed"]) ?? 0
            if let losses = event["losses"] as? [String: Any] {
                for (key, value) in losses {
                    if let number = double(value) { progress.losses[key] = number }
                }
                lossHistory.append(ClassroomPoint(epoch: progress.epoch, value: progress.losses.values.reduce(0, +)))
            }
            appendLog(String(
                format: t("Epoch %d of %d finished · loss %.3f"),
                progress.epoch,
                progress.epochs,
                progress.losses.values.reduce(0, +)
            ))
        case "metrics":
            let epoch = int(event["epoch"]) ?? progress.epoch
            guard epoch <= max(progress.epochs, 1) else { return }
            if let metrics = event["metrics"] as? [String: Any] {
                for (key, value) in metrics {
                    if let number = double(value) { progress.metrics[key] = number }
                }
                if let map50 = double(metrics["metrics/mAP50(B)"]) {
                    metricHistory.append(ClassroomPoint(epoch: epoch, value: map50))
                }
            }
        case "log":
            if let text = event["text"] as? String { appendLog(text) }
        case "done":
            progress.isRunning = false
            appendLog(t("Training finished; the best weights are saved."))
            refreshRuns()
        case "error":
            progress.isRunning = false
            appendLog((event["message"] as? String) ?? "error")
        default:
            break
        }
    }

    private func appendLog(_ text: String) {
        logLines.append(text)
        if logLines.count > 800 { logLines.removeFirst(logLines.count - 800) }
    }

    // MARK: Step 4 — records

    func refreshRuns() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: nil) else {
            runs = []
            return
        }
        var found: [ClassroomRun] = []
        for folder in folders {
            let summary = folder.appendingPathComponent("classroom.json")
            guard let data = try? Data(contentsOf: summary),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var metrics: [String: Double] = [:]
            if let raw = object["metrics"] as? [String: Any] {
                for (key, value) in raw { if let number = double(value) { metrics[key] = number } }
            }
            found.append(
                ClassroomRun(
                    name: (object["name"] as? String) ?? folder.lastPathComponent,
                    epochs: int(object["epochs"]) ?? 0,
                    imgsz: int(object["imgsz"]) ?? 0,
                    batch: (object["batch"] as? String) ?? "-",
                    device: (object["device"] as? String) ?? "-",
                    seconds: double(object["seconds"]) ?? 0,
                    best: (object["best"] as? String) ?? "",
                    metrics: metrics,
                    finishedAt: (object["finishedAt"] as? String) ?? ""
                )
            )
        }
        runs = found.sorted { $0.finishedAt > $1.finishedAt }
        if testWeight.isEmpty, let best = runs.max(by: { $0.map50 < $1.map50 }) {
            testWeight = best.best
        }
    }

    func runCurve(_ run: ClassroomRun, limit: Int = 120) -> [ClassroomPoint] {
        let csv = runsURL.appendingPathComponent(run.name).appendingPathComponent("results.csv")
        guard let text = try? String(contentsOf: csv, encoding: .utf8) else { return [] }
        let rows = text.split(separator: "\n")
        guard rows.count > 1 else { return [] }
        var points: [ClassroomPoint] = []
        for row in rows.dropFirst().prefix(limit) {
            let columns = row.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 4, let epoch = Int(columns[0].replacingOccurrences(of: " ", with: "")) else { continue }
            var total = 0.0
            for index in 1..<min(columns.count, 4) {
                if let value = Double(columns[index]) { total += value }
            }
            points.append(ClassroomPoint(epoch: epoch, value: total))
        }
        return points
    }

    func toggleRunSelection(_ run: ClassroomRun) {
        if selectedRuns.contains(run.name) {
            selectedRuns.remove(run.name)
        } else if selectedRuns.count < 3 {
            selectedRuns.insert(run.name)
        }
    }

    func reuseConfig(_ run: ClassroomRun) {
        config.epochs = run.epochs
        config.imgsz = run.imgsz
        config.batch = Int(run.batch) ?? config.batch
        config.device = run.device
        saveProject()
        step = .train
    }

    // MARK: Step 5 — testing

    func chooseTestImage(_ url: URL) {
        testImagePath = url.path
        detections = []
        testNote = ""
    }

    func runTest() {
        guard let python = Self.pythonPath(), let bridge = Self.bridgeScript() else {
            banner = t("No Python environment, so testing is unavailable.")
            return
        }
        let weights = testWeight.isEmpty ? (Self.startingWeights()?.path ?? "") : testWeight
        guard !weights.isEmpty, !testImagePath.isEmpty else { return }
        testBusy = true
        testNote = ""
        detections = []
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            bridge, "test",
            "--weights", weights,
            "--source", testImagePath,
            "--conf", String(format: "%.2f", testConfidence),
            "--imgsz", "640",
            "--device", capabilities.device
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard (try? process.run()) != nil else {
                await MainActor.run {
                    self?.testBusy = false
                    self?.banner = self?.t("Could not start inference.")
                }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            await MainActor.run {
                guard let self else { return }
                self.testBusy = false
                guard let event = Self.parseEvents(data).first(where: { ($0["kind"] as? String) == "detections" }) else {
                    self.testNote = self.t("Inference failed; see the message below.")
                    return
                }
                let width = (event["width"] as? Double) ?? 1
                let height = (event["height"] as? Double) ?? 1
                let boxes = (event["boxes"] as? [[String: Any]]) ?? []
                self.detections = boxes.map { box in
                    ClassroomDetection(
                        label: (box["label"] as? String) ?? "?",
                        conf: (box["conf"] as? Double) ?? 0,
                        rect: CGRect(
                            x: ((box["x1"] as? Double) ?? 0) / max(width, 1),
                            y: ((box["y1"] as? Double) ?? 0) / max(height, 1),
                            width: (((box["x2"] as? Double) ?? 0) - ((box["x1"] as? Double) ?? 0)) / max(width, 1),
                            height: (((box["y2"] as? Double) ?? 0) - ((box["y1"] as? Double) ?? 0)) / max(height, 1)
                        )
                    )
                }
                self.testNote = self.detections.isEmpty
                    ? self.t("Nothing found — try a lower confidence threshold.")
                    : String(format: self.t("Found %d objects"), self.detections.count)
            }
        }
    }

    // MARK: Step 6 — export

    func runExport() {
        guard let python = Self.pythonPath(), let bridge = Self.bridgeScript() else {
            banner = t("No Python environment, so exporting is unavailable.")
            return
        }
        let weights = testWeight.isEmpty ? (Self.startingWeights()?.path ?? "") : testWeight
        guard !weights.isEmpty else { return }
        exportBusy = true
        exportPath = ""
        installState = ""
        exportLog = []
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            "-u", bridge, "export",
            "--weights", weights,
            "--format", exportFormat,
            // The app only installs 640 × 640 CoreML models; other formats keep the trained size.
            "--imgsz", exportFormat == "coreml" ? "640" : String(config.imgsz),
            "--device", capabilities.device
        ] + (exportHalf ? ["--half"] : [])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        exportTask = process

        do {
            try process.run()
        } catch {
            exportBusy = false
            banner = t("Could not start the export.")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            await Self.streamLines(pipe) { line in
                await MainActor.run { self?.consumeExport(line: line) }
            }
            await MainActor.run { self?.exportBusy = false }
        }
    }

    private func consumeExport(line: String) {
        guard line.hasPrefix("@yolo-classroom ") else {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                exportLog.append(trimmed)
                if exportLog.count > 400 { exportLog.removeFirst(exportLog.count - 400) }
            }
            return
        }
        guard let event = Self.parseEvent(String(line.dropFirst("@yolo-classroom ".count))),
              let kind = event["kind"] as? String else { return }
        switch kind {
        case "export":
            exportPath = (event["path"] as? String) ?? ""
        case "error":
            exportLog.append((event["message"] as? String) ?? "error")
        case "log":
            if let text = event["text"] as? String { exportLog.append(text) }
        default:
            break
        }
    }

    /// Installs the exported CoreML package as the app's detection model.
    func installExportedModel() {
        guard !exportPath.isEmpty else { return }
        let package = URL(fileURLWithPath: exportPath)
        installState = t("Loading model")
        appModel.training.installModel(at: package) { [weak self] in
            guard let self else { return }
            self.installState = self.t("Applied to the app")
            if self.appModel.postureMonitoringEnabled {
                self.appModel.launchPostureMonitor()
            }
        }
    }

    /// The Python that runs fine-tuning, and a way to point at another one now
    /// that the old training page (which owned this picker) is gone.
    var pythonDisplayPath: String { Self.pythonPath() ?? "" }

    func choosePython(_ url: URL) {
        if let probe = capabilityProbe, probe.isRunning { probe.terminate() }
        capabilityProbe = nil
        UserDefaults.standard.set(url.path, forKey: "notch.training.python")
        capabilities.checked = false
        probeCapabilities()
    }

    // MARK: Capabilities

    func probeCapabilities() {
        guard !capabilities.checked, capabilityProbe == nil else { return }
        guard let python = Self.pythonPath(), let bridge = Self.bridgeScript() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [bridge, "check"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        capabilityProbe = process
        Task.detached(priority: .userInitiated) { [weak self] in
            guard (try? process.run()) != nil else {
                await MainActor.run {
                    if self?.capabilityProbe === process { self?.capabilityProbe = nil }
                }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            await MainActor.run {
                guard let self, self.capabilityProbe === process else { return }
                self.capabilityProbe = nil
                guard let event = Self.parseEvents(data).first(where: { ($0["kind"] as? String) == "check" }) else { return }
                var caps = ClassroomCapabilities()
                caps.checked = true
                caps.ultralytics = (event["ultralytics"] as? String) ?? ""
                caps.device = (event["device"] as? String) ?? "auto"
                caps.mps = (event["mps"] as? Bool) ?? false
                caps.coreml = (event["coremltools"] as? String) != nil
                caps.onnx = (event["onnx"] as? String) != nil
                caps.rknn = (event["rknn"] as? String) != nil
                self.capabilities = caps
                self.config.device = caps.device
            }
        }
    }

    // MARK: Helpers

    /// Reads a pipe on a background queue so training never blocks the window.
    nonisolated static func streamLines(_ pipe: Pipe, onLine: @escaping @Sendable (String) async -> Void) async {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let range = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                if let text = String(data: lineData, encoding: .utf8) {
                    await onLine(text)
                }
            }
        }
    }

    nonisolated static func parseEvent(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    nonisolated static func parseEvents(_ data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("@yolo-classroom ") else { return nil }
            return parseEvent(String(line.dropFirst("@yolo-classroom ".count)))
        }
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    @MainActor static func bridgeScript() -> String? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Classroom/yolo_classroom.py").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        let path = PostureTrainingController.projectRoot
            .appendingPathComponent("app/Bridge/yolo_classroom.py").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    @MainActor static func pythonPath() -> String? {
        if let stored = UserDefaults.standard.string(forKey: "notch.training.python"),
           FileManager.default.isExecutableFile(atPath: stored) {
            return stored
        }
        let suggested = PostureTrainingController.suggestedPython
        return suggested.isEmpty ? nil : suggested
    }

    /// Weights to fine-tune from: the bundled posture YOLO26n export.
    @MainActor static func startingWeights() -> URL? {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("Classroom/sitting_posture_yolo26n.pt"))
        }
        candidates.append(
            PostureTrainingController.projectRoot
                .appendingPathComponent("models/sitting_posture_yolo26n.pt")
        )
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
