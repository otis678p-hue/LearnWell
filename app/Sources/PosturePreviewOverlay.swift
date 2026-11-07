import AppKit
import CoreGraphics
import Foundation

/// One detection drawn on the panel preview: label, score and a box in the
/// *preview image's* pixel coordinates (origin top-left, like the camera frame).
struct PosturePreviewBox {
    let label: PostureDetection.Label
    let confidence: Double
    let rect: CGRect
    /// Which path produced this verdict, shown as a suffix so the preview never hides the
    /// fact that a box came from the pose fallback rather than the head.
    var source: PostureVerdictSource = .model
    var language: AppLanguage = .defaultLanguage

    var text: String {
        let base = String(format: "%@ %.2f", labelText, confidence)
        switch source {
        case .model: return base
        case .poseCrop: return base + " " + language.localized("pose crop")
        case .pose: return base + " " + language.localized("pose")
        case .poseVeto: return base + " " + language.localized("veto")
        case .poseConflict: return base + " " + language.localized("conflict")
        }
    }

    private var labelText: String {
        language.localized(label == .bad ? "Bad posture" : "Good posture")
    }

    var color: NSColor {
        label == .bad
            ? NSColor(srgbRed: 0.93, green: 0.26, blue: 0.26, alpha: 1)
            : NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    }
}

/// The body-pose skeleton drawn under the verdict, in normalised y-down coordinates.
struct PosturePreviewSkeleton {
    let joints: [PosturePoseJoint]
    let box: CGRect
    let color: NSColor

    /// Pairs of joint names the overlay connects, so the drawing reads as a body.
    static let connections: [(String, String)] = [
        ("neck", "nose"),
        ("left ear", "left eye"), ("left eye", "nose"),
        ("right ear", "right eye"), ("right eye", "nose"),
        ("neck", "left shoulder"), ("neck", "right shoulder"),
        ("neck", "root"), ("root", "left hip"), ("root", "right hip"),
        ("left hip", "right hip"),
        ("left shoulder", "left elbow"), ("left elbow", "left wrist"),
        ("right shoulder", "right elbow"), ("right elbow", "right wrist"),
        ("left hip", "left knee"), ("right hip", "right knee"),
    ]
}

/// Draws the detector's verdict onto the preview frame the notch panel shows:
/// a rounded box around the person plus a label chip carrying the class and its
/// confidence, so the ring is never the only evidence on screen.
enum PosturePreviewOverlay {
    static func draw(
        _ image: CGImage,
        boxes: [PosturePreviewBox],
        skeleton: PosturePreviewSkeleton? = nil
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        if let skeleton {
            drawSkeleton(skeleton, width: CGFloat(width), height: CGFloat(height))
        }
        let fontSize = max(11, (CGFloat(width) * 0.022).rounded())
        let lineWidth = max(2, (fontSize / 5).rounded())
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)

        for box in boxes {
            // The overlay works in top-left coordinates; AppKit draws bottom-left.
            let rect = CGRect(
                x: box.rect.minX,
                y: CGFloat(height) - box.rect.maxY,
                width: box.rect.width,
                height: box.rect.height
            ).intersection(bounds)
            guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }

            let radius = min(lineWidth * 3, min(rect.width, rect.height) / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = lineWidth
            box.color.setStroke()
            path.stroke()

            let attributed = NSAttributedString(
                string: box.text,
                attributes: [.font: font, .foregroundColor: NSColor.white]
            )
            let textSize = attributed.size()
            let padding = (fontSize * 0.32).rounded()
            var chip = CGRect(
                x: rect.minX,
                y: rect.maxY - textSize.height - 2 * padding,
                width: textSize.width + 2 * padding,
                height: textSize.height + 2 * padding
            )
            // Keep the chip glued to the box but inside the frame.
            if chip.minX + chip.width > bounds.maxX {
                chip.origin.x = bounds.maxX - chip.width
            }
            if chip.minY < 0 {
                chip.origin.y = rect.minY
            }
            box.color.setFill()
            NSBezierPath(roundedRect: chip, xRadius: padding, yRadius: padding).fill()
            attributed.draw(at: CGPoint(x: chip.minX + padding, y: chip.minY + padding))
        }

        context.flushGraphics()
        return rep.cgImage
    }

    /// Thin lines between the joints plus a dot on each, in the verdict's colour. The
    /// points arrive normalised with a top-left origin and AppKit draws bottom-left.
    private static func drawSkeleton(
        _ skeleton: PosturePreviewSkeleton,
        width: CGFloat,
        height: CGFloat
    ) {
        let scale = max(2, (width * 0.006).rounded())
        var points: [String: CGPoint] = [:]
        for joint in skeleton.joints {
            points[joint.name] = CGPoint(x: joint.point.x * width,
                                         y: (1 - joint.point.y) * height)
        }
        skeleton.color.withAlphaComponent(0.65).setStroke()
        for (start, end) in PosturePreviewSkeleton.connections {
            guard let from = points[start], let to = points[end] else { continue }
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = scale
            path.lineCapStyle = .round
            path.stroke()
        }
        skeleton.color.setFill()
        for point in points.values {
            NSBezierPath(ovalIn: CGRect(x: point.x - scale, y: point.y - scale,
                                        width: scale * 2, height: scale * 2)).fill()
        }
    }
}
