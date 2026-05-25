import Foundation
import SwiftUI
import ServiceManagement

class SettingsManager: ObservableObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let maxHistoryCount = "maxHistoryCount"
        static let largeFileStoragePath = "largeFileStoragePath"
        static let largeFileThresholdMB = "largeFileThresholdMB"
        static let showNotifications = "showNotifications"
        static let launchAtLogin = "launchAtLogin"
        static let saveScreenshotsToDisk = "saveScreenshotsToDisk"
        static let screenshotsFolderPath = "screenshotsFolderPath"
        static let captureDelaySeconds = "captureDelaySeconds"
        static let showCaptureThumbnail = "showCaptureThumbnail"
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let alwaysPastePlainText = "alwaysPastePlainText"
        static let restoreClipboardAfterPaste = "restoreClipboardAfterPaste"
        static func hotkeyKeyCode(_ action: HotkeyAction) -> String { "hotkey.\(action.rawValue).keyCode" }
        static func hotkeyModifiers(_ action: HotkeyAction) -> String { "hotkey.\(action.rawValue).modifiers" }
    }

    @Published var maxHistoryCount: Int {
        didSet { defaults.set(maxHistoryCount, forKey: Keys.maxHistoryCount) }
    }

    @Published var largeFileStoragePath: String {
        didSet {
            defaults.set(largeFileStoragePath, forKey: Keys.largeFileStoragePath)
            // Make sure the new directory exists so ClipboardManager can skip
            // the per-capture `createDirectory` call. Cheap when the dir is
            // already there.
            ensureStorageDirectoryExists()
        }
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

    // MARK: - Screenshot output

    @Published var saveScreenshotsToDisk: Bool {
        didSet { defaults.set(saveScreenshotsToDisk, forKey: Keys.saveScreenshotsToDisk) }
    }

    @Published var screenshotsFolderPath: String {
        didSet {
            defaults.set(screenshotsFolderPath, forKey: Keys.screenshotsFolderPath)
            ensureScreenshotsFolderExists()
        }
    }

    /// 0 = no delay; otherwise 3/5/10 seconds before the selection overlay
    /// appears, so users can open menus / position content first.
    @Published var captureDelaySeconds: Int {
        didSet { defaults.set(captureDelaySeconds, forKey: Keys.captureDelaySeconds) }
    }

    @Published var showCaptureThumbnail: Bool {
        didSet { defaults.set(showCaptureThumbnail, forKey: Keys.showCaptureThumbnail) }
    }

    @Published var hasSeenOnboarding: Bool {
        didSet { defaults.set(hasSeenOnboarding, forKey: Keys.hasSeenOnboarding) }
    }

    /// When on, every paste through ClipboardKit strips formatting and writes
    /// only `public.utf8-plain-text` to the pasteboard.
    @Published var alwaysPastePlainText: Bool {
        didSet { defaults.set(alwaysPastePlainText, forKey: Keys.alwaysPastePlainText) }
    }

    /// When on, ClipboardKit snapshots the system pasteboard before pasting a
    /// history item, then restores the original contents ~250ms after the
    /// simulated ⌘V. Net effect: the user pastes from history without
    /// losing whatever they had on the clipboard before.
    @Published var restoreClipboardAfterPaste: Bool {
        didSet { defaults.set(restoreClipboardAfterPaste, forKey: Keys.restoreClipboardAfterPaste) }
    }

    var largeFileThresholdBytes: Int {
        largeFileThresholdMB * 1_000_000
    }

    private init() {
        // Set defaults
        let defaultStoragePath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClipboardKit/LargeFiles").path
        let defaultScreenshotsPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? NSString("~/Desktop").expandingTildeInPath

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
        if defaults.object(forKey: Keys.saveScreenshotsToDisk) == nil {
            defaults.set(false, forKey: Keys.saveScreenshotsToDisk)
        }
        if defaults.object(forKey: Keys.screenshotsFolderPath) == nil {
            defaults.set(defaultScreenshotsPath, forKey: Keys.screenshotsFolderPath)
        }
        if defaults.object(forKey: Keys.captureDelaySeconds) == nil {
            defaults.set(0, forKey: Keys.captureDelaySeconds)
        }
        if defaults.object(forKey: Keys.showCaptureThumbnail) == nil {
            defaults.set(true, forKey: Keys.showCaptureThumbnail)
        }
        if defaults.object(forKey: Keys.hasSeenOnboarding) == nil {
            defaults.set(false, forKey: Keys.hasSeenOnboarding)
        }
        if defaults.object(forKey: Keys.alwaysPastePlainText) == nil {
            defaults.set(false, forKey: Keys.alwaysPastePlainText)
        }
        if defaults.object(forKey: Keys.restoreClipboardAfterPaste) == nil {
            defaults.set(false, forKey: Keys.restoreClipboardAfterPaste)
        }

        self.maxHistoryCount = defaults.integer(forKey: Keys.maxHistoryCount)
        self.largeFileStoragePath = defaults.string(forKey: Keys.largeFileStoragePath) ?? defaultStoragePath
        self.largeFileThresholdMB = defaults.integer(forKey: Keys.largeFileThresholdMB)
        self.showNotifications = defaults.bool(forKey: Keys.showNotifications)
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.saveScreenshotsToDisk = defaults.bool(forKey: Keys.saveScreenshotsToDisk)
        self.screenshotsFolderPath = defaults.string(forKey: Keys.screenshotsFolderPath) ?? defaultScreenshotsPath
        self.captureDelaySeconds = defaults.integer(forKey: Keys.captureDelaySeconds)
        self.showCaptureThumbnail = defaults.bool(forKey: Keys.showCaptureThumbnail)
        self.hasSeenOnboarding = defaults.bool(forKey: Keys.hasSeenOnboarding)
        self.alwaysPastePlainText = defaults.bool(forKey: Keys.alwaysPastePlainText)
        self.restoreClipboardAfterPaste = defaults.bool(forKey: Keys.restoreClipboardAfterPaste)

        // Ensure storage directory exists
        ensureStorageDirectoryExists()
        ensureScreenshotsFolderExists()

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
        // `createDirectory(...:withIntermediateDirectories: true)` is
        // idempotent — no need to stat first. Hop off main so a slow disk
        // (network share, encrypted volume) can't stall the settings UI.
        let path = largeFileStoragePath
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
        }
    }

    func ensureScreenshotsFolderExists() {
        let path = screenshotsFolderPath
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
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

    func selectScreenshotsFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Screenshots Folder"
        if panel.runModal() == .OK, let url = panel.url {
            return url.path
        }
        return nil
    }

    // MARK: - Hotkeys

    /// Read the binding for `action`. Falls back to the built-in default
    /// shipped with the app when nothing has been persisted yet.
    func hotkey(for action: HotkeyAction) -> HotkeyBinding {
        let keyKey = Keys.hotkeyKeyCode(action)
        let modKey = Keys.hotkeyModifiers(action)
        guard defaults.object(forKey: keyKey) != nil else {
            return action.defaultBinding
        }
        let kc = UInt32(defaults.integer(forKey: keyKey))
        let mods = UInt32(defaults.integer(forKey: modKey))
        return HotkeyBinding(keyCode: kc, modifiers: mods)
    }

    /// Persist a new binding (or `.disabled`) for `action` and trigger a
    /// hotkey re-registration on the next main-runloop tick.
    func setHotkey(_ binding: HotkeyBinding, for action: HotkeyAction) {
        defaults.set(Int(binding.keyCode), forKey: Keys.hotkeyKeyCode(action))
        defaults.set(Int(binding.modifiers), forKey: Keys.hotkeyModifiers(action))
        objectWillChange.send()
        DispatchQueue.main.async {
            HotkeyManager.shared.reregisterAll()
        }
    }

    func resetHotkey(_ action: HotkeyAction) {
        setHotkey(action.defaultBinding, for: action)
    }
}
