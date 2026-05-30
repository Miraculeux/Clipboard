import Foundation
import AppKit
import Combine
import Carbon.HIToolbox
import CryptoKit

class ClipboardManager: ObservableObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = ClipboardManager()

    @Published var history: [ClipboardItem] = []
    @Published var searchText: String = ""
    @Published var selectedCategory: HistoryCategory = .clipboard
    /// Secondary filter applied on top of `selectedCategory == .clipboard`.
    /// Lets the user narrow the clipboard tab down to text / links / files
    /// / colors without changing what's tracked.
    @Published var selectedTypeFilter: TypeFilter = .all
    /// Item currently highlighted by keyboard navigation in the popover.
    @Published var keyboardSelectedID: ClipboardItem.ID?
    /// Cached, debounced filtered view of `history`. Recomputed only when
    /// `history`, `searchText`, or `selectedCategory` actually changes
    /// (debounced for typing).
    @Published private(set) var filteredHistory: [ClipboardItem] = []

    /// User-managed snippet library. Independent of `history` — never
    /// auto-captured, never trimmed.
    @Published var snippets: [Snippet] = []
    /// Cached, debounced filtered view of `snippets`.
    @Published private(set) var filteredSnippets: [Snippet] = []
    /// Snippet highlighted by keyboard navigation while the Snippets tab is
    /// active in the popover.
    @Published var keyboardSelectedSnippetID: Snippet.ID?

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general
    private let settings = SettingsManager.shared

    // Cached pasteboard type constants (avoid reconstructing each tick).
    private static let fileURLType = NSPasteboard.PasteboardType("public.file-url")
    private static let multiFileType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    // Background save: coalesce rapid mutations into one write.
    private let saveQueue = DispatchQueue(label: "ClipboardKit.save", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private static let saveDebounce: TimeInterval = 0.5

    private var filterCancellable: AnyCancellable?
    private var snippetFilterCancellable: AnyCancellable?

    /// SQLite-backed history persistence. Replaces the previous
    /// `history.json` blob. Reads/writes happen on the store's internal
    /// queue; we just hand it snapshots.
    private let store = HistoryStore.shared
    /// Snippet library persistence.
    private let snippetStore = SnippetStore.shared
    private var pendingSnippetSave: DispatchWorkItem?

    private init() {
        lastChangeCount = pasteboard.changeCount
        setupFilterPipeline()
        loadHistoryAsync()
        loadSnippetsAsync()
    }

    // Threshold above which a text item's full body is stored on disk and only
    // a preview is kept in `textContent`. Avoids ballooning history.json and
    // keeping multi-MB strings resident in memory.
    private static let largeTextThresholdBytes = 256 * 1024 // 256 KB UTF-8

    // MARK: - Monitoring

    /// The pasteboard server posts this Darwin notification every time the
    /// general pasteboard mutates. Subscribing to it is essentially free
    /// (the kernel wakes us only when there's actually a change), and
    /// replaces the previous ~2 Hz polling timer.
    private static let pasteboardDarwinChangeName = "com.apple.pasteboard.notify.changed"

    func startMonitoring() {
        // Pick up anything already on the pasteboard at launch.
        checkClipboard()

        // Register a Darwin notification observer. The CFNotificationCallback
        // is a C function pointer — we can't capture `self` inside it, so we
        // pass an opaque pointer to `self` as the observer key and bounce
        // through a static trampoline that hops to the main queue.
        let observerPtr = Unmanaged.passUnretained(self).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            observerPtr,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let manager = Unmanaged<ClipboardManager>.fromOpaque(observer).takeUnretainedValue()
                // The Darwin callback runs on a CF runloop thread; trampoline
                // to main where the rest of the manager already lives.
                DispatchQueue.main.async { manager.checkClipboard() }
            },
            Self.pasteboardDarwinChangeName as CFString,
            nil,
            .deliverImmediately
        )

        // Safety-net poller in case the Darwin notification ever fails to
        // deliver (e.g. some sleep / wake races). 3 s with 1.5 s tolerance
        // gives ~0.2 wake-ups/sec — negligible CPU/battery cost compared to
        // the previous 0.6 s interval.
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        t.tolerance = 1.5
        timer = t
    }

    func stopMonitoring() {
        let observerPtr = Unmanaged.passUnretained(self).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(
            center,
            observerPtr,
            CFNotificationName(Self.pasteboardDarwinChangeName as CFString),
            nil
        )
        timer?.invalidate()
        timer = nil
        flushPendingSave()
    }

    private func checkClipboard() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // NSPasteboard isn't documented as thread-safe — keep all reads on the
        // main thread (we're already here, called from a Timer). Heavy work
        // like image encoding and disk I/O is dispatched to background queues
        // by the individual branches in `captureClipboard`.
        captureClipboard()
    }

    private func captureClipboard() {
        // Snapshot the frontmost app *now*, before any async hop: by the time
        // a background queue gets to assemble the item the user may have
        // switched focus, and we want the app they were *in* when they hit
        // ⌘C. Filter ourselves out so a paste-loop / restore-snapshot can't
        // mislabel an item as coming from ClipboardKit.
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ourBundle = Bundle.main.bundleIdentifier
        let sourceBundleID: String? = (frontBundle == ourBundle) ? nil : frontBundle

        // Check for file URLs first (Finder copy)
        // Files are detected via the pasteboard types that Finder sets
        let hasFiles = pasteboard.types?.contains(where: { $0 == Self.fileURLType || $0 == Self.multiFileType }) ?? false

        if hasFiles {
            var filePaths: [String] = []

            // Try reading filenames from the legacy plist-based type
            if let data = pasteboard.data(forType: Self.multiFileType),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let paths = plist as? [String] {
                filePaths = paths
            }

            // Fallback: read via NSURL
            if filePaths.isEmpty,
               let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                filePaths = urls.map { $0.path }
            }

            if !filePaths.isEmpty {
                // `attributesOfItem` is a syscall per file; do the size sum
                // off-main and assemble the item from the background.
                let captured = filePaths
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let totalSize = captured.reduce(0) { acc, path in
                        acc + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
                    }
                    let item = ClipboardItem(
                        id: UUID(),
                        timestamp: Date(),
                        contentType: .fileURL,
                        textContent: captured.joined(separator: "\n"),
                        fileName: nil,
                        filePaths: captured,
                        originalSize: totalSize,
                        sourceBundleID: sourceBundleID
                    )
                    self?.addItem(item)
                }
                return
            }
        }

        // Image: read on main (NSPasteboard isn't thread-safe), then hand the
        // raw Data off to a background queue for PNG encode + disk write.
        // Prefer the source's PNG when available; fall back to TIFF.
        let pngData = pasteboard.data(forType: .png)
        let tiffData = pngData == nil ? pasteboard.data(forType: .tiff) : nil
        if let imageData = pngData ?? tiffData {
            let isAlreadyPNG = pngData != nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let item = self.saveImageItem(data: imageData, isAlreadyPNG: isAlreadyPNG, sourceBundleID: sourceBundleID)
                self.addItem(item)
            }
            return
        }

        // Rich text: read on main, offload large-text disk write to background.
        if let rtfData = pasteboard.data(forType: .rtf),
           let attrString = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            let plainText = attrString.string
            let originalSize = rtfData.count
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                // Always persist the RTF blob to a sidecar so "paste rich"
                // can replay the original formatting later. The plain-text
                // preview lives inline on the item for quick display.
                let sidecarPath = self.writeRTFSidecar(rtfData)
                let preview = self.previewText(plainText)
                let item = ClipboardItem(
                    id: UUID(),
                    timestamp: Date(),
                    contentType: .richText,
                    textContent: preview,
                    fileName: sidecarPath,
                    filePaths: nil,
                    originalSize: originalSize,
                    sourceBundleID: sourceBundleID
                )
                self.addItem(item)
            }
            return
        }

        // Plain text
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let originalSize = text.utf8.count
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let (preview, sidecar) = self.offloadLargeTextIfNeeded(text)
                let item = ClipboardItem(
                    id: UUID(),
                    timestamp: Date(),
                    contentType: .text,
                    textContent: preview,
                    fileName: sidecar,
                    filePaths: nil,
                    originalSize: originalSize,
                    sourceBundleID: sourceBundleID
                )
                self.addItem(item)
            }
            return
        }
    }

    /// If `text` exceeds the large-text threshold, write the full body to a
    /// sidecar file and return only a short preview to keep in memory/JSON.
    /// Returns `(textContent, sidecarPath)` ready to drop into a `ClipboardItem`.
    private func offloadLargeTextIfNeeded(_ text: String) -> (String, String?) {
        let utf8Count = text.utf8.count
        guard utf8Count > Self.largeTextThresholdBytes else {
            return (text, nil)
        }
        // SettingsManager creates the storage dir at startup and on path
        // changes — don't repeat the syscall on every capture.
        let storagePath = settings.largeFileStoragePath
        let dirURL = URL(fileURLWithPath: storagePath)
        let fileURL = dirURL.appendingPathComponent(UUID().uuidString + ".txt")
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Fall back to keeping the full text in memory if we can't write.
            return (text, nil)
        }
        return (previewText(text), fileURL.path)
    }

    /// Cap a string to a safe inline preview without splitting UTF-8.
    private func previewText(_ text: String) -> String {
        let previewChars = min(text.count, 4_000)
        if text.count <= previewChars { return text }
        return String(text.prefix(previewChars))
            + "\n…(truncated, full content stored on disk)"
    }

    /// Persist captured RTF data to a sidecar `.rtf` file so the history can
    /// later replay rich-text pastes (preserving fonts, colors, links, etc.).
    private func writeRTFSidecar(_ data: Data) -> String? {
        let storagePath = settings.largeFileStoragePath
        let dirURL = URL(fileURLWithPath: storagePath)
        let fileURL = dirURL.appendingPathComponent(UUID().uuidString + ".rtf")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            print("ClipboardManager: failed to write RTF sidecar — \(error.localizedDescription)")
            return nil
        }
    }

    private func saveImageItem(data: Data, isAlreadyPNG: Bool, sourceBundleID: String? = nil) -> ClipboardItem {
        let fileName = UUID().uuidString + ".png"

        // Always store images in the user-chosen storage location.
        // SettingsManager creates the directory at startup and whenever the
        // user changes the path, so we don't pay a syscall here per capture.
        let storagePath = settings.largeFileStoragePath
        let dirURL = URL(fileURLWithPath: storagePath)

        let fileURL = dirURL.appendingPathComponent(fileName)

        if isAlreadyPNG {
            // Source pasteboard payload is already PNG — write it through
            // verbatim. This avoids a costly decode + re-encode pass that for
            // a 4K screenshot can run 30–100ms of pure CPU work.
            try? data.write(to: fileURL)
        } else if let bitmapRep = NSBitmapImageRep(data: data),
                  let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            // TIFF → PNG conversion path.
            try? pngData.write(to: fileURL)
        } else {
            try? data.write(to: fileURL)
        }

        // Cheap hex SHA256 of the raw pasteboard payload. Used downstream
        // by the dedupe path to recognize "the same screenshot copied
        // twice" without re-reading the file from disk.
        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        return ClipboardItem(
            id: UUID(),
            timestamp: Date(),
            contentType: .image,
            textContent: nil,
            fileName: fileURL.path,
            filePaths: nil,
            originalSize: data.count,
            sourceBundleID: sourceBundleID,
            contentHash: hash
        )
    }

    // MARK: - History Management

    // MARK: - Drag-in / drop import
    //
    // These mirror the pasteboard-handling paths above but accept payloads
    // that came from a SwiftUI `.onDrop`. They intentionally don't write to
    // `NSPasteboard.general` — the user dragged something into the popover
    // because they want it in *history*, not on the system clipboard.

    /// Import file URLs that were dropped onto the popover. Each invocation
    /// produces one `.fileURL` history item (matching how the system
    /// pasteboard groups multi-file selections).
    func importDroppedFiles(paths: [String]) {
        let captured = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !captured.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let totalSize = captured.reduce(0) { acc, path in
                acc + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
            }
            let item = ClipboardItem(
                id: UUID(),
                timestamp: Date(),
                contentType: .fileURL,
                textContent: captured.joined(separator: "\n"),
                fileName: nil,
                filePaths: captured,
                originalSize: totalSize
            )
            self?.addItem(item)
        }
    }

    /// Import raw image data dropped from another app (e.g. a browser).
    func importDroppedImage(data: Data, isPNG: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let item = self.saveImageItem(data: data, isAlreadyPNG: isPNG)
            self.addItem(item)
        }
    }

    /// Import plain text dropped onto the popover.
    func importDroppedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let (preview, sidecar) = offloadLargeTextIfNeeded(text)
        let item = ClipboardItem(
            id: UUID(),
            timestamp: Date(),
            contentType: .text,
            textContent: preview,
            fileName: sidecar,
            filePaths: nil,
            originalSize: text.utf8.count
        )
        addItem(item)
    }

    private func addItem(_ item: ClipboardItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Dedupe across the WHOLE history (not just the immediately
            // previous row): re-copying an item that's already there should
            // float the existing version up rather than leaving the old row
            // dangling. The user can turn this off in Settings if they need
            // a strict append-only history (e.g. for audit purposes).
            //
            // Pinned items are exempt from removal — we silently skip the
            // insert so the user's curated pin doesn't get replaced with a
            // fresh, unpinned copy of itself.
            if self.settings.deduplicateEntries, let matcher = Self.duplicateMatcher(for: item) {
                if let existing = self.history.first(where: matcher), existing.isPinned {
                    return
                }
                // Cleanup any sidecar files on removed duplicates so we don't
                // leak orphans on disk (image PNGs especially).
                for dup in self.history where matcher(dup) {
                    Self.cleanupFileSync(for: dup)
                }
                self.history.removeAll(where: matcher)
            }

            // The new item we'll actually insert. We may augment it with a
            // link preview carried over from a removed duplicate so the user
            // doesn't see the fancy card flicker back to a plain URL row
            // every time they re-copy the same link.
            var inserted = item
            if inserted.contentType == .text,
               let text = inserted.textContent,
               let url = LinkMetadataService.detectURL(in: text) {
                // Look for any other item that already cached a preview for
                // exactly this URL string. This survives the dedup-removeAll
                // above because the lookup happens before re-inserting.
                if let cached = self.history.first(where: {
                    $0.linkPreview?.url == url.absoluteString
                })?.linkPreview {
                    inserted.linkPreview = cached
                } else {
                    // Kick off an async fetch; the result is patched into the
                    // item in place once it arrives. Only the URL is
                    // captured so no retain cycle through the item itself.
                    let pendingID = inserted.id
                    LinkMetadataService.shared.fetch(url: url) { [weak self] preview in
                        self?.applyLinkPreview(itemID: pendingID, preview: preview)
                    }
                }
            }

            // Insert the fresh item right below the pinned section so pins
            // stay at the very top of the list.
            let pinnedCount = self.history.prefix(while: { $0.isPinned }).count
            self.history.insert(inserted, at: pinnedCount)

            // Trim to max count, but never evict pinned items. Pinned items
            // also don't count toward the cap so users can stockpile
            // long-lived snippets without losing fresh history.
            let unpinnedCount = self.history.lazy.filter { !$0.isPinned }.count
            var toRemove = max(0, unpinnedCount - self.settings.maxHistoryCount)
            if toRemove > 0 {
                var i = self.history.count - 1
                while i >= 0 && toRemove > 0 {
                    if !self.history[i].isPinned {
                        let removed = self.history.remove(at: i)
                        self.cleanupFile(for: removed)
                        toRemove -= 1
                    }
                    i -= 1
                }
            }

            self.scheduleSave()
        }
    }

    /// Patch the link preview onto an existing history item by ID, then
    /// persist. No-op if the item was already removed (evicted by max-history
    /// trim or deleted by the user) by the time the fetch returns.
    private func applyLinkPreview(itemID: ClipboardItem.ID, preview: LinkPreview) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let idx = self.history.firstIndex(where: { $0.id == itemID }) else { return }
            var updated = self.history[idx]
            updated.linkPreview = preview
            self.history[idx] = updated
            self.scheduleSave()
        }
    }

    func pasteItem(_ item: ClipboardItem, asPlainText: Bool = false) {
        pasteItem(item, transform: asPlainText ? .plainText : .none)
    }

    /// Paste `item` into the previously-focused app, optionally rewriting any
    /// text payload before it hits the pasteboard. Image and file items
    /// ignore the transform.
    func pasteItem(_ item: ClipboardItem, transform: PasteTransform) {
        // `alwaysPastePlainText` is a settings-level baseline; an explicit
        // `.none` from a caller is upgraded to `.plainText` so the global
        // toggle still wins. `.trimmed` already implies plain text.
        let effective: PasteTransform = {
            if transform != .none { return transform }
            return settings.alwaysPastePlainText ? .plainText : .none
        }()
        let forcePlain = effective.forcesPlainText
        // Snapshot what the user had on the clipboard BEFORE we overwrite it
        // with our own payload. If `restoreClipboardAfterPaste` is on we put
        // these contents back after the simulated paste, so the user's
        // previous clipboard survives. Captured once here so every async
        // branch below ends up restoring the same baseline.
        let restoreSnapshot: PasteboardSnapshot? =
            settings.restoreClipboardAfterPaste ? snapshotPasteboard() : nil

        // Image paste: read large data off the main thread to avoid UI hitches.
        if item.contentType == .image, let fileName = item.fileName {
            let url = URL(fileURLWithPath: fileName)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let data = try? Data(contentsOf: url)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let data = data {
                        self.pasteboard.clearContents()
                        self.pasteboard.setData(data, forType: .png)
                    }
                    self.finalizePasteAndSimulate(restore: restoreSnapshot)
                }
            }
            return
        }

        // Rich text: prefer RTF sidecar so receivers get formatted output.
        // When `forcePlain`, write only the plain string.
        if item.contentType == .richText, let sidecarPath = item.fileName {
            let url = URL(fileURLWithPath: sidecarPath)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if sidecarPath.hasSuffix(".rtf"),
                   let rtfData = try? Data(contentsOf: url) {
                    let plain = effective.apply(
                        NSAttributedString(rtf: rtfData, documentAttributes: nil)?
                            .string ?? (item.textContent ?? "")
                    )
                    DispatchQueue.main.async {
                        self.pasteboard.clearContents()
                        if forcePlain {
                            self.pasteboard.setString(plain, forType: .string)
                        } else {
                            self.pasteboard.setData(rtfData, forType: .rtf)
                            self.pasteboard.setString(plain, forType: .string)
                        }
                        self.finalizePasteAndSimulate(restore: restoreSnapshot)
                    }
                    return
                }
                // Legacy .txt sidecar — only the plain body remains on disk.
                let plain = effective.apply(
                    (try? String(contentsOf: url, encoding: .utf8))
                        ?? (item.textContent ?? "")
                )
                DispatchQueue.main.async {
                    self.pasteboard.clearContents()
                    self.pasteboard.setString(plain, forType: .string)
                    self.finalizePasteAndSimulate(restore: restoreSnapshot)
                }
            }
            return
        }

        // Large-text paste: full body lives on disk; read it in the background.
        if item.contentType == .text, let sidecar = item.fileName {
            let url = URL(fileURLWithPath: sidecar)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let fullText = effective.apply(
                    (try? String(contentsOf: url, encoding: .utf8)) ?? (item.textContent ?? "")
                )
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.pasteboard.clearContents()
                    self.pasteboard.setString(fullText, forType: .string)
                    self.finalizePasteAndSimulate(restore: restoreSnapshot)
                }
            }
            return
        }

        // Synchronous (fast) paths.
        switch item.contentType {
        case .text, .richText:
            pasteboard.clearContents()
            pasteboard.setString(effective.apply(item.textContent ?? ""), forType: .string)
        case .image:
            break // handled above
        case .fileURL:
            if let paths = item.filePaths, !paths.isEmpty {
                pasteboard.clearContents()
                let urls = paths.compactMap { NSURL(fileURLWithPath: $0) }
                pasteboard.writeObjects(urls)
            } else if let path = item.textContent {
                pasteboard.clearContents()
                pasteboard.writeObjects([NSURL(fileURLWithPath: path)])
            }
        }

        finalizePasteAndSimulate(restore: restoreSnapshot)
    }

    private func finalizePasteAndSimulate(restore: PasteboardSnapshot? = nil) {
        lastChangeCount = pasteboard.changeCount
        AppDelegate.shared.closePopoverAndRestoreFocus { [weak self] in
            self?.simulatePaste()
            // Brief visual confirmation near the menu bar — feedback that
            // the paste actually fired (the user just lost the popover, so
            // a silent action looks like a no-op).
            DispatchQueue.main.async {
                ToastCenter.shared.show("Pasted")
            }
            // Restore the snapshotted clipboard after a brief delay — long
            // enough for the receiving app to actually consume the paste
            // event. Without the delay, some apps (e.g. Slack web) read the
            // pasteboard from a deferred handler and end up with the restored
            // baseline instead of our payload.
            if let snap = restore {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self?.restorePasteboard(snap)
                }
            }
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode = CGKeyCode(UInt16(kVK_ANSI_V))
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)

        keyDown?.flags = CGEventFlags.maskCommand
        keyUp?.flags = CGEventFlags.maskCommand

        keyDown?.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp?.post(tap: CGEventTapLocation.cghidEventTap)
    }

    // MARK: - Pasteboard snapshot / restore

    /// Full-fidelity copy of every item on `NSPasteboard.general`. We capture
    /// the raw `Data` for every declared type so we can reproduce the same
    /// content (images, file URLs, RTF, custom flavors, …) bit-for-bit when
    /// restoring after a paste.
    struct PasteboardSnapshot {
        let entries: [[NSPasteboard.PasteboardType: Data]]
    }

    private func snapshotPasteboard() -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        var entries: [[NSPasteboard.PasteboardType: Data]] = []
        entries.reserveCapacity(items.count)
        for item in items {
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type] = data
                }
            }
            if !map.isEmpty { entries.append(map) }
        }
        return entries.isEmpty ? nil : PasteboardSnapshot(entries: entries)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(snapshot.entries.count)
        for map in snapshot.entries {
            let pbItem = NSPasteboardItem()
            for (type, data) in map {
                pbItem.setData(data, forType: type)
            }
            items.append(pbItem)
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        // Bump our high-water mark so the monitor doesn't treat the restore
        // as a fresh user-driven copy and re-ingest it.
        lastChangeCount = pasteboard.changeCount
    }

    func deleteItem(_ item: ClipboardItem) {
        history.removeAll { $0.id == item.id }
        cleanupFile(for: item)
        scheduleSave()
    }

    func clearHistory() {
        let snapshot = history
        history.removeAll()
        // Drop the file deletes off the main thread.
        DispatchQueue.global(qos: .utility).async {
            for item in snapshot {
                Self.cleanupFileSync(for: item)
            }
        }
        scheduleSave()
    }

    /// Toggle the pinned state on `item`. Pinned items move to the top of
    /// the list (in pin-toggle order), survive across launches, and are
    /// exempt from the max-history trim. Unpinning drops the item to the top
    /// of the unpinned section so the user can see what they just released.
    func togglePin(_ item: ClipboardItem) {
        guard let index = history.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = history[index]
        updated.isPinned.toggle()
        history.remove(at: index)
        if updated.isPinned {
            // Insert at the top of the pinned section so most-recently pinned
            // bubbles up to the absolute top.
            history.insert(updated, at: 0)
        } else {
            // Drop the now-unpinned item right after the pinned section.
            let pinnedCount = history.prefix(while: { $0.isPinned }).count
            history.insert(updated, at: pinnedCount)
        }
        scheduleSave()
    }

    /// Legacy alias kept for callers that don't yet pass through the toggle.
    /// Pins the item if it isn't already pinned, otherwise re-asserts its
    /// position at the top of the pin section.
    func pinItem(_ item: ClipboardItem) {
        if let existing = history.first(where: { $0.id == item.id }), existing.isPinned {
            // Already pinned — move to top of pin section.
            if let idx = history.firstIndex(where: { $0.id == item.id }) {
                let removed = history.remove(at: idx)
                history.insert(removed, at: 0)
                scheduleSave()
            }
            return
        }
        togglePin(item)
    }

    private func cleanupFile(for item: ClipboardItem) {
        if let fileName = item.fileName {
            ThumbnailCache.shared.invalidate(path: fileName)
        }
        DispatchQueue.global(qos: .utility).async {
            Self.cleanupFileSync(for: item)
        }
    }

    private static func cleanupFileSync(for item: ClipboardItem) {
        if let fileName = item.fileName {
            try? FileManager.default.removeItem(atPath: fileName)
        }
    }

    /// Build the predicate used to find existing rows that should collapse
    /// into a newly-captured `incoming`. Returns `nil` for items that we
    /// don't dedupe (e.g. an image without a hash, which would be a coding
    /// bug — better to leave it alone than to collapse unrelated rows).
    ///
    /// Returning a free-standing closure keeps the dedup logic in one place
    /// and lets the caller use it for both the "is the existing row pinned?"
    /// lookup and the actual `removeAll`.
    private static func duplicateMatcher(for incoming: ClipboardItem) -> ((ClipboardItem) -> Bool)? {
        switch incoming.contentType {
        case .fileURL:
            guard let paths = incoming.filePaths else { return nil }
            let count = paths.count
            return { existing in
                existing.contentType == .fileURL
                    && (existing.filePaths?.count ?? -1) == count
                    && existing.filePaths == paths
            }
        case .image:
            // Image dedupe requires the SHA256 we computed at capture time.
            // Without it we'd be guessing — bail.
            guard let hash = incoming.contentHash else { return nil }
            return { existing in
                existing.contentType == .image && existing.contentHash == hash
            }
        case .text, .richText:
            guard let text = incoming.textContent else { return nil }
            let size = incoming.originalSize
            let type = incoming.contentType
            return { existing in
                existing.contentType == type
                    && existing.originalSize == size
                    && existing.textContent == text
            }
        }
    }

    // MARK: - Persistence (debounced, off-main)

    /// Coalesce many rapid mutations into a single background write.
    /// Snapshot the array on the main thread (cheap COW reference); the
    /// background work item just hands it to `HistoryStore`, which does the
    /// SQLite write in a single transaction.
    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = history
        let work = DispatchWorkItem { [store] in
            store.replaceAll(snapshot)
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// Force any pending write to complete synchronously (e.g. on terminate).
    /// Runs the write on the save queue so we don't tie up the main thread
    /// with the SQLite work and we serialize cleanly against any in-flight
    /// save the queue had already started.
    private func flushPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = history
        saveQueue.sync { [store] in
            store.replaceAll(snapshot)
        }
    }

    private func loadHistoryAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // One-time migration from the old history.json into SQLite, if
            // present. The store hands us back the imported items so we can
            // populate memory directly without a second read.
            let imported = self.store.migrateLegacyJSONIfNeeded()
            let items = imported ?? self.store.loadAll()
            guard !items.isEmpty else { return }
            DispatchQueue.main.async {
                if self.history.isEmpty {
                    self.history = items
                } else {
                    // Anything captured while we were loading is newer than
                    // what's on disk; keep it on top and append the historic
                    // items below, dropping duplicates by id.
                    let existingIDs = Set(self.history.map { $0.id })
                    let merged = self.history + items.filter { !existingIDs.contains($0.id) }
                    self.history = merged
                }
            }
        }
    }

    // MARK: - Filtered history pipeline

    private func setupFilterPipeline() {
        // Initial value
        filteredHistory = history
        let historyStream = $history
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
        let queryStream = $searchText
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .removeDuplicates()
        let categoryStream = $selectedCategory
            .removeDuplicates()
        let typeStream = $selectedTypeFilter
            .removeDuplicates()

        filterCancellable = Publishers.CombineLatest4(historyStream, queryStream, categoryStream, typeStream)
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { history, query, category, typeFilter -> [ClipboardItem] in
                // The snippets tab uses a different model; skip the history
                // filter entirely when it's selected so we don't waste work.
                guard category != .snippets else { return [] }
                let categoryFiltered: [ClipboardItem]
                switch category {
                case .clipboard:
                    // Apply the chip filter only on the clipboard tab. The
                    // screenshots tab is all-images by definition; further
                    // narrowing would just yield "all or nothing".
                    let base = history.filter { $0.contentType != .image }
                    categoryFiltered = typeFilter == .all
                        ? base
                        : base.filter { typeFilter.matches($0) }
                case .screenshots:
                    categoryFiltered = history.filter { $0.contentType == .image }
                case .snippets:
                    categoryFiltered = []
                }
                guard !query.isEmpty else { return categoryFiltered }
                return categoryFiltered.filter {
                    $0.displayText.range(of: query, options: .caseInsensitive) != nil
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: \.filteredHistory, on: self)

        // Parallel pipeline for the snippet library: only the search field is
        // shared with the history view, so reuse `$searchText`. Filtering is
        // cheap (snippet counts are tens, not thousands) — debounce only the
        // query to match keystroke pacing.
        let snippetStream = $snippets
            .debounce(for: .milliseconds(40), scheduler: DispatchQueue.main)

        snippetFilterCancellable = Publishers.CombineLatest(snippetStream, queryStream)
            .map { snippets, query -> [Snippet] in
                guard !query.isEmpty else { return snippets }
                return snippets.filter {
                    $0.displayTitle.range(of: query, options: .caseInsensitive) != nil
                        || $0.content.range(of: query, options: .caseInsensitive) != nil
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: \.filteredSnippets, on: self)
    }

    // MARK: - Snippet library

    private func loadSnippetsAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let loaded = self.snippetStore.loadAll()
            guard !loaded.isEmpty else { return }
            DispatchQueue.main.async {
                self.snippets = loaded
            }
        }
    }

    func addSnippet(_ snippet: Snippet) {
        snippets.insert(snippet, at: 0)
        snippetStore.saveAll(snippets)
    }

    func updateSnippet(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.updatedAt = Date()
        snippets[idx] = updated
        snippetStore.saveAll(snippets)
    }

    func deleteSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        snippetStore.saveAll(snippets)
    }

    /// Promote a history item into the snippet library. Image and file items
    /// are ignored — there's no useful text body to promote.
    func saveItemAsSnippet(_ item: ClipboardItem) {
        switch item.contentType {
        case .text, .richText:
            let body = item.textContent ?? ""
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            addSnippet(Snippet(title: "", content: body))
        case .image, .fileURL:
            return
        }
    }

    /// Paste a snippet just like a text history item. The snippet model
    /// never has a sidecar or rich format, so the path is much simpler than
    /// `pasteItem(_:transform:)`. Template placeholders (`{date}`,
    /// `{clipboard}`, …) are expanded *before* the transform so case rules
    /// apply to the final rendered string.
    func pasteSnippet(_ snippet: Snippet, transform: PasteTransform = .none) {
        let effective: PasteTransform = {
            if transform != .none { return transform }
            return settings.alwaysPastePlainText ? .plainText : .none
        }()
        let expanded = SnippetExpander.expand(snippet.content)
        let body = effective.apply(expanded)
        let restoreSnapshot: PasteboardSnapshot? =
            settings.restoreClipboardAfterPaste ? snapshotPasteboard() : nil
        pasteboard.clearContents()
        pasteboard.setString(body, forType: .string)
        finalizePasteAndSimulate(restore: restoreSnapshot)
    }
}

