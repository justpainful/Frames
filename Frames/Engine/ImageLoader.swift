import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UIKit
import UniformTypeIdentifiers

/// Loads and downsamples still images off the main actor, with a small cache.
///
/// Editing a 48-megapixel photo does not require decoding 48 megapixels to show
/// it on a 6-inch screen. Every load goes through `CGImageSourceCreateThumbnail`
/// with a pixel budget, which keeps memory flat regardless of what the user
/// imported. Full resolution is only ever decoded at export.
actor ImageLoader {
    static let shared = ImageLoader()

    private var cache: [CacheKey: CGImage] = [:]
    private var insertionOrder: [CacheKey] = []
    private let capacity = 12
    private let logger = FramesLog.render

    private struct CacheKey: Hashable {
        let path: String
        let maxPixel: Int
        let modified: TimeInterval
    }

    /// Decodes an image no larger than `maxPixelSize` on its longest edge, with
    /// EXIF orientation already applied.
    func image(at url: URL, maxPixelSize: Int) throws -> CGImage {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = CacheKey(path: url.path, maxPixel: maxPixelSize, modified: modified)
        if let cached = cache[key] { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw FramesError.corruptMedia("no image source at \(url.lastPathComponent)")
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FramesError.corruptMedia("could not decode \(url.lastPathComponent)")
        }

        store(image, for: key)
        return image
    }

    /// Full resolution, orientation-corrected. Used only by the export path.
    func fullResolutionImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FramesError.corruptMedia("no image source at \(url.lastPathComponent)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 16384
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FramesError.corruptMedia("could not decode \(url.lastPathComponent)")
        }
        return image
    }

    private func store(_ image: CGImage, for key: CacheKey) {
        cache[key] = image
        insertionOrder.append(key)
        while insertionOrder.count > capacity {
            let evicted = insertionOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    func purge() {
        cache.removeAll()
        insertionOrder.removeAll()
    }
}
