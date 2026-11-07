#!/usr/bin/env swift
// Runs the bundled CoreML posture model over image files and prints what the app
// would report, so a new export can be checked without a camera or a full Xcode
// install. Uses the same letterbox + decode + NMS path as PostureCameraController.
//
//   bash tools/run_posture_model_check.sh [image ...]
// With no images, runs inference on a generated blank frame.
import AppKit
import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO

let arguments = Array(CommandLine.arguments.dropFirst())
guard let modelPath = arguments.first else {
    print("usage: posture_model_check.swift <.mlmodelc|.mlpackage> <image> [image ...]")
    exit(2)
}
let imagePaths = Array(arguments.dropFirst())
guard let classifier = PostureClassifier(url: URL(fileURLWithPath: modelPath)) else {
    print("cannot load \(modelPath)")
    exit(3)
}
classifier.confidenceThreshold = PostureDetectionDecoder.defaultConfidenceThreshold

let pipeline = PostureImagePipeline()
var failures = 0

func pixelBuffer(for image: CGImage) -> CVPixelBuffer? {
    let width = image.width
    let height = image.height
    let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                              &buffer) == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
          ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

if imagePaths.isEmpty {
    guard let context = CGContext(data: nil, width: 640, height: 640,
                                  bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("cannot create smoke-check frame")
        exit(1)
    }
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
    guard let image = context.makeImage(), let buffer = pixelBuffer(for: image),
          let letterboxed = pipeline.letterbox(buffer) else {
        print("cannot prepare smoke-check frame")
        exit(1)
    }
    let summary = classifier.predictDetailed(letterboxed.buffer)
    guard summary.bestScore > 0, summary.bestScore.isFinite else {
        print("model returned no valid inference output")
        exit(1)
    }
    print("Generated blank frame: model inference succeeded")
}

for path in imagePaths {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let buffer = pixelBuffer(for: image),
          let letterboxed = pipeline.letterbox(buffer) else {
        print("\(path): cannot read image")
        failures += 1
        continue
    }
    let started = Date()
    let summary = classifier.predictDetailed(letterboxed.buffer)
    let elapsed = Date().timeIntervalSince(started) * 1000
    let outcome = PostureDetectionDecoder.outcome(for: summary.detections)
    if let previewDirectory = ProcessInfo.processInfo.environment["POSTURE_CHECK_PREVIEW_DIR"] {
        let boxes = summary.detections.map { detection in
            PosturePreviewBox(
                label: detection.label,
                confidence: detection.confidence,
                rect: letterboxed.transform.frameRect(for: detection.box)
            )
        }
        if let annotated = PosturePreviewOverlay.draw(image, boxes: boxes) {
            let directory = URL(fileURLWithPath: previewDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = (path as NSString).lastPathComponent
            let target = directory.appendingPathComponent((name as NSString).deletingPathExtension + "-preview.jpg")
            let rep = NSBitmapImageRep(cgImage: annotated)
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try? data.write(to: target)
                print("preview: \(target.path)")
            }
        }
    }
    let boxes = summary.detections.map { detection -> String in
        let rect = letterboxed.transform.frameRect(for: detection.box)
        return String(
            format: "%@ %.2f box=(%.0f,%.0f,%.0f,%.0f)",
            detection.label == .bad ? "Bad" : "Good",
            detection.confidence,
            rect.minX, rect.minY, rect.width, rect.height
        )
    }
    print(String(
        format: "%@ %dx%d -> %@ best=%.3f anchors=%d %.1fms",
        (path as NSString).lastPathComponent,
        image.width, image.height,
        outcome.isConfirmed ? "\(outcome.posture) \(boxes.joined(separator: " | "))" : "no confident posture (\(outcome.peopleCount) boxes)",
        summary.bestScore,
        summary.scoredAnchors,
        elapsed
    ))
}

print(failures == 0 ? "MODEL CHECK PASSED" : "MODEL CHECK FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
