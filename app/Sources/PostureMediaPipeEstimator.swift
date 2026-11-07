import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Foundation
import ImageIO
import OSLog
import Vision

/// A single worker on the camera's serial analysis queue. The camera drops late frames,
/// so there is at most one request in flight and no queue of stale images in Python.
final class PostureMediaPipeEstimator {
    struct Configuration {
        var python: URL
        var helper: URL
        var libraries: URL?
        var startupTimeout: TimeInterval = 15
        var frameTimeout: TimeInterval = 2
        var retryDelay: TimeInterval = 5

        static func local() throws -> Configuration {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let env = ProcessInfo.processInfo.environment
            let defaults = UserDefaults.standard
            let candidates = [
                env["POSTURE_MEDIAPIPE_PYTHON"],
                defaults.string(forKey: "notch.pose.python"),
                root.appendingPathComponent(".venv-pose/bin/python").path,
                root.appendingPathComponent(".venv/bin/python").path,
                defaults.string(forKey: "notch.training.python"),
                "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"
            ].compactMap { $0 }
            guard let python = candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            else { throw WorkerError.unavailable }
            let helpers = [
                env["POSTURE_MEDIAPIPE_HELPER"].map { URL(fileURLWithPath: $0) },
                Bundle.main.resourceURL?.appendingPathComponent("Pose/mediapipe_pose.py"),
                root.appendingPathComponent("app/Bridge/mediapipe_pose.py")
            ].compactMap { $0 }
            guard let helper = helpers.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else { throw WorkerError.unavailable }
            return Configuration(
                python: URL(fileURLWithPath: python), helper: helper,
                libraries: env["POSTURE_MEDIAPIPE_LIBS"].map { URL(fileURLWithPath: $0) }
                    ?? root.appendingPathComponent("vendor/pylibs")
            )
        }
    }

    struct Landmark: Codable {
        let x: Double
        let y: Double
        let z: Double
        let visibility: Double

        var isValid: Bool {
            x.isFinite && y.isFinite && z.isFinite && visibility.isFinite &&
                (0...1).contains(visibility)
        }

        var isVisible: Bool {
            isValid && visibility >= 0.5 && (0...1).contains(x) && (0...1).contains(y)
        }
    }

    private struct Response: Decodable {
        let version: Int
        let ready: Bool?
        let id: UInt32?
        let bodyCount: Int?
        let faceBox: [Double]?
        let landmarks: [Landmark]?
        let error: String?
    }

    private enum WorkerError: Error {
        case unavailable, timeout, disconnected, invalidResponse
        case backend(String)
    }

    private static let logger = Logger(subsystem: "com.hyacinth.notchtriage", category: "MediaPipe")
    private let configuration: Configuration?
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private var process: Process?
    private var socket: Int32 = -1
    private var received = Data()
    private var frameID: UInt32 = 0
    private var nextAttempt: TimeInterval = 0
    private(set) var lastError: String?
    var helperProcessID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    init(configuration: Configuration? = nil) { self.configuration = configuration }
    deinit { closeWorker() }

    func stop() {
        closeWorker()
        lastError = nil
        nextAttempt = 0
    }

