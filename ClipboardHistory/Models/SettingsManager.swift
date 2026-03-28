import Foundation
import SwiftUI
import ServiceManagement

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let maxHistoryCount = "maxHistoryCount"
        static let largeFileStoragePath = "largeFileStoragePath"
        static let largeFileThresholdMB = "largeFileThresholdMB"
        static let showNotifications = "showNotifications"
        static let launchAtLogin = "launchAtLogin"
    }

    @Published var maxHistoryCount: Int {
        didSet { defaults.set(maxHistoryCount, forKey: Keys.maxHistoryCount) }
    }

    @Published var largeFileStoragePath: String {
        didSet { defaults.set(largeFileStoragePath, forKey: Keys.largeFileStoragePath) }
    }

    @Published var largeFileThresholdMB: Int {
        didSet { defaults.set(largeFileThresholdMB, forKey: Keys.largeFileThresholdMB) }
    }

    @Published var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: Keys.showNotifications) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    var largeFileThresholdBytes: Int {
        largeFileThresholdMB * 1_000_000
    }

    private init() {
        // Set defaults
        let defaultStoragePath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClipboardHistory/LargeFiles").path

        if defaults.object(forKey: Keys.maxHistoryCount) == nil {
            defaults.set(50, forKey: Keys.maxHistoryCount)
        }
        if defaults.object(forKey: Keys.largeFileStoragePath) == nil {
            defaults.set(defaultStoragePath, forKey: Keys.largeFileStoragePath)
        }
        if defaults.object(forKey: Keys.largeFileThresholdMB) == nil {
            defaults.set(1, forKey: Keys.largeFileThresholdMB)
        }
        if defaults.object(forKey: Keys.showNotifications) == nil {
            defaults.set(true, forKey: Keys.showNotifications)
        }

        self.maxHistoryCount = defaults.integer(forKey: Keys.maxHistoryCount)
        self.largeFileStoragePath = defaults.string(forKey: Keys.largeFileStoragePath) ?? defaultStoragePath
        self.largeFileThresholdMB = defaults.integer(forKey: Keys.largeFileThresholdMB)
        self.showNotifications = defaults.bool(forKey: Keys.showNotifications)
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)

        // Ensure storage directory exists
        ensureStorageDirectoryExists()

        // Sync login item state with system on next run loop to avoid layout recursion
        DispatchQueue.main.async { [weak self] in
            self?.syncLoginItemStatus()
        }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update login item: \(error)")
        }
    }

    private func syncLoginItemStatus() {
        let status = SMAppService.mainApp.status
        let isRegistered = (status == .enabled)
        if launchAtLogin != isRegistered {
            launchAtLogin = isRegistered
        }
    }

    func ensureStorageDirectoryExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: largeFileStoragePath) {
            try? fm.createDirectory(atPath: largeFileStoragePath, withIntermediateDirectories: true)
        }
    }

    func selectStorageFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Storage Folder"

        if panel.runModal() == .OK, let url = panel.url {
            return url.path
        }
        return nil
    }
}