/// Per-paste rewrite applied to text payloads. `none` is the default;
/// `plainText` strips any RTF and writes only `public.utf8-plain-text`;
/// `trimmed` is `plainText` plus a leading/trailing whitespace trim; the
/// case-changing variants also imply plain text (formatting can't survive
/// a string-level rewrite cleanly).
enum PasteTransform: Sendable, Equatable, CaseIterable {
    case none
    case plainText
    case trimmed
    case lowercase
    case uppercase
    case titleCase

    /// `true` when the receiver should be denied rich-text formatting.
    var forcesPlainText: Bool { self != .none }

    /// Human-readable label for menus / settings.
    var displayName: String {
        switch self {
        case .none:      return "Paste"
        case .plainText: return "Paste as Plain Text"
        case .trimmed:   return "Paste Trimmed"
        case .lowercase: return "Paste as lowercase"
        case .uppercase: return "Paste as UPPERCASE"
        case .titleCase: return "Paste as Title Case"
        }
    }

    /// Rewrite the text body about to be placed on the pasteboard.
    func apply(_ text: String) -> String {
        switch self {
        case .none, .plainText:
            return text
        case .trimmed:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .lowercase:
            return text.lowercased()
        case .uppercase:
            return text.uppercased()
        case .titleCase:
            // Foundation's `.capitalized` lowercases the rest of each word
            // and uppercases the first letter, locale-aware. Good enough for
            // a one-shot transform; users wanting AP / Chicago style can
            // post-edit.
            return text.capitalized
        }
    }

