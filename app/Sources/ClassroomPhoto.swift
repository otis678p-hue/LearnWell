import AppKit
import ImageIO
import SwiftUI

/// Decode once, off the main actor, at the size the UI actually needs. The
/// original JPEG/HEIC remains untouched for annotation coordinates and training.
actor ClassroomPhotoCache {
    static let shared = ClassroomPhotoCache()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 256
    }

    func image(at url: URL, maximumPixelSize: Int) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        // Imported library paths are unique, but test photos can be replaced.
        // URL.resourceValues can retain stale metadata on the URL instance.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let limit = min(1600, max(1, maximumPixelSize))
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.standardizedFileURL.path)|\(limit)|\(attributes?[.size] ?? 0)|\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR
            ] as CFDictionary),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: thumbnail.width, height: thumbnail.height,
                bitsPerComponent: 8, bytesPerRow: thumbnail.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }

            // An ordinary RGBA bitmap also strips iPhone HDR gain-map metadata
            // that AppKit was repeatedly trying (and failing) to render.
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
            guard let image = context.makeImage() else { return nil }
            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }
    }
}

/// View state retains the decoded image across camera/statistics updates.
/// A changed URL never displays the preceding photo with the new photo's boxes.
struct ClassroomPhoto<Content: View>: View {
    let url: URL
    var maximumPixelSize = 160
    @ViewBuilder var content: (NSImage) -> Content

    private struct Request: Hashable {
        let url: URL
        let maximumPixelSize: Int
    }

    @State private var image: NSImage?
    @State private var loadedRequest: Request?

    var body: some View {
        let request = Request(url: url, maximumPixelSize: maximumPixelSize)
        Group {
            if loadedRequest == request, let image {
                content(image)
            } else {
                Color.secondary.opacity(0.06)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .task(id: request) {
            let bitmap = await ClassroomPhotoCache.shared.image(
                at: request.url, maximumPixelSize: request.maximumPixelSize
            )
            guard !Task.isCancelled else { return }
            image = bitmap.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            loadedRequest = request
        }
    }
}
