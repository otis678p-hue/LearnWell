import CoreGraphics
import Foundation

/// Presentation-only preferences; preview resizing never changes the inference input.
enum PosturePreviewSizing {
    static let heightKey = "notch.posture.previewHeight"
    static let fullFrameKey = "notch.posture.previewFullFrame"
    static let range: ClosedRange<CGFloat> = 120...360
    static let defaultHeight: CGFloat = 220

    static func normalized(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return defaultHeight }
        return min(range.upperBound, max(range.lowerBound, height))
    }

    static func load(defaults: UserDefaults = .standard) -> CGFloat {
        guard let number = defaults.object(forKey: heightKey) as? NSNumber else { return defaultHeight }
        return normalized(CGFloat(number.doubleValue))
    }

    static func expandedHeight(previewHeight: CGFloat, environmentVisible: Bool,
                               availableHeight: CGFloat) -> CGFloat {
        let desired = max(460, 300 + normalized(previewHeight) + (environmentVisible ? 64 : 0))
        let available = availableHeight.isFinite ? max(260, availableHeight) : 700
        return min(desired, available)
    }
}
