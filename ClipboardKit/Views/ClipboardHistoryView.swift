import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ClipboardHistoryView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager
    @EnvironmentObject var settingsManager: SettingsManager
    /// Highlight the popover border while the user is hovering a drag over
    /// it, so the drop target is obviously discoverable.
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // ---- Top strata (search + tabs + chips) ----
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search…", text: $clipboardManager.searchText)
                            .textFieldStyle(.plain)
                        if !clipboardManager.searchText.isEmpty {
                            Button(action: { clipboardManager.searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary.opacity(0.5))
                    )

                    Menu {
                        Button("Settings…") { openSettings() }
                        Divider()
                        Button("Clear History", role: .destructive) {
                            clipboardManager.clearHistory()
                        }
                        Divider()
                        Button("Quit ClipboardKit") { NSApp.terminate(nil) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)
                    .help("More")
                }

                Picker("", selection: $clipboardManager.selectedCategory) {
                    ForEach(HistoryCategory.allCases) { c in
                        Label(c.title, systemImage: c.symbol).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Type-filter chips appear only on the Clipboard tab.
                // Reserve a fixed slot so switching tabs doesn't jump the
                // list's vertical position.
                if clipboardManager.selectedCategory == .clipboard {
                    TypeFilterChipRow()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(VisualEffectBackground(material: .headerView, blendingMode: .behindWindow))

            // ---- List ----
            HistoryListView()
                .background(Color(NSColor.textBackgroundColor))

            // ---- Footer strata ----
            HistoryFooterView()
                .background(VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow))
        }
        .frame(width: 460, height: 640)
        .overlay(
            // Accent ring while a drag is hovering over the popover; lets
            // the user know this surface accepts drops without taking up
            // permanent UI real estate.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(2)
                .opacity(isDropTargeted ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
                .allowsHitTesting(false)
        )
        .onDrop(
            of: [
                UTType.fileURL,
                UTType.image,
                UTType.url,
                UTType.text,
                UTType.plainText,
                UTType.utf8PlainText,
            ],
            isTargeted: $isDropTargeted,
            perform: handleDrop(providers:)
        )
    }

    private func openSettings() {
        AppDelegate.shared.openSettings()
    }

    /// Route a drop's providers to the right `ClipboardManager` import API.
    /// File URLs win over images win over plain text so a drag of a single
    /// PNG from Finder lands as a `.fileURL` item (with its real path)
    /// instead of a re-encoded image blob.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            collectFileURLs(from: fileProviders) { paths in
                guard !paths.isEmpty else { return }
                clipboardManager.importDroppedFiles(paths: paths)
            }
            return true
        }

        let imageProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if let imageProvider = imageProviders.first {
            // Prefer PNG so we skip a TIFF→PNG transcode on the import path.
            let pngID = UTType.png.identifier
            let typeID = imageProvider.registeredTypeIdentifiers.first(where: { $0 == pngID })
                ?? imageProvider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
            guard let typeID else { return false }
            imageProvider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                guard let data = data else { return }
                DispatchQueue.main.async {
                    clipboardManager.importDroppedImage(data: data, isPNG: typeID == pngID)
                }
            }
            return true
        }

        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
                    guard let text = reading as? String else { return }
                    DispatchQueue.main.async {
                        clipboardManager.importDroppedText(text)
                    }
                }
                return true
            }
        }
        return false
    }

    /// Resolve every file-URL provider into a real path. The completion fires
    /// exactly once, after every provider has resolved (or timed out).
    private func collectFileURLs(from providers: [NSItemProvider],
                                 completion: @escaping ([String]) -> Void) {
        let group = DispatchGroup()
        // `paths` is mutated from the loadItem completion callbacks (which
        // may fire on arbitrary queues); funnel writes through `queue` so
        // we don't race ordering.
        var paths: [String] = []
        let queue = DispatchQueue(label: "ClipboardKit.DropCollect")
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, url.isFileURL {
                    queue.async { paths.append(url.path) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(paths) }
    }
}