    func analyse(_ pixelBuffer: CVPixelBuffer) -> PosturePoseSample {
        guard ProcessInfo.processInfo.systemUptime >= nextAttempt else { return .empty }
        do {
            let config = try configuration ?? Configuration.local()
            if process?.isRunning != true { try start(config) }
            guard let jpeg = jpegFrame(pixelBuffer), jpeg.count <= 8 * 1024 * 1024 else {
                throw WorkerError.invalidResponse
            }
            frameID &+= 1
            var packet = Data("PMJ1".utf8)
            for value in [frameID, UInt32(jpeg.count)] {
                packet.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24),
                                          UInt8(truncatingIfNeeded: value >> 16),
                                          UInt8(truncatingIfNeeded: value >> 8),
                                          UInt8(truncatingIfNeeded: value)])
            }
            packet.append(jpeg)
            let deadline = ProcessInfo.processInfo.systemUptime + config.frameTimeout
            try send(packet, until: deadline)
            let response = try readResponse(until: deadline)
            guard response.id == frameID else { throw WorkerError.invalidResponse }
            if let error = response.error { throw WorkerError.backend(error) }
            guard let count = response.bodyCount, (0...100).contains(count),
                  let landmarks = response.landmarks,
                  (landmarks.isEmpty || (count == 1 && landmarks.count == 33)),
                  landmarks.allSatisfy(\.isValid) else { throw WorkerError.invalidResponse }
            var faceBox: CGRect?
            if let coordinates = response.faceBox {
                guard coordinates.count == 4, coordinates.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                      coordinates[2] > 0, coordinates[3] > 0,
                      coordinates[0] + coordinates[2] <= 1.001,
                      coordinates[1] + coordinates[3] <= 1.001 else { throw WorkerError.invalidResponse }
                faceBox = CGRect(x: coordinates[0], y: coordinates[1],
                                 width: coordinates[2], height: coordinates[3])
            }
            lastError = nil
            return Self.sample(landmarks, bodyCount: count,
                               width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer), faceBox: faceBox)
        } catch {
            let description = String(describing: error)
            if description != lastError {
                Self.logger.error("MediaPipe worker unavailable: \(description, privacy: .public)")
            }
            closeWorker()
            lastError = description
            nextAttempt = ProcessInfo.processInfo.systemUptime + (configuration?.retryDelay ?? 5)
            return .empty
        }
    }

    private func start(_ config: Configuration) throws {
        closeWorker()
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw WorkerError.unavailable
        }
        socket = descriptors[0]
        let child = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        defer { try? child.close() }
        // Avoid SIGPIPE if Python exits between the poll and write. CLOEXEC prevents
        // a later subprocess inheriting the parent's end and keeping a dead worker alive.
        var enabled: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                         socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(socket, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(socket, F_SETFL, O_NONBLOCK) != -1 else { throw WorkerError.unavailable }
        let worker = Process()
        worker.executableURL = config.python
        worker.arguments = ["-u", config.helper.path] +
            (config.libraries.map { ["--libraries", $0.path] } ?? [])
        worker.standardInput = child
        worker.standardOutput = child
        worker.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        worker.environment = environment
        process = worker
        try worker.run()
        let response = try readResponse(until: ProcessInfo.processInfo.systemUptime + config.startupTimeout)
        if let error = response.error { throw WorkerError.backend(error) }
        guard response.ready == true else { throw WorkerError.invalidResponse }
    }

    private func closeWorker() {
        if socket >= 0 {
            Darwin.close(socket)
            socket = -1
        }
        received.removeAll(keepingCapacity: true)
        if let worker = process, worker.isRunning {
            worker.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if worker.isRunning { Darwin.kill(worker.processIdentifier, SIGKILL) }
            }
        }
        process = nil
    }

    private func wait(for event: Int16, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard socket >= 0 else { throw WorkerError.disconnected }
            guard remaining > 0 else { throw WorkerError.timeout }
            var descriptor = pollfd(fd: socket, events: event, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 30_000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw WorkerError.disconnected }
            guard result != 0 else { throw WorkerError.timeout }
            if descriptor.revents & event != 0 { return }
            throw WorkerError.disconnected
        }
    }

    private func send(_ data: Data, until deadline: TimeInterval) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw WorkerError.invalidResponse }
            var offset = 0
            while offset < bytes.count {
                try wait(for: Int16(POLLOUT), until: deadline)
                let count = Darwin.send(socket, base.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw WorkerError.disconnected }
                offset += count
            }
        }
    }

    private func readResponse(until deadline: TimeInterval) throws -> Response {
        while true {
            if let newline = received.firstIndex(of: 10) {
                let line = received.prefix(upTo: newline)
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let response = try decoder.decode(Response.self, from: Data(line))
                received.removeSubrange(...newline)
                guard response.version == 1 else { throw WorkerError.invalidResponse }
                return response
            }
            guard received.count < 65_536 else { throw WorkerError.invalidResponse }
            try wait(for: Int16(POLLIN), until: deadline)
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.recv(socket, &bytes, bytes.count, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw WorkerError.disconnected }
            received.append(contentsOf: bytes.prefix(count))
        }
    }

    /// Preserve the full camera aspect ratio and orientation. JPEG is only an IPC
    /// payload in memory, never a file; Python converts BGR decoding back to RGB.
    private func jpegFrame(_ buffer: CVPixelBuffer) -> Data? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, 640 / CGFloat(max(width, height)))
        let image = CIImage(cvPixelBuffer: buffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(image, from: image.extent.integral) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage,
                                  [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Map MediaPipe's top-left coordinates to the shared head/shoulder geometry.
    /// Off-screen or low-visibility hips are excluded rather than extrapolated.
    static func sample(_ landmarks: [Landmark], bodyCount: Int,
                       width: Int, height: Int, faceBox: CGRect? = nil) -> PosturePoseSample {
        guard bodyCount == 1 else {
            return PosturePoseSample(bodyCount: bodyCount, features: nil, joints: [], box: nil,
                                     locatedBodies: bodyCount)
        }
        let faceCrop = faceBox.map { PosturePoseEstimator.expandedHeadShoulderBox($0)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        if landmarks.isEmpty {
            return PosturePoseSample(bodyCount: 1, features: nil, joints: [], box: nil,
                                     locationBox: faceCrop, locatedBodies: 1)
        }
        guard landmarks.count == 33, landmarks.allSatisfy(\.isValid), width > 0, height > 0 else {
            return .empty
        }
        let mapping: [(Int, VNHumanBodyPoseObservation.JointName, String)] = [
            (0, .nose, "nose"), (2, .leftEye, "left eye"), (5, .rightEye, "right eye"),
            (7, .leftEar, "left ear"), (8, .rightEar, "right ear"),
            (11, .leftShoulder, "left shoulder"), (12, .rightShoulder, "right shoulder"),
            (13, .leftElbow, "left elbow"), (14, .rightElbow, "right elbow"),
            (15, .leftWrist, "left wrist"), (16, .rightWrist, "right wrist"),
            (23, .leftHip, "left hip"), (24, .rightHip, "right hip"),
            (25, .leftKnee, "left knee"), (26, .rightKnee, "right knee")
        ]
        var points: [VNHumanBodyPoseObservation.JointName: PosturePoseJoint] = [:]
        for (index, key, name) in mapping where landmarks[index].isVisible {
            let landmark = landmarks[index]
            points[key] = PosturePoseJoint(name: name, point: CGPoint(x: landmark.x, y: landmark.y),
                                          confidence: landmark.visibility)
        }
        let midpoints: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName,
                         VNHumanBodyPoseObservation.JointName, String)] = [
            (.leftShoulder, .rightShoulder, .neck, "neck"),
            (.leftHip, .rightHip, .root, "root")
        ]
        for (left, right, key, name) in midpoints {
            if let a = points[left], let b = points[right] {
                points[key] = PosturePoseJoint(name: name,
                    point: CGPoint(x: (a.point.x + b.point.x) / 2, y: (a.point.y + b.point.y) / 2),
                    confidence: min(a.confidence, b.confidence))
            }
        }
        let joints = Array(points.values).sorted { $0.name < $1.name }
        let xs = joints.map { $0.point.x }, ys = joints.map { $0.point.y }
        let box: CGRect? = joints.count >= 2 ? CGRect(
            x: xs.min()!, y: ys.min()!, width: max(0.02, xs.max()! - xs.min()!),
            height: max(0.03, ys.max()! - ys.min()!)
        ) : nil
        let features = PosturePoseEstimator.measurements(
            from: points, width: width, height: height,
            minimumConfidence: 0.5, minimumEarConfidence: 0.5, minimumHipConfidence: 0.5
        )
        return PosturePoseSample(bodyCount: 1, features: features, joints: joints,
                                 box: box, locationBox: box ?? faceCrop,
                                 locationBoxes: [box, faceCrop].compactMap { $0 }, locatedBodies: 1)
    }
}
