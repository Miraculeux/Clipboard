import Foundation
import AppKit
import Combine
import Carbon.HIToolbox

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published var history: [ClipboardItem] = []
    @Published var searchText: String = ""
    /// Cached, debounced filtered view of `history`. Recomputed only when
    /// `history` or `searchText` actually changes (debounced for typing).
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

    /// Cached history file URL. Directory is created once in `init` so we
    /// don't hit the filesystem on every save.
    private let historyFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClipboardKit")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("history.json")
    }()

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

    func startMonitoring() {
        let t = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        // Allow the system to coalesce wake-ups; we don't need millisecond accuracy.
        t.tolerance = 0.2
        timer = t
    }

    func stopMonitoring() {
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
                let (preview, sidecar) = self.offloadLargeTextIfNeeded(plainText)
                let item = ClipboardItem(
                    id: UUID(),
                    timestamp: Date(),
                    contentType: .richText,
                    textContent: preview,
                    fileName: sidecar,
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
        // Build a safe truncated preview. Cap by character count so we never
        // split a multi-byte UTF-8 sequence.
        let previewChars = min(text.count, 4_000)
        let preview = String(text.prefix(previewChars))
            + "\n…(truncated, full content stored on disk)"
        return (preview, fileURL.path)
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

    func pasteItem(_ item: ClipboardItem) {
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
                    self.lastChangeCount = self.pasteboard.changeCount
                    AppDelegate.shared.closePopoverAndRestoreFocus { [weak self] in
                        self?.simulatePaste()
                    }
                }
            }
            return
        }

        // Large-text paste: full body lives on disk; read it in the background.
        if (item.contentType == .text || item.contentType == .richText),
           let sidecar = item.fileName {
            let url = URL(fileURLWithPath: sidecar)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let fullText = (try? String(contentsOf: url, encoding: .utf8)) ?? (item.textContent ?? "")
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.pasteboard.clearContents()
                    self.pasteboard.setString(fullText, forType: .string)
                    self.lastChangeCount = self.pasteboard.changeCount
                    AppDelegate.shared.closePopoverAndRestoreFocus { [weak self] in
                        self?.simulatePaste()
                    }
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

        // Update change count so we don't re-capture what we just pasted
        lastChangeCount = pasteboard.changeCount

        // Close popover, restore focus to previous app, then simulate paste
        AppDelegate.shared.closePopoverAndRestoreFocus { [weak self] in
            self?.simulatePaste()
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
    /// background work item just encodes + writes that snapshot. We avoid
    /// `DispatchQueue.main.sync` from the save queue to prevent any chance of
    /// reverse-blocking the main thread.
    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = history
        let url = historyFileURL
        let work = DispatchWorkItem {
            Self.writeHistory(snapshot, to: url)
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// Force any pending write to complete synchronously (e.g. on terminate).
    /// Runs the write on the save queue so we don't tie up the main thread
    /// with a JSON encode + atomic file write — and we serialize cleanly
    /// against any in-flight save the queue had already started.
    private func flushPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = history
        let url = historyFileURL
        saveQueue.sync {
            Self.writeHistory(snapshot, to: url)
        }
    }

    private static func writeHistory(_ items: [ClipboardItem], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadHistoryAsync() {
        let url = historyFileURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: url),
                  let items = try? decoder.decode([ClipboardItem].self, from: data) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
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
        // Don't `removeDuplicates` on `history` — our mutators always produce
        // a real change and full-array equality is O(n × text), which is the
        // exact thing we're trying to avoid.
        //
        // Both inputs are debounced: typing in the search box (120ms) and
        // bursts of clipboard captures / pin / delete (60ms). Without the
        // history debounce, every `addItem` immediately re-runs the filter on
        // a background queue and bounces back to main, which adds up under
        // rapid copies.
        let historyStream = $history
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
        let queryStream = $searchText
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .removeDuplicates()

        filterCancellable = Publishers.CombineLatest(historyStream, queryStream)
            // Move the filter work off the main thread for large histories.
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { history, query -> [ClipboardItem] in
                // Fast path: no query → no filtering, no allocation.
                guard !query.isEmpty else { return history }
                return history.filter {
                    $0.displayText.range(of: query, options: .caseInsensitive) != nil
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: \.filteredHistory, on: self)
    }
}