/// Isolated history list. Only this view observes `filteredHistory`, so a
/// capture that updates `history` (but yields the same filtered slice)
/// doesn't tear down rows above/below the scroll area.
struct HistoryListView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager

    var body: some View {
        // Snippets live in a parallel data store and have their own row
        // chrome / context menu; route them to a dedicated subview rather
        // than trying to coerce them through `ClipboardItemRow`.
        if clipboardManager.selectedCategory == .snippets {
            SnippetsListView()
        } else if clipboardManager.filteredHistory.isEmpty {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                        // Section the list by recency (and pull pins to the
                        // very top). Headers give the user temporal anchors
                        // so a long scroll doesn't feel like one undifferentiated
                        // wall of rows. Quick-paste numbers still come from
                        // the flat-list index so ⌘1–⌘9 maps to what's actually
                        // visible top-to-bottom.
                        let indexed = Array(clipboardManager.filteredHistory.enumerated())
                        ForEach(HistorySectionBucket.bucketize(indexed)) { section in
                            Section {
                                ForEach(section.entries, id: \.item.id) { entry in
                                    ClipboardItemRow(
                                        item: entry.item,
                                        isKeyboardSelected: entry.item.id == clipboardManager.keyboardSelectedID,
                                        quickPasteNumber: entry.index < 9 ? entry.index + 1 : nil
                                    )
                                    .equatable()
                                    .id(entry.item.id)
                                }
                            } header: {
                                SectionHeader(title: section.title, count: section.entries.count)
                            }
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
        case .snippets: return "No snippets yet"
        }
    }

    private var emptyHint: String {
        switch clipboardManager.selectedCategory {
        case .clipboard: return "Copy something to get started"
        case .screenshots: return "Press ⌘⇧S to take one"
        case .snippets: return "Save text from history or create a new one"
        }
    }
}

