import CoreVideo
import Foundation

/// Diagnostics entry point: `INT4154PostureDetection --posture-selftest` verifies that the
/// bundled model loads and how long one inference takes, without touching the camera.
enum PostureSelfTest {
    static func run() -> Int32 {
        guard let classifier = PostureClassifier() else {
            print("posture self-test: model unavailable")
            return 1
        }
        guard let source = makeBuffer(width: 1280, height: 720) else {
            print("posture self-test: cannot allocate frame")
            return 1
        }
        let pipeline = PostureImagePipeline()
        guard let letterboxed = pipeline.letterbox(source) else {
            print("posture self-test: letterbox failed")
            return 1
        }
        var timings: [Double] = []
        var detections = 0
        for _ in 0..<5 {
            let start = Date()
            detections = classifier.predict(letterboxed.buffer).count
            timings.append(Date().timeIntervalSince(start) * 1000)
        }
        let preview = pipeline.previewImage(from: source)
        print(
            String(
                format: "posture self-test: model ok, %.1f ms average, %d detections on a blank frame, preview %@",
                timings.reduce(0, +) / Double(timings.count),
                detections,
                preview == nil ? "missing" : "ok"
            )
        )
        return detections == 0 ? 0 : 2
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess else { return nil }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x72, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
