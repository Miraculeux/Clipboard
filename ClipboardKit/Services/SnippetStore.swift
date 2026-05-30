import Foundation

/// Persists user-curated snippets to a JSON file in app support. Snippets are
/// small (title + body), low in count (tens, not thousands), and rarely
/// mutated — a single JSON blob is the right size of solution. SQLite would
/// be over-engineering here.
///
/// All public methods are safe to call from any thread; writes are
/// serialized on an internal queue and debounced to coalesce rapid edits.
final class SnippetStore: @unchecked Sendable {
    static let shared = SnippetStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "ClipboardKit.SnippetStore", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private static let saveDebounce: TimeInterval = 0.4

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClipboardKit")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.fileURL = appDir.appendingPathComponent("snippets.json")
    }

    func loadAll() -> [Snippet] {
        return queue.sync { _loadAll() }
    }

    /// Replace the on-disk snippets with `snippets`. Debounced so a burst of
    /// reorders / edits produces a single write.
    func saveAll(_ snippets: [Snippet]) {
        pendingSave?.cancel()
        let snapshot = snippets
        let work = DispatchWorkItem { [weak self] in
            self?._saveAll(snapshot)
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// Flush any pending write synchronously (call on terminate).
    func flush() {
        let work = pendingSave
        pendingSave = nil
        queue.sync {
            work?.perform()
        }
    }

    // MARK: - Internals

    private func _loadAll() -> [Snippet] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Snippet].self, from: data)) ?? []
    }

    private func _saveAll(_ snippets: [Snippet]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snippets) else { return }
        // Atomic write: a crash mid-write can't corrupt the user's library.
        try? data.write(to: fileURL, options: .atomic)
    }
}