/// Horizontal row of single-tap chips that narrows the clipboard tab by
/// type. Lives in its own view so the parent body doesn't have to observe
/// the chip selection — only this view does, and the change still triggers
/// the filter pipeline through the `@Published` on the manager.
struct TypeFilterChipRow: View {
    @EnvironmentObject var clipboardManager: ClipboardManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TypeFilter.allCases) { filter in
                    Chip(filter: filter,
                         isSelected: clipboardManager.selectedTypeFilter == filter,
                         action: { clipboardManager.selectedTypeFilter = filter })
                }
            }
        }
    }

    private struct Chip: View {
        let filter: TypeFilter
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: filter.symbol)
                        .font(.system(size: 10, weight: .medium))
                    Text(filter.title)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        isSelected
                            ? AnyShapeStyle(.tint.opacity(0.18))
                            : AnyShapeStyle(.quaternary.opacity(0.6))
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.6) : Color.clear,
                        lineWidth: 1
                    )
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Tiny standalone footer so the heavyweight history list doesn't have to
/// re-evaluate just because `history.count` ticked up.
struct HistoryFooterView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager

    var body: some View {
        HStack {
            switch clipboardManager.selectedCategory {
            case .clipboard, .screenshots:
                Text("\(clipboardManager.filteredHistory.count) / \(clipboardManager.history.count) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .snippets:
                Text("\(clipboardManager.filteredSnippets.count) / \(clipboardManager.snippets.count) snippets")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
    /// 1-based shortcut number (⌘N) displayed as a tiny leading badge so
    /// users know which row corresponds to ⌘1–⌘9. `nil` for rows beyond
    /// the ninth (we only register that many digits).
    let quickPasteNumber: Int?
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
        // `ClipboardItem ==` compares by id only; that's correct for the
        // history array (items are immutable except for `isPinned`). The Row
        // also displays the pin indicator, so include it explicitly so a
        // pin/unpin actually triggers a re-render of the visible row.
        lhs.item == rhs.item
            && lhs.item.isPinned == rhs.item.isPinned
            && lhs.isKeyboardSelected == rhs.isKeyboardSelected
            && lhs.quickPasteNumber == rhs.quickPasteNumber
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let saveAsTimestampFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Leading column: ⌘N quick-paste pill for the first nine rows,
            // type icon otherwise. The pill is sized to its own intrinsic
            // dimensions, then placed in a 28pt slot so the row content
            // start column stays stable as the user scrolls past row nine.
            ZStack {
                if let n = quickPasteNumber {
                    quickPasteBadge(n)
                } else {
                    itemIcon
                }
            }
            .frame(width: 28, alignment: .center)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                if item.contentType == .image, let fileName = item.fileName {
                    imagePreview(path: fileName)
                } else if item.contentType == .fileURL, let paths = item.filePaths, !paths.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(paths.prefix(3), id: \.self) { path in
                            HStack(spacing: 4) {
                                fileIcon(for: path)
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                            }
                        }
                        if paths.count > 3 {
                            Text("+ \(paths.count - 3) more")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                } else if let preview = item.linkPreview, !preview.failed {
                    linkPreviewCard(preview: preview, fallbackText: item.previewText)
                } else {
                    Text(item.previewText)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .foregroundColor(.primary)
                }

                HStack(spacing: 6) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .help("Pinned")
                    }
                    if let bundleID = item.sourceBundleID {
                        SourceAppBadge(bundleID: bundleID)
                    }
                    if item.isFromHandoff {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .help(item.contentType == .fileURL
                                  ? "From another device (Handoff) — file lives on the source Mac and may not paste once it's offline"
                                  : "From another device (Handoff)")
                    }
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

                    Button(action: { Self.revealInSeeker(path: fileName) }) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .regular))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Seeker")
                }

                // File items (Finder copies + our own MP4/GIF recordings)
                // get a Reveal-in-Seeker shortcut too. We default to the
                // first path \u2014 multi-file selections still reveal all via
                // the context menu.
                if item.contentType == .fileURL,
                   let first = item.filePaths?.first {
                    Button(action: { Self.togglePreview(path: first) }) {
                        Image(systemName: "eye")
                            .font(.system(size: 12, weight: .regular))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look")

                    Button(action: { UrlActions.revealInSeeker(path: first) }) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .regular))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Seeker")
                }

                Button(action: { manager.togglePin(item) }) {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16, height: 16)
                        .foregroundColor(item.isPinned ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin" : "Pin to top")

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
            // Read the modifier state at the moment of click so ⌥/⇧ select a
            // paste transform (plain text / trimmed). `NSEvent.modifierFlags`
            // reflects the hardware state and is set during the click event.
            manager.pasteItem(item, transform: PasteTransform.from(modifiers: NSEvent.modifierFlags))
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrag { dragProvider() }
        .contextMenu {
            Button("Paste") { manager.pasteItem(item) }
            Button("Paste as Plain Text") { manager.pasteItem(item, transform: .plainText) }
                .keyboardShortcut(.return, modifiers: [.option])
                .disabled(item.contentType == .image || item.contentType == .fileURL)
            Button("Paste Trimmed") { manager.pasteItem(item, transform: .trimmed) }
                .keyboardShortcut(.return, modifiers: [.shift])
                .disabled(item.contentType == .image || item.contentType == .fileURL)
            if item.contentType == .text || item.contentType == .richText {
                Menu("Paste as…") {
                    Button("lowercase")   { manager.pasteItem(item, transform: .lowercase) }
                        .keyboardShortcut(.return, modifiers: [.control])
                    Button("UPPERCASE")   { manager.pasteItem(item, transform: .uppercase) }
                        .keyboardShortcut(.return, modifiers: [.control, .shift])
                    Button("Title Case")  { manager.pasteItem(item, transform: .titleCase) }
                        .keyboardShortcut(.return, modifiers: [.control, .option])
                }
                Divider()
                Button("Save as Snippet") { manager.saveItemAsSnippet(item) }
                if let actions = UrlActions.detect(in: item.textContent ?? ""), !actions.isEmpty {
                    Divider()
                    ForEach(actions) { action in
                        Button(action.label) { action.perform() }
                    }
                }
            }
            if item.contentType == .image, let fileName = item.fileName {
                Divider()
                Button("Annotate…") { Self.openAnnotator(path: fileName) }
                Button("Recognize Text (OCR)") { Self.recognizeText(path: fileName) }
                Button("Quick Look") { Self.togglePreview(path: fileName) }
                Button("Reveal in Seeker") { Self.revealInSeeker(path: fileName) }
            }
            if item.contentType == .fileURL, let paths = item.filePaths, !paths.isEmpty {
                Divider()
                Button("Reveal in Seeker") {
                    for p in paths { UrlActions.revealInSeeker(path: p) }
                }
                Button("Open") {
                    AppDelegate.shared?.popover.close()
                    for p in paths { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                }
            }
            Divider()
            Button(item.isPinned ? "Unpin" : "Pin to top") { manager.togglePin(item) }
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
        if isKeyboardSelected { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color.primary.opacity(0.06) }
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

    /// Colored, type-specific icon for the leading column. The tint isn't
    /// load-bearing — type is also conveyed via row content — but a quick
    /// glance at the column makes it easy to skim "where's the file I just
    /// copied?" without reading every preview.
    @ViewBuilder
    private var itemIcon: some View {
        switch item.contentType {
        case .text:
            // URL items get a link-colored globe so they pop out of a
            // wall of plain text.
            if let body = item.textContent, looksLikeURL(body) {
                Image(systemName: "link")
                    .foregroundStyle(Color.blue)
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
        case .richText:
            Image(systemName: "doc.richtext")
                .foregroundStyle(Color.purple)
        case .image:
            Image(systemName: "photo")
                .foregroundStyle(Color.pink)
        case .fileURL:
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.orange)
        }
    }

    /// Cheap URL sniff — `TypeFilter.isLink` is internal; reproduce its
    /// gist inline so the row doesn't have to reach into the manager.
    private func looksLikeURL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" "), !t.contains("\n"), t.count <= 2048 else { return false }
        if let url = URL(string: t),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "mailto", "tel", "file"].contains(scheme) {
            return true
        }
        return false
    }

    /// Subtle "⌘N" pill rendered in the leading column for the first
    /// nine rows. Filled with a tinted background and accent-colored
    /// glyph so it reads as a hint, not a status badge.
    @ViewBuilder
    private func quickPasteBadge(_ n: Int) -> some View {
        Text("⌘\(n)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(.quaternary.opacity(0.7))
            )
            .help("Press ⌘\(n) to paste this item")
    }

    @ViewBuilder
    private func imagePreview(path: String) -> some View {
        ThumbnailImageView(path: path, maxPixel: 160)
    }

    /// Rich card rendering for URL items once `LinkMetadataService` has
    /// resolved the OG metadata. Falls back to a plain URL line when the
    /// title isn't available yet so the row never looks empty.
    @ViewBuilder
    private func linkPreviewCard(preview: LinkPreview, fallbackText: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let imagePath = preview.imagePath {
                ThumbnailImageView(path: imagePath, maxPixel: 96)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(preview.title ?? fallbackText)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .foregroundColor(.primary)
                HStack(spacing: 4) {
                    if let iconPath = preview.iconPath {
                        ThumbnailImageView(path: iconPath, maxPixel: 32)
                            .frame(width: 12, height: 12)
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    }
                    Text(preview.domain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
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
        // Close the popover before showing Quick Look. The popover sits on
        // top of the QLPreviewPanel and steals first-responder, so without
        // dismissing it the preview either appears behind the popover or
        // can't receive its own keyboard shortcuts (Space, arrows).
        AppDelegate.shared?.popover.close()
        DispatchQueue.main.async {
            ImageQuickPreview.shared.toggle(path: path)
        }
    }

    /// Ask Seeker (com.marvel.Seeker) to reveal the on-disk PNG. Delegates
    /// to the shared implementation in `UrlActions` so the integration only
    /// has one source of truth.
    fileprivate static func revealInSeeker(path: String) {
        UrlActions.revealInSeeker(path: path)
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
            AnnotationWindowController.shared.present(image: image, savedPath: path)
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
