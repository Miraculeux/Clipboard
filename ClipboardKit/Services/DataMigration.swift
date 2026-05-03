import Foundation

enum DataMigration {
    private static let migrationKey = "didMigrateClipboardHistoryToClipboardKit"
    private static let oldFolderName = "ClipboardHistory"
    private static let newFolderName = "ClipboardKit"

    /// Migrates Application Support data from the legacy `ClipboardHistory` directory
    /// to the new `ClipboardKit` directory. Runs at most once.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let oldDir = appSupport.appendingPathComponent(oldFolderName)
        let newDir = appSupport.appendingPathComponent(newFolderName)

        if fm.fileExists(atPath: oldDir.path) {
            if fm.fileExists(atPath: newDir.path) {
                // New dir already exists: merge children that don't conflict.
                mergeDirectory(from: oldDir, into: newDir, fileManager: fm)
            } else {
                do {
                    try fm.moveItem(at: oldDir, to: newDir)
                } catch {
                    NSLog("ClipboardKit migration: failed to move \(oldDir.path): \(error)")
                    return
                }
            }
        }

        // Update default large-file storage path if it still points at the old folder.
        if let stored = defaults.string(forKey: "largeFileStoragePath") {
            let oldDefault = appSupport.appendingPathComponent("\(oldFolderName)/LargeFiles").path
            if stored == oldDefault {
                let newDefault = appSupport.appendingPathComponent("\(newFolderName)/LargeFiles").path
                defaults.set(newDefault, forKey: "largeFileStoragePath")
            }
        }

        defaults.set(true, forKey: migrationKey)
    }

    private static func mergeDirectory(from source: URL, into destination: URL, fileManager fm: FileManager) {
        guard let entries = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: target.path) { continue }
            do {
                try fm.moveItem(at: entry, to: target)
            } catch {
                NSLog("ClipboardKit migration: failed to move \(entry.path): \(error)")
            }
        }
        // Remove old dir if now empty.
        if let remaining = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil),
           remaining.isEmpty {
            try? fm.removeItem(at: source)
        }
    }
}
