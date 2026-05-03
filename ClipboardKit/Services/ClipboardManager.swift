import Foundation
import AppKit
import Combine
import Carbon.HIToolbox

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published var history: [ClipboardItem] = []
    @Published var searchText: String = ""

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general
    private let settings = SettingsManager.shared

    private var historyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClipboardKit")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("history.json")
    }

    var filteredHistory: [ClipboardItem] {
        if searchText.isEmpty {
            return history
        }
        return history.filter { item in
            item.displayText.localizedCaseInsensitiveContains(searchText)
        }
    }

    private init() {
        loadHistory()
        lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Monitoring

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        captureClipboard()
    }

    private func captureClipboard() {
        // Check for file URLs first (Finder copy)
        // Files are detected via the pasteboard types that Finder sets
        let fileURLType = NSPasteboard.PasteboardType("public.file-url")
        let multiFileType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let hasFiles = pasteboard.types?.contains(where: { $0 == fileURLType || $0 == multiFileType }) ?? false

        if hasFiles {
            var filePaths: [String] = []

            // Try reading filenames from the legacy plist-based type
            if let data = pasteboard.data(forType: multiFileType),
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
                let totalSize = filePaths.reduce(0) { acc, path in
                    acc + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
                }
                let item = ClipboardItem(
                    id: UUID(),
                    timestamp: Date(),
                    contentType: .fileURL,
                    textContent: filePaths.joined(separator: "\n"),
                    fileName: nil,
                    filePaths: filePaths,
                    originalSize: totalSize
                )
                addItem(item)
                return
            }
        }

        // Check for image
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            let item = saveImageItem(data: imageData)
            addItem(item)
            return
        }

        // Check for rich text
        if let rtfData = pasteboard.data(forType: .rtf),
           let attrString = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            let plainText = attrString.string
            let item = ClipboardItem(
                id: UUID(),
                timestamp: Date(),
                contentType: .richText,
                textContent: plainText,
                fileName: nil,
                filePaths: nil,
                originalSize: rtfData.count
            )
            addItem(item)
            return
        }

        // Plain text
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let item = ClipboardItem(
                id: UUID(),
                timestamp: Date(),
                contentType: .text,
                textContent: text,
                fileName: nil,
                filePaths: nil,
                originalSize: text.utf8.count
            )
            addItem(item)
            return
        }
    }

    private func saveImageItem(data: Data) -> ClipboardItem {
        let fileName = UUID().uuidString + ".png"

        // Save to large file storage if needed
        let storagePath: String
        if data.count > settings.largeFileThresholdBytes {
            storagePath = settings.largeFileStoragePath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            storagePath = appSupport.appendingPathComponent("ClipboardKit/Images").path
        }

        let dirURL = URL(fileURLWithPath: storagePath)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let fileURL = dirURL.appendingPathComponent(fileName)

        // Convert TIFF to PNG for storage
        if let bitmapRep = NSBitmapImageRep(data: data),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
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

            // Remove duplicate
            if item.contentType == .fileURL, let paths = item.filePaths {
                self.history.removeAll { $0.filePaths == paths && $0.contentType == .fileURL }
            } else if let text = item.textContent {
                self.history.removeAll { $0.textContent == text && $0.contentType == item.contentType }
            }

            self.history.insert(item, at: 0)

            // Trim to max count
            while self.history.count > self.settings.maxHistoryCount {
                let removed = self.history.removeLast()
                self.cleanupFile(for: removed)
            }

            self.saveHistory()
        }
    }

    func pasteItem(_ item: ClipboardItem) {
        // Set the clipboard content first
        switch item.contentType {
        case .text:
            pasteboard.clearContents()
            pasteboard.setString(item.textContent ?? "", forType: .string)
        case .richText:
            pasteboard.clearContents()
            pasteboard.setString(item.textContent ?? "", forType: .string)
        case .image:
            if let fileName = item.fileName,
               let imageData = try? Data(contentsOf: URL(fileURLWithPath: fileName)) {
                pasteboard.clearContents()
                pasteboard.setData(imageData, forType: .png)
            }
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
        saveHistory()
    }

    func clearHistory() {
        for item in history {
            cleanupFile(for: item)
        }
        history.removeAll()
        saveHistory()
    }

    func pinItem(_ item: ClipboardItem) {
        // Move item to top
        if let index = history.firstIndex(of: item) {
            history.remove(at: index)
            history.insert(item, at: 0)
            saveHistory()
        }
    }

    private func cleanupFile(for item: ClipboardItem) {
        if let fileName = item.fileName {
            try? FileManager.default.removeItem(atPath: fileName)
        }
    }

    // MARK: - Persistence

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) {
            try? data.write(to: historyFileURL)
        }
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: historyFileURL),
           let items = try? decoder.decode([ClipboardItem].self, from: data) {
            history = items
        }
    }
}
