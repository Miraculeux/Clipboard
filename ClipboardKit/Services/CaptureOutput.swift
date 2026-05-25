import AppKit

/// Centralized hand-off for completed screen captures.
///
/// Every capture path (region, window, long screenshot, annotation) funnels
/// the final PNG through `deliver(...)`. That keeps three side-effects in one
/// place:
///   1. Copy to `NSPasteboard.general` so paste works immediately.
///   2. Optionally write the PNG to disk (Save to disk setting).
///   3. Optionally show the floating thumbnail HUD (post-capture preview).
final class CaptureOutput: @unchecked Sendable {
    nonisolated(unsafe) static let shared = CaptureOutput()

    private init() {}

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// Hand a finalized screenshot to the user.
    /// - Parameters:
    ///   - pngData: The PNG-encoded bytes that will land on the pasteboard
    ///     and (optionally) on disk.
    ///   - image: An optional pre-decoded `NSImage` to reuse for the HUD so
    ///     we don't re-decode the PNG just to show a thumbnail.
    ///   - showThumbnail: Set to `false` when the source itself is the HUD
    ///     or annotator (avoids a second floating thumbnail on top of itself).
    func deliver(pngData: Data, image: NSImage? = nil, showThumbnail: Bool = true) {
        // 1) Clipboard
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)

        // 2) Disk (optional)
        let settings = SettingsManager.shared
        var savedURL: URL? = nil
        if settings.saveScreenshotsToDisk {
            savedURL = writeToDisk(pngData: pngData, folder: settings.screenshotsFolderPath)
        }

        // 3) Thumbnail HUD (optional)
        if showThumbnail && settings.showCaptureThumbnail {
            let img = image ?? NSImage(data: pngData)
            if let img {
                CaptureThumbnailHUD.shared.show(image: img, savedURL: savedURL)
            }
        }
    }

    private func writeToDisk(pngData: Data, folder: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let name = "Screenshot \(Self.filenameFormatter.string(from: Date())).png"
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        do {
            try pngData.write(to: url)
            return url
        } catch {
            print("CaptureOutput: failed to save to disk — \(error.localizedDescription)")
            return nil
        }
    }
}