    /// Map `NSEvent.modifierFlags` to a transform. Used by click / Return
    /// handlers in the popover so the user can shape the paste at the
    /// moment of action.
    ///
    /// - `⌥` (Option)               → `.plainText`
    /// - `⇧` (Shift)                → `.trimmed`
    /// - `⌃` (Control)              → `.lowercase`
    /// - `⌃⇧` (Control+Shift)       → `.uppercase`
    /// - `⌃⌥` (Control+Option)      → `.titleCase`
    /// - Any other combination falls back to `.none`.
    static func from(modifiers: NSEvent.ModifierFlags) -> PasteTransform {
        let m = modifiers.intersection(.deviceIndependentFlagsMask)
        // ⌘ is always present on a paste action when invoked via ⌘+digit /
        // ⌘+Return — strip it before pattern-matching so the caller doesn't
        // have to mask it themselves.
        let mods = m.subtracting(.command)
        if mods == [.control, .shift]  { return .uppercase }
        if mods == [.control, .option] { return .titleCase }
        if mods == .control            { return .lowercase }
        if mods == .shift              { return .trimmed }
        if mods == .option             { return .plainText }
        return .none
    }
}

/// Top-level segmentation surfaced in the history popover.
/// `.clipboard` shows text/rich-text/file items; `.screenshots` shows images;
/// `.snippets` shows the user's curated snippet library.
enum HistoryCategory: String, CaseIterable, Identifiable {
    case clipboard
    case screenshots
    case snippets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .screenshots: return "Screenshots"
        case .snippets: return "Snippets"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .screenshots: return "photo"
        case .snippets: return "text.badge.star"
        }
    }
}

