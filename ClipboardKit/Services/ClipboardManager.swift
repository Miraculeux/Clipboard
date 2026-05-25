import Foundation
import AppKit
import Combine
import Carbon.HIToolbox

class ClipboardManager: ObservableObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = ClipboardManager()

    @Published var history: [ClipboardItem] = []
    @Published var searchText: String = ""
    @Published var selectedCategory: HistoryCategory = .clipboard
    /// Item currently highlighted by keyboard navigation in the popover.
    @Published var keyboardSelectedID: ClipboardItem.ID?
    /// Cached, debounced filtered view of `history`. Recomputed only when
    /// `history`, `searchText`, or `selectedCategory` actually changes
    /// (debounced for typing).
    @Published private(set) var filteredHistory: [ClipboardItem] = []

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

    /// SQLite-backed history persistence. Replaces the previous
    /// `history.json` blob. Reads/writes happen on the store's internal
    /// queue; we just hand it snapshots.
    private let store = HistoryStore.shared

    private init() {
        lastChangeCount = pasteboard.changeCount
        setupFilterPipeline()
        loadHistoryAsync()
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
                        originalSize: totalSize
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
                let item = self.saveImageItem(data: imageData, isAlreadyPNG: isAlreadyPNG)
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
                    originalSize: originalSize
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
                    originalSize: originalSize
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

    private func saveImageItem(data: Data, isAlreadyPNG: Bool) -> ClipboardItem {
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

        return ClipboardItem(
            id: UUID(),
            timestamp: Date(),
            contentType: .image,
            textContent: nil,
            fileName: fileURL.path,
            filePaths: nil,
            originalSize: data.count
        )
    }

    // MARK: - History Management

    private func addItem(_ item: ClipboardItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Remove duplicate. Short-circuit on `originalSize` (cheap Int compare)
            // before doing the potentially expensive String/Array equality.
            if item.contentType == .fileURL, let paths = item.filePaths {
                let count = paths.count
                self.history.removeAll {
                    $0.contentType == .fileURL
                        && ($0.filePaths?.count ?? -1) == count
                        && $0.filePaths == paths
                }
            } else if let text = item.textContent {
                let size = item.originalSize
                let type = item.contentType
                self.history.removeAll {
                    $0.contentType == type
                        && $0.originalSize == size
                        && $0.textContent == text
                }
            }

            self.history.insert(item, at: 0)

            // Trim to max count
            while self.history.count > self.settings.maxHistoryCount {
                let removed = self.history.removeLast()
                self.cleanupFile(for: removed)
            }

            self.scheduleSave()
        }
    }

    func pasteItem(_ item: ClipboardItem, asPlainText: Bool = false) {
        let forcePlain = asPlainText || settings.alwaysPastePlainText
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
                    let plain = NSAttributedString(rtf: rtfData, documentAttributes: nil)?
                        .string ?? (item.textContent ?? "")
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
                let plain = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (item.textContent ?? "")
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
                let fullText = (try? String(contentsOf: url, encoding: .utf8)) ?? (item.textContent ?? "")
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
            pasteboard.setString(item.textContent ?? "", forType: .string)
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

    func pinItem(_ item: ClipboardItem) {
        // Move item to top
        if let index = history.firstIndex(of: item) {
            history.remove(at: index)
            history.insert(item, at: 0)
            scheduleSave()
        }
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

        filterCancellable = Publishers.CombineLatest3(historyStream, queryStream, categoryStream)
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { history, query, category -> [ClipboardItem] in
                let categoryFiltered: [ClipboardItem]
                switch category {
                case .clipboard:
                    categoryFiltered = history.filter { $0.contentType != .image }
                case .screenshots:
                    categoryFiltered = history.filter { $0.contentType == .image }
                }
                guard !query.isEmpty else { return categoryFiltered }
                return categoryFiltered.filter {
                    $0.displayText.range(of: query, options: .caseInsensitive) != nil
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: \.filteredHistory, on: self)
    }
}

/// Top-level segmentation surfaced in the history popover.
/// `.clipboard` shows text/rich-text/file items; `.screenshots` shows images.
enum HistoryCategory: String, CaseIterable, Identifiable {
    case clipboard
    case screenshots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .screenshots: return "Screenshots"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .screenshots: return "photo"
        }
    }
}
