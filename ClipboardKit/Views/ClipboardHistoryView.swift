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

            // Category picker: split the popover into Clipboard / Screenshots
            // so screenshots don't dominate the list when there are many.
            Picker("", selection: $clipboardManager.selectedCategory) {
                ForEach(HistoryCategory.allCases) { c in
                    Label(c.title, systemImage: c.symbol).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
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

            // History list is its own view so it only re-evaluates when
            // `filteredHistory` changes, not whenever the parent body runs
            // (e.g. after `searchText` typing while debounced).
            HistoryListView()

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

/// Isolated history list. Only this view observes `filteredHistory`, so a
/// capture that updates `history` (but yields the same filtered slice)
/// doesn't tear down rows above/below the scroll area.
struct HistoryListView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager

    var body: some View {
        if clipboardManager.filteredHistory.isEmpty {
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: clipboardManager.selectedCategory.symbol)
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(emptyMessage)
                        .foregroundColor(.secondary)
                    Text(emptyHint)
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(clipboardManager.filteredHistory) { item in
                            // `.equatable()` lets SwiftUI skip body re-eval
                            // when `item` is unchanged — even if the parent
                            // re-renders for an unrelated reason (e.g. another
                            // capture published `history`).
                            ClipboardItemRow(
                                item: item,
                                isKeyboardSelected: item.id == clipboardManager.keyboardSelectedID
                            )
                            .equatable()
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: clipboardManager.keyboardSelectedID) { _, newID in
                    if let newID {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if !clipboardManager.searchText.isEmpty {
            return "No matching items"
        }
        switch clipboardManager.selectedCategory {
        case .clipboard: return "No clipboard history yet"
        case .screenshots: return "No screenshots yet"
        }
    }

    private var emptyHint: String {
        switch clipboardManager.selectedCategory {
        case .clipboard: return "Copy something to get started"
        case .screenshots: return "Press ⌘⇧S to take one"
        }
    }
}

/// Tiny standalone footer so the heavyweight history list doesn't have to
/// re-evaluate just because `history.count` ticked up.
struct HistoryFooterView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager

    var body: some View {
        HStack {
            Text("\(clipboardManager.filteredHistory.count) / \(clipboardManager.history.count) items")
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
    let isKeyboardSelected: Bool
    @EnvironmentObject private var manager: ClipboardManager
    @State private var isHovered = false
    /// Snapshot of "5 minutes ago" computed once per row presentation.
    /// Recomputed when the row is reused for a different item via `task(id:)`.
    @State private var relativeTimestamp: String = ""

    /// SwiftUI compares stored properties for change detection. With closures
    /// stored on the Row, every parent re-render produced new closure
    /// identities and forced every visible row to re-evaluate. This Row is
    /// driven only by `item` and the keyboard-selected flag; declare equality
    /// explicitly so `.equatable()` can short-circuit body re-eval when both
    /// are unchanged. Property wrappers like `@EnvironmentObject` and `@State`
    /// are intentionally excluded from the comparison — they're storage, not
    /// identity.
    static nonisolated func == (lhs: ClipboardItemRow, rhs: ClipboardItemRow) -> Bool {
        lhs.item == rhs.item && lhs.isKeyboardSelected == rhs.isKeyboardSelected
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

                    Button(action: { Self.openAnnotator(path: fileName) }) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .regular))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Annotate…")

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
        .background(rowBackground)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            manager.pasteItem(item)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrag { dragProvider() }
        .contextMenu {
            Button("Paste") { manager.pasteItem(item) }
            Button("Paste as Plain Text") { manager.pasteItem(item, asPlainText: true) }
                .keyboardShortcut(.return, modifiers: [.option])
                .disabled(item.contentType == .image || item.contentType == .fileURL)
            if item.contentType == .image, let fileName = item.fileName {
                Divider()
                Button("Annotate…") { Self.openAnnotator(path: fileName) }
                Button("Recognize Text (OCR)") { Self.recognizeText(path: fileName) }
                Button("Quick Look") { Self.togglePreview(path: fileName) }
                Button("Save to…") { Self.saveImageAs(item) }
            }
            Divider()
            Button("Pin to top") { manager.pinItem(item) }
            Button("Delete", role: .destructive) { manager.deleteItem(item) }
        }
        .task(id: item.id) {
            relativeTimestamp = Self.relativeFormatter.localizedString(
                for: item.timestamp,
                relativeTo: Date()
            )
        }
    }

    private var rowBackground: Color {
        if isKeyboardSelected { return Color.accentColor.opacity(0.22) }
        if isHovered { return Color.accentColor.opacity(0.10) }
        return Color.clear
    }

    /// Build an `NSItemProvider` so the user can drag a history item out of
    /// the popover into other apps. Images are dragged as the on-disk PNG so
    /// receivers get a real file; files are dragged as their original URLs;
    /// text is dragged as a plain string.
    private func dragProvider() -> NSItemProvider {
        switch item.contentType {
        case .image:
            if let path = item.fileName {
                let url = URL(fileURLWithPath: path)
                if let provider = NSItemProvider(contentsOf: url) {
                    return provider
                }
            }
            return NSItemProvider(object: (item.textContent ?? "") as NSString)
        case .fileURL:
            if let paths = item.filePaths, let first = paths.first {
                let url = URL(fileURLWithPath: first)
                if let provider = NSItemProvider(contentsOf: url) {
                    return provider
                }
            }
            return NSItemProvider(object: (item.textContent ?? "") as NSString)
        case .text, .richText:
            return NSItemProvider(object: (item.textContent ?? "") as NSString)
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

    /// Load the PNG at `path` from disk and open it in the annotation
    /// window. Used by both the row's wand button and the context menu.
    fileprivate static func openAnnotator(path: String) {
        guard let image = NSImage(contentsOfFile: path) else { NSSound.beep(); return }
        // Close the popover *synchronously* (close() bypasses the dismiss
        // animation that performClose uses) so its window has fully gone away
        // before we try to bring the annotator key. Otherwise the popover's
        // closing animation steals focus on the very first invocation and the
        // new window opens behind the previous frontmost app.
        AppDelegate.shared?.popover.close()
        ImageQuickPreview.shared.dismiss()
        // Hop a runloop tick so the AppKit window server has actually torn
        // down the popover before we order the annotator front.
        DispatchQueue.main.async {
            AnnotationWindowController.shared.present(image: image)
        }
    }

    /// Run OCR on the image at `path` and show the recognized text in a
    /// floating panel. Closes the popover first so the result panel can
    /// receive focus.
    fileprivate static func recognizeText(path: String) {
        let url = URL(fileURLWithPath: path)
        AppDelegate.shared?.popover.close()
        ImageQuickPreview.shared.dismiss()
        DispatchQueue.main.async {
            OCRService.recognizeText(at: url) { result in
                switch result {
                case .success(let text):
                    OCRResultWindowController.present(recognizedText: text)
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = "No text recognized"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .informational
                    NSApp.activate()
                    alert.runModal()
                }
            }
        }
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