/// Secondary type chip applied to the clipboard tab. `.all` is the default
/// and short-circuits the filter; the others narrow by surface heuristics
/// (URL detector, color regex, type tag, etc.).
enum TypeFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case link
    case file
    case color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:   return "All"
        case .text:  return "Text"
        case .link:  return "Link"
        case .file:  return "File"
        case .color: return "Color"
        }
    }

    var symbol: String {
        switch self {
        case .all:   return "tray.full"
        case .text:  return "doc.text"
        case .link:  return "link"
        case .file:  return "folder"
        case .color: return "paintpalette"
        }
    }

    /// `true` if `item` belongs in the chip's filtered slice.
    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            return true
        case .text:
            // Plain or rich text that *isn't* obviously a URL/color — those
            // get their own chips and would otherwise show up in both.
            guard item.contentType == .text || item.contentType == .richText else { return false }
            let body = item.textContent ?? ""
            return !Self.isLink(body) && !Self.isColor(body)
        case .link:
            guard item.contentType == .text || item.contentType == .richText else { return false }
            return Self.isLink(item.textContent ?? "")
        case .file:
            return item.contentType == .fileURL
        case .color:
            guard item.contentType == .text || item.contentType == .richText else { return false }
            return Self.isColor(item.textContent ?? "")
        }
    }

    private static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("\n") else { return false }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "mailto", "tel", "file"].contains(scheme) {
            return true
        }
        // Bare host like "github.com/x" — must contain a dot, no spaces, and
        // look at least vaguely TLD-shaped.
        if trimmed.contains(".") && !trimmed.contains("/.") {
            let components = trimmed.split(separator: ".")
            if let tld = components.last, tld.count >= 2 && tld.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return components.count >= 2
            }
        }
        return false
    }

    /// Conservative color literal detector: `#RGB`, `#RGBA`, `#RRGGBB`,
    /// `#RRGGBBAA`, `rgb(...)`, `rgba(...)`, `hsl(...)`, `hsla(...)`. The
    /// whole trimmed string must be the color — embedding one inside prose
    /// doesn't qualify.
    private static func isColor(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.count <= 64 else { return false }
        if s.hasPrefix("#") {
            let hex = s.dropFirst()
            guard [3, 4, 6, 8].contains(hex.count) else { return false }
            return hex.allSatisfy { $0.isHexDigit }
        }
        if s.hasPrefix("rgb(") || s.hasPrefix("rgba(") || s.hasPrefix("hsl(") || s.hasPrefix("hsla(") {
            return s.hasSuffix(")")
        }
        return false
    }
}
