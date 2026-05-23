import SwiftUI

struct ClipboardHistoryView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager
    @EnvironmentObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Clipboard History")
                    .font(.headline)
                Spacer()
                Button(action: { openSettings() }) {
                    Image(systemName: "gear")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button(action: { clipboardManager.clearHistory() }) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear All")

                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search clipboard history...", text: $clipboardManager.searchText)
                    .textFieldStyle(.plain)
                if !clipboardManager.searchText.isEmpty {
                    Button(action: { clipboardManager.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // History list
            if clipboardManager.filteredHistory.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(clipboardManager.searchText.isEmpty ? "No clipboard history yet" : "No matching items")
                        .foregroundColor(.secondary)
                    Text("Copy something to get started")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(clipboardManager.filteredHistory) { item in
                            // `.equatable()` lets SwiftUI skip body re-eval
                            // when `item` is unchanged — even if the parent
                            // re-renders for an unrelated reason (e.g. another
                            // capture published `history`). The Row no longer
                            // stores closures whose identities flip on every
                            // parent body pass; it pulls the manager from the
                            // environment and acts on `item` directly.
                            ClipboardItemRow(item: item)
                                .equatable()
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // Footer is its own view so the parent body doesn't have to
            // observe `history.count` directly. The footer still updates on
            // every capture, but it's a single Text — cheap.
            HistoryFooterView()
        }
        .frame(width: 350, height: 500)
    }

    private func openSettings() {
        AppDelegate.shared.openSettings()
    }
}

/// Tiny standalone footer so the heavyweight history list doesn't have to
/// re-evaluate just because `history.count` ticked up.
struct HistoryFooterView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager

    var body: some View {
        HStack {
            Text("\(clipboardManager.history.count) items")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("⌘⇧V to toggle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct ClipboardItemRow: View, Equatable {
    let item: ClipboardItem
    @EnvironmentObject private var manager: ClipboardManager
    @State private var isHovered = false
    /// Snapshot of "5 minutes ago" computed once per row presentation.
    /// Recomputed when the row is reused for a different item via `task(id:)`.
    @State private var relativeTimestamp: String = ""

    /// SwiftUI compares stored properties for change detection. With closures
    /// stored on the Row, every parent re-render produced new closure
    /// identities and forced every visible row to re-evaluate. This Row is
    /// driven only by `item`; declare equality explicitly so `.equatable()`
    /// can short-circuit body re-eval when `item` is unchanged. Property
    /// wrappers like `@EnvironmentObject` and `@State` are intentionally
    /// excluded from the comparison — they're storage, not identity.
    static func == (lhs: ClipboardItemRow, rhs: ClipboardItemRow) -> Bool {
        lhs.item == rhs.item
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let saveAsTimestampFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Type icon
            itemIcon
                .frame(width: 24)
                .foregroundColor(.secondary)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                if item.contentType == .image, let fileName = item.fileName {
                    imagePreview(path: fileName)
                } else if item.contentType == .fileURL, let paths = item.filePaths, !paths.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(paths.prefix(3), id: \.self) { path in
                            HStack(spacing: 4) {
                                fileIcon(for: path)
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                        }
                        if paths.count > 3 {
                            Text("+ \(paths.count - 3) more")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text(item.previewText)
                        .font(.system(size: 12))
                        .lineLimit(3)
                        .foregroundColor(.primary)
                }

                HStack {
                    Text(relativeTimestamp)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if item.originalSize > 1000 {
                        Text("• \(item.formattedSize)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Action buttons — always present so hover/click hit-testing
            // stays stable; only the visibility flips on hover.
            HStack(spacing: 6) {
                if item.contentType == .image, let fileName = item.fileName {
                    Button(action: { Self.togglePreview(path: fileName) }) {
                        Image(systemName: "eye")
                            .font(.system(size: 12, weight: .regular))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look")

                    Button(action: { Self.saveImageAs(item) }) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .regular))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Save to…")
                }

                Button(action: { manager.pinItem(item) }) {
                    Image(systemName: "pin")
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Move to top")

                Button(action: { manager.deleteItem(item) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16, height: 16)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(8)
        .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            manager.pasteItem(item)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: item.id) {
            relativeTimestamp = Self.relativeFormatter.localizedString(
                for: item.timestamp,
                relativeTo: Date()
            )
        }
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item.contentType {
        case .text:
            Image(systemName: "doc.text")
        case .richText:
            Image(systemName: "doc.richtext")
        case .image:
            Image(systemName: "photo")
        case .fileURL:
            Image(systemName: "folder")
        }
    }

    @ViewBuilder
    private func imagePreview(path: String) -> some View {
        ThumbnailImageView(path: path, maxPixel: 160)
    }

    @ViewBuilder
    private func fileIcon(for path: String) -> some View {
        let ext = (path as NSString).pathExtension.lowercased()
        let isDir = FileTypeCache.shared.isDirectory(path)
        if isDir {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.blue)
        } else {
            switch ext {
            case "pdf":
                Image(systemName: "doc.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            case "jpg", "jpeg", "png", "gif", "heic", "webp":
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            case "mp4", "mov", "avi", "mkv":
                Image(systemName: "film")
                    .font(.system(size: 11))
                    .foregroundColor(.purple)
            case "zip", "tar", "gz", "rar":
                Image(systemName: "doc.zipper")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            default:
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Static so the action button doesn't need to capture parent state.
    /// Self-contained: derives everything it needs from `item`.
    fileprivate static func togglePreview(path: String) {
        ImageQuickPreview.shared.toggle(path: path)
    }

    fileprivate static func saveImageAs(_ item: ClipboardItem) {
        guard item.contentType == .image, let sourcePath = item.fileName else { return }
        let sourceURL = URL(fileURLWithPath: sourcePath)

        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        let stamp = saveAsTimestampFormatter.string(from: item.timestamp)
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Screenshot \(stamp).png"

        // Make the panel actually appear in front of the popover.
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: sourceURL, to: dest)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t save image"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

/// Async-loading, cached thumbnail view. Avoids decoding full-resolution PNGs
/// on the main thread while the history list scrolls.
struct ThumbnailImageView: View {
    let path: String
    let maxPixel: CGFloat

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 80)
                    .cornerRadius(4)
            } else if failed {
                Text("Image not found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 80)
                    .cornerRadius(4)
            }
        }
        .onAppear(perform: load)
        .onChange(of: path) { _, _ in
            image = nil
            failed = false
            load()
        }
    }

    private func load() {
        if let cached = ThumbnailCache.shared.cachedThumbnail(forPath: path, maxPixel: maxPixel) {
            self.image = cached
            return
        }
        ThumbnailCache.shared.loadThumbnail(forPath: path, maxPixel: maxPixel) { img in
            if let img = img {
                self.image = img
            } else {
                self.failed = true
            }
        }
    }
}
