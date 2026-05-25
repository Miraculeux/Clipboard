import Foundation
import SQLite3

/// Tiny SQLite-backed persistence layer for the clipboard history.
///
/// Design intent:
/// - **One file, one table.** `items(id TEXT PRIMARY KEY, position INTEGER, payload BLOB)`.
///   `payload` is the JSON-encoded `ClipboardItem`, so schema changes to that
///   struct never require a DB migration — Codable handles it.
/// - **Order is explicit.** A monotonically increasing `position` column
///   preserves the in-memory ordering across pinning and reordering. We
///   replace the whole table inside a single transaction on each save so the
///   on-disk state always matches what the user sees.
/// - **Off-main.** All read/write methods are intended to run from a utility
///   queue; the `ClipboardManager` is responsible for the queue hop.
///
/// `nonisolated(unsafe)` is safe because every public method serializes on
/// its own internal serial queue and the SQLite handle is never touched from
/// any other code path.
final class HistoryStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ClipboardKit.HistoryStore", qos: .utility)
    private let dbURL: URL
    /// Path to the legacy JSON history. Loaded into the DB exactly once on
    /// first run after the migration ship.
    private let legacyJSONURL: URL

    /// SQLite's documented sentinel for "make a private copy of the bound
    /// string/blob". Equivalent to `SQLITE_TRANSIENT` from the C header,
    /// which doesn't get auto-imported as a Swift constant.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClipboardKit")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.dbURL = appDir.appendingPathComponent("history.sqlite")
        self.legacyJSONURL = appDir.appendingPathComponent("history.json")
        openDatabase()
        createSchema()
    }

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Public API

    /// Synchronously load every item in display order. Safe to call from a
    /// background queue.
    func loadAll() -> [ClipboardItem] {
        return queue.sync { _loadAll() }
    }

    /// Replace the entire on-disk table with `items` inside a single
    /// transaction. Asynchronous and non-blocking.
    func replaceAll(_ items: [ClipboardItem]) {
        let snapshot = items
        queue.async { [weak self] in
            self?._replaceAll(snapshot)
        }
    }

    /// One-time import from the legacy `history.json` blob. Returns the
    /// imported items if a migration happened, otherwise nil. The caller
    /// should merge / replace its in-memory state with the result.
    func migrateLegacyJSONIfNeeded() -> [ClipboardItem]? {
        return queue.sync { _migrateLegacyJSON() }
    }

    // MARK: - Internals (all on `queue`)

    private func openDatabase() {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &handle, flags, nil) == SQLITE_OK else {
            NSLog("[HistoryStore] sqlite3_open_v2 failed: %s", String(cString: sqlite3_errmsg(handle)))
            sqlite3_close_v2(handle)
            return
        }
        self.db = handle
        // WAL gives us non-blocking readers + crash-safe writes. NORMAL
        // sync is fine for a user-data cache — we already debounce saves.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
    }

    private func createSchema() {
        exec("""
            CREATE TABLE IF NOT EXISTS items (
              id TEXT PRIMARY KEY,
              position INTEGER NOT NULL,
              payload BLOB NOT NULL
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_items_position ON items(position);")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db = db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "(unknown)"
            NSLog("[HistoryStore] exec failed: %@ — %@", sql, msg)
            sqlite3_free(err)
            return false
        }
        return true
    }

    private func _loadAll() -> [ClipboardItem] {
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT payload FROM items ORDER BY position ASC;", -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[HistoryStore] prepare loadAll failed: %s", String(cString: sqlite3_errmsg(db)))
            return []
        }
        var items: [ClipboardItem] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blobPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let blobLen = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blobPtr, count: blobLen)
            if let item = try? decoder.decode(ClipboardItem.self, from: data) {
                items.append(item)
            }
        }
        return items
    }

    private func _replaceAll(_ items: [ClipboardItem]) {
        guard let db = db else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        defer {
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
        sqlite3_exec(db, "DELETE FROM items;", nil, nil, nil)

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO items (id, position, payload) VALUES (?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[HistoryStore] prepare insert failed: %s", String(cString: sqlite3_errmsg(db)))
            return
        }

        for (idx, item) in items.enumerated() {
            guard let data = try? encoder.encode(item) else { continue }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(idx))
            _ = data.withUnsafeBytes { raw -> Int32 in
                let ptr = raw.baseAddress
                return sqlite3_bind_blob(stmt, 3, ptr, Int32(raw.count), Self.SQLITE_TRANSIENT)
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("[HistoryStore] insert step failed: %s", String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func _migrateLegacyJSON() -> [ClipboardItem]? {
        // Only migrate if there's a legacy file AND the table is currently empty.
        guard FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return nil }
        let existing = _loadAll()
        guard existing.isEmpty else {
            // Already imported in a previous run; the JSON is stale, archive it.
            archiveLegacyFile()
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: legacyJSONURL),
              let items = try? decoder.decode([ClipboardItem].self, from: data) else {
            // Bad / unreadable file — archive it out of the way so we don't retry forever.
            archiveLegacyFile()
            return nil
        }
        _replaceAll(items)
        archiveLegacyFile()
        return items
    }

    private func archiveLegacyFile() {
        let archive = legacyJSONURL.appendingPathExtension("migrated")
        if FileManager.default.fileExists(atPath: archive.path) {
            try? FileManager.default.removeItem(at: archive)
        }
        try? FileManager.default.moveItem(at: legacyJSONURL, to: archive)
    }
}
