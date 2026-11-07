import Combine
import CoreML
import Foundation

/// Owns the app's active detection model. Training itself runs in the Classroom.
@MainActor
final class PostureTrainingController: ObservableObject {
    enum Phase {
        case idle, installing, exported, failed

        var isBusy: Bool { self == .installing }
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var error: String?
    @Published private(set) var activeModelPath = UserDefaults.standard.string(forKey: "notch.posture.customModel")

    nonisolated static var storage: URL {
        if let path = ProcessInfo.processInfo.environment["POSTURE_TRAINING_PATH"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("INT4154 Posture Detecion/Training", isDirectory: true)
    }

    /// #filePath is a development fallback; installed builds carry the backend.
    static var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static var suggestedPython: String {
        let paths = [
            projectRoot.appendingPathComponent(".venv/bin/python").path
        ]
        // No system Python fallback: it never has ultralytics, so the UI should ask instead.
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    /// Compiles, validates and installs an exported CoreML package as the
    /// app's detection model.
    func installModel(at package: URL, onApplied: @escaping @MainActor () -> Void) {
        phase = .installing
        error = nil
        Task {
            do {
                let installed = try await Task.detached(priority: .userInitiated) {
                    let compiled = try await MLModel.compileModel(at: package)
                    defer { try? FileManager.default.removeItem(at: compiled) }
                    let model = try MLModel(contentsOf: compiled)
                    let inputs = model.modelDescription.inputDescriptionsByName.values
                    let outputs = model.modelDescription.outputDescriptionsByName.values
                    guard inputs.count == 1, outputs.count == 1,
                          let image = inputs.first?.imageConstraint,
                          image.pixelsWide == 640, image.pixelsHigh == 640,
                          let shape = outputs.first?.multiArrayConstraint?.shape.map({ $0.intValue }),
                          shape.count == 3, shape[0] == 1, (shape[1] == 6 || shape[2] == 6) else {
                        throw TrainingError.message("Incompatible model format. Export the model again.")
                    }
                    // The Classroom flow can install before any training run created this folder.
                    try FileManager.default.createDirectory(at: Self.storage, withIntermediateDirectories: true)
                    let destination = Self.storage.appendingPathComponent("Active-\(UUID().uuidString).mlmodelc")
                    try FileManager.default.copyItem(at: compiled, to: destination)
                    return destination
                }.value
                UserDefaults.standard.set(installed.path, forKey: "notch.posture.customModel")
                removeInstalledModel(activeModelPath)
                activeModelPath = installed.path
                phase = .exported
                onApplied()
            } catch {
                self.error = error.localizedDescription
                phase = .failed
            }
        }
    }

    func restoreBundledModel() {
        guard !phase.isBusy else { return }
        UserDefaults.standard.removeObject(forKey: "notch.posture.customModel")
        removeInstalledModel(activeModelPath)
        activeModelPath = nil
    }

    /// Deletes a replaced model, but only one this controller installed.
    private func removeInstalledModel(_ path: String?) {
        guard let path, URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            == Self.storage.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

private enum TrainingError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
