import AppKit
import Foundation
import LinkPresentation

/// Fetches and caches rich link metadata (title, OG image, favicon) for URL
/// clipboard items using `LPMetadataProvider`. Thumbnails/icons are written
/// to a per-user cache directory; only their paths land on the `ClipboardItem`
/// so the SQLite payload stays small.
///
/// Coalesces concurrent requests for the same URL so a burst of duplicate
/// copies doesn't open multiple network sockets to the same host.
final class LinkMetadataService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = LinkMetadataService()

    private let queue = DispatchQueue(label: "ClipboardKit.LinkMetadata", qos: .utility)
    /// URLs currently being fetched. Guarded by `queue`.
    private var inFlight: Set<String> = []
    /// Per-URL waiters so multiple callers asking for the same URL get one
    /// network round-trip and all receive the eventual preview.
    private var waiters: [String: [(LinkPreview) -> Void]] = [:]
    private let cacheDir: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = base
            .appendingPathComponent("ClipboardKit", isDirectory: true)
            .appendingPathComponent("LinkPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDir = dir
    }

    /// Returns a URL iff `text` (trimmed) is itself a single http(s) URL —
    /// i.e. the user copied a bare link, not prose that happens to contain
    /// one. Avoids hammering the network with metadata fetches for random
    /// long-form text that mentions URLs.
    static func detectURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Reject any whitespace inside the candidate.
        if trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return nil
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Fetch metadata for `url` (or return the cached failure record).
    /// Completion is dispatched to the main queue so callers can mutate
    /// SwiftUI-published state directly.
    func fetch(url: URL, completion: @escaping (LinkPreview) -> Void) {
        let key = url.absoluteString

        queue.async { [weak self] in
            guard let self = self else { return }
            // Already in flight — register as a waiter, exit.
            if self.inFlight.contains(key) {
                self.waiters[key, default: []].append(completion)
                return
            }
            self.inFlight.insert(key)
            self.waiters[key, default: []].append(completion)

            let provider = LPMetadataProvider()
            provider.timeout = 12
            provider.startFetchingMetadata(for: url) { meta, _ in
                if let meta = meta {
                    self.persistMetadata(meta, url: url) { preview in
                        self.deliver(preview, forKey: key)
                    }
                } else {
                    var preview = self.makeStub(url: url)
                    preview.failed = true
                    self.deliver(preview, forKey: key)
                }
            }
        }
    }

    /// Drain all waiters for `key` with `preview`, then clear the in-flight
    /// record so future fetches can proceed.
    private func deliver(_ preview: LinkPreview, forKey key: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let callbacks = self.waiters.removeValue(forKey: key) ?? []
            self.inFlight.remove(key)
            DispatchQueue.main.async {
                for cb in callbacks { cb(preview) }
            }
        }
    }

    /// Minimum populated preview we always have available: the URL and its
    /// host. Title / image fields get filled in from `LPLinkMetadata`.
    private func makeStub(url: URL) -> LinkPreview {
        LinkPreview(url: url.absoluteString,
                    title: nil,
                    domain: url.host ?? url.absoluteString,
                    imagePath: nil,
                    iconPath: nil,
                    fetchedAt: Date(),
                    failed: false)
    }

    /// Pull title + thumbnail + favicon out of an `LPLinkMetadata`, write the
    /// images to the cache dir, and emit the resulting `LinkPreview`. Image
    /// extraction runs through `NSItemProvider.loadObject` so we wait for
    /// both providers (when present) before calling the completion.
    private func persistMetadata(_ meta: LPLinkMetadata,
                                 url: URL,
                                 completion: @escaping (LinkPreview) -> Void) {
        var preview = makeStub(url: url)
        preview.title = meta.title

        let group = DispatchGroup()
        let lock = NSLock()
        let keyHash = Self.hashKey(url.absoluteString)

        if let provider = meta.imageProvider {
            group.enter()
            provider.loadObject(ofClass: NSImage.self) { obj, _ in
                defer { group.leave() }
                guard let img = obj as? NSImage,
                      let data = Self.pngData(for: img, maxPixel: 640) else { return }
                let dest = self.cacheDir.appendingPathComponent("\(keyHash)_image.png")
                if (try? data.write(to: dest, options: .atomic)) != nil {
                    lock.lock(); preview.imagePath = dest.path; lock.unlock()
                }
            }
        }
        if let provider = meta.iconProvider {
            group.enter()
            provider.loadObject(ofClass: NSImage.self) { obj, _ in
                defer { group.leave() }
                guard let img = obj as? NSImage,
                      let data = Self.pngData(for: img, maxPixel: 96) else { return }
                let dest = self.cacheDir.appendingPathComponent("\(keyHash)_icon.png")
                if (try? data.write(to: dest, options: .atomic)) != nil {
                    lock.lock(); preview.iconPath = dest.path; lock.unlock()
                }
            }
        }
        group.notify(queue: queue) {
            completion(preview)
        }
    }

    // MARK: - Helpers

    /// Stable, runs-independent hash for cache filenames. `String.hashValue`
    /// is randomized per launch and would orphan the cache on every run.
    private static func hashKey(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Render `image` to PNG, downscaling so the larger side is at most
    /// `maxPixel` to keep cached thumbnails tiny.
    private static func pngData(for image: NSImage, maxPixel: CGFloat) -> Data? {
        // Pick the rep with the largest pixel area; fall back to size if no
        // bitmap rep is available (rare for LP output, common for vector).
        var srcWidth = image.size.width
        var srcHeight = image.size.height
        for rep in image.representations {
            let w = rep.pixelsWide, h = rep.pixelsHigh
            if w > 0, h > 0, CGFloat(w) > srcWidth {
                srcWidth = CGFloat(w); srcHeight = CGFloat(h)
            }
        }
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        let scale = min(1, maxPixel / max(srcWidth, srcHeight))
        let outW = max(1, Int((srcWidth * scale).rounded()))
        let outH = max(1, Int((srcHeight * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outW, pixelsHigh: outH,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: outW, height: outH)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH))
        return rep.representation(using: .png, properties: [:])
    }
}
