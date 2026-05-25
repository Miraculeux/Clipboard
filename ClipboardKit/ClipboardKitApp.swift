import SwiftUI
import Carbon.HIToolbox

@main
struct ClipboardKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Migrate legacy ClipboardHistory data before any singletons read from disk.
        DataMigration.migrateIfNeeded()
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(ClipboardManager.shared)
                .environmentObject(SettingsManager.shared)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static private(set) var shared: AppDelegate!
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var settingsWindow: NSWindow?
    var clipboardManager = ClipboardManager.shared
    var settingsManager = SettingsManager.shared
    var previousApp: NSRunningApplication?
    private var popoverKeyMonitor: Any?
    private var popoverCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Hide dock icon - menu bar only app
        NSApp.setActivationPolicy(.accessory)

        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard History")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Setup popover (content set lazily on first show)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 350, height: 500)
        popover.behavior = .transient

        // Start monitoring clipboard
        clipboardManager.startMonitoring()

        // Register global hotkeys via HotkeyManager (configurable in Settings).
        HotkeyManager.shared.install { action in
            switch action {
            case .toggleHistory:
                AppDelegate.shared?.togglePopover()
            case .captureRegion:
                AppDelegate.shared?.captureScreenRegion()
            case .captureLongScreenshot:
                AppDelegate.shared?.toggleLongScreenshot()
            case .captureFullScreen:
                AppDelegate.shared?.captureFullScreen()
            }
        }

        // First-run onboarding.
        if !settingsManager.hasSeenOnboarding {
            DispatchQueue.main.async {
                OnboardingWindowController.shared.present()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardManager.stopMonitoring()
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
                ImageQuickPreview.shared.dismiss()
            } else {
                // Lazily create content to avoid layout recursion at launch
                if popover.contentViewController == nil {
                    popover.contentViewController = NSHostingController(
                        rootView: ClipboardHistoryView()
                            .environmentObject(clipboardManager)
                            .environmentObject(settingsManager)
                    )
                }
                // Remember the currently active app before we steal focus
                previousApp = NSWorkspace.shared.frontmostApplication
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate()
                installPopoverKeyMonitor()
            }
        }
    }

    /// Local key-event monitor active only while the popover is visible.
    /// Supports ↑/↓ to move selection, Return to paste, Esc to close, and
    /// ⌘+digit to paste the Nth visible item.
    private func installPopoverKeyMonitor() {
        removePopoverKeyMonitor()
        // Seed keyboard selection on the first row so the user sees focus.
        if clipboardManager.keyboardSelectedID == nil {
            clipboardManager.keyboardSelectedID = clipboardManager.filteredHistory.first?.id
        }
        popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            return self.handlePopoverKey(event)
        }
        if popoverCloseObserver == nil {
            popoverCloseObserver = NotificationCenter.default.addObserver(
                forName: NSPopover.didCloseNotification,
                object: popover,
                queue: .main
            ) { [weak self] _ in
                self?.removePopoverKeyMonitor()
            }
        }
    }

    private func removePopoverKeyMonitor() {
        if let m = popoverKeyMonitor {
            NSEvent.removeMonitor(m)
            popoverKeyMonitor = nil
        }
    }

    private func handlePopoverKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let list = clipboardManager.filteredHistory
        let asPlain = mods.contains(.option)

        // ⌘+digit → quick paste of the Nth visible row.
        if mods.subtracting(.option) == .command,
           let chars = event.charactersIgnoringModifiers,
           let digit = Int(chars), digit >= 1, digit <= 9, digit <= list.count {
            clipboardManager.pasteItem(list[digit - 1], asPlainText: asPlain)
            popover.performClose(nil)
            return nil
        }

        switch Int(event.keyCode) {
        case 125: // down
            advanceSelection(by: 1, in: list)
            return nil
        case 126: // up
            advanceSelection(by: -1, in: list)
            return nil
        case 36, 76: // return / numpad enter
            if let id = clipboardManager.keyboardSelectedID,
               let item = list.first(where: { $0.id == id }) {
                clipboardManager.pasteItem(item, asPlainText: asPlain)
                popover.performClose(nil)
                return nil
            }
            return event
        case 53: // esc
            popover.performClose(nil)
            return nil
        default:
            return event
        }
    }

    private func advanceSelection(by delta: Int, in list: [ClipboardItem]) {
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex(where: { $0.id == clipboardManager.keyboardSelectedID }) ?? -1
        let nextIndex = max(0, min(list.count - 1, currentIndex + delta))
        clipboardManager.keyboardSelectedID = list[nextIndex].id
    }

    func closePopoverAndRestoreFocus(then action: @escaping @Sendable () -> Void) {
        popover.performClose(nil)
        ImageQuickPreview.shared.dismiss()
        // Re-activate the previous app so paste goes into the right place
        if let app = previousApp {
            app.activate()
        }
        // Small delay to let the OS switch focus before simulating keystrokes.
        // 100ms is enough on all hardware we've measured (M1+, ProMotion);
        // earlier 200ms was over-conservative and noticeably delayed paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            action()
        }
    }

    func openSettings() {
        popover.performClose(nil)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let settingsView = SettingsView()
            .environmentObject(clipboardManager)
            .environmentObject(settingsManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard History Settings"
        window.contentViewController = NSHostingController(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        settingsWindow = window
    }

    func registerCarbonHotkey() {
        // Deprecated: hotkey registration now lives in `HotkeyManager`.
        // Kept as an empty stub in case external callers still reference it.
    }

    /// Starts the in-app interactive region capture: a gray overlay covers every screen,
    /// the user drags out a rectangle (which becomes a clear hole), and the resulting
    /// image is written to `NSPasteboard.general`.
    func captureScreenRegion() {
        // Don't preflight — `CGPreflightScreenCaptureAccess` lies for ScreenCaptureKit
        // clients. Just begin; ScreenshotCapture surfaces auth failures itself.
        ScreenshotCapture.shared.begin()
    }

    /// Toggle the long-screenshot session: first press starts selection, second
    /// press stops capturing and copies the stitched PNG to the clipboard.
    func toggleLongScreenshot() {
        LongScreenshotCapture.shared.toggle()
    }

    /// Capture the entire main display immediately, without a selection overlay.
    /// Bound to the user-configured `captureFullScreen` hotkey.
    func captureFullScreen() {
        ScreenshotCapture.shared.captureFullScreen()
    }
}
