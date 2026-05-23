import Foundation
import AppKit
import ImageIO

/// Async, bounded cache of downscaled NSImage thumbnails for clipboard images.
/// Keeps the SwiftUI list snappy by avoiding synchronous full-resolution
/// `NSImage(contentsOfFile:)` calls during scrolling.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()
    private let queue = DispatchQueue(
        label: "ClipboardKit.ThumbnailCache",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Tracks every (path, maxPixel) key currently in the cache so that
    /// `invalidate(path:)` can drop *all* sizes for that path — not just a
    /// hardcoded list. Protected by `keysLock` because `loadThumbnail` runs
    /// on `queue` (concurrent) and `invalidate` runs on the main thread.
    private var trackedKeys: [String: Set<Int>] = [:]
    private let keysLock = NSLock()

    private init() {}

    func cachedThumbnail(forPath path: String, maxPixel: CGFloat) -> NSImage? {
        cache.object(forKey: Self.key(path: path, maxPixel: maxPixel))
    }

    func loadThumbnail(forPath path: String,
                       maxPixel: CGFloat,
                       completion: @escaping (NSImage?) -> Void) {
        let key = Self.key(path: path, maxPixel: maxPixel)
        if let img = cache.object(forKey: key) {
            completion(img)
            return
        }
        queue.async { [weak self] in
            let img = Self.makeThumbnail(path: path, maxPixel: maxPixel)
            if let img = img, let self = self {
                self.cache.setObject(img, forKey: key)
                self.keysLock.lock()
                self.trackedKeys[path, default: []].insert(Int(maxPixel))
                self.keysLock.unlock()
            }
            DispatchQueue.main.async {
                completion(img)
            }
        }
    }

    func invalidate(path: String) {
        keysLock.lock()
        let sizes = trackedKeys.removeValue(forKey: path) ?? []
        keysLock.unlock()
        for mp in sizes {
            cache.removeObject(forKey: Self.key(path: path, maxPixel: CGFloat(mp)))
        }
    }

    private static func key(path: String, maxPixel: CGFloat) -> NSString {
        "\(path)|\(Int(maxPixel))" as NSString
    }

    private static func makeThumbnail(path: String, maxPixel: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Tiny in-memory cache for `isDirectory` lookups so SwiftUI rows don't stat
/// the filesystem on every redraw.
final class FileTypeCache {
    static let shared = FileTypeCache()

    /// `NSCache` gives us automatic LRU-ish eviction under memory pressure and
    /// a hard count limit, so this never grows without bound (unlike a plain
    /// dictionary that we'd have to evict by hand).
    private let cache: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 512
        return c
    }()

    private init() {}

    func isDirectory(_ path: String) -> Bool {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached.boolValue
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let value = isDir.boolValue

        cache.setObject(NSNumber(value: value), forKey: key)
        return value
    }
}
