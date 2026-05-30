import AppKit
import SwiftUI

/// Tiny in-memory cache of source-app icons, keyed by bundle identifier.
///
/// `NSWorkspace.urlForApplication(withBundleIdentifier:)` hits LaunchServices
/// and is fast enough for a one-off, but a scrolling history list would call
/// it many times per frame. The cache shrinks lookups to a dictionary read.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    private var icons: [String: NSImage] = [:]
    /// Bundle IDs we tried and failed to resolve. Cached so we don't pay the
    /// LaunchServices round-trip on every redraw for an uninstalled app.
    private var misses: Set<String> = []

    private init() {}

    func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        if misses.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }

    func appName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let bundle = Bundle(url: url)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}

/// 12pt source-app icon for a clipboard row's metadata line. Falls back to a
/// generic monochrome glyph when the bundle id can't be resolved (uninstalled
/// app, sandboxed lookup failure, etc.) so the meta row keeps a stable shape.
struct SourceAppBadge: View {
    let bundleID: String

    var body: some View {
        if let icon = AppIconCache.shared.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.medium)
                .frame(width: 12, height: 12)
                .help(AppIconCache.shared.appName(forBundleID: bundleID) ?? bundleID)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .help(bundleID)
        }
    }
}
