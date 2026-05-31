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
    private var popoverGlobalMouseMonitor: Any?
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
        popover.contentSize = NSSize(width: 460, height: 640)
        // `.semitransient` keeps the popover open while the user is still
        // interacting with our own app — needed because both `NSMenu.popUp`
        // and SwiftUI sheets present in sibling windows that `.transient`
        // would treat as a click-outside, dismissing the popover and
        // leaving the menu / sheet orphaned. `.semitransient` still
        // auto-closes when the user switches to a different app.
        popover.behavior = .semitransient

        // Start monitoring clipboard
        clipboardManager.startMonitoring()

        // Honor the persisted "expand snippet abbreviations" setting. The
        // expander prompts for Accessibility on its own when the user first
        // flips it on, so we don't pre-prompt here at launch.
        if settingsManager.snippetAbbreviationsEnabled {
            SnippetAbbreviationExpander.shared.setEnabled(true)
        }

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
            case .captureWindow:
                AppDelegate.shared?.captureWindow()
            case .repeatLastCapture:
                ScreenshotCapture.shared.repeatLast()
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
        seedKeyboardSelection()
        popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            // When a modal sheet (e.g. the snippet editor) is presented on
            // top of the popover, let it own the keyboard. Otherwise Escape
            // would close the popover *around* the sheet, leaving an
            // orphaned modal that swallows all clicks.
            if let popoverWindow = self.popover.contentViewController?.view.window,
               popoverWindow.attachedSheet != nil {
                return event
            }
            return self.handlePopoverKey(event)
        }
        // `.semitransient` keeps the popover open across in-app sibling
        // windows (menus, sheets). The trade-off is that it sometimes fails
        // to auto-dismiss when the user clicks into another app — most
        // visibly after a `Menu` dismissal leaves NSApp in an "active but
        // unfocused" limbo. This global monitor is the safety net: any
        // mouse click that happens outside ALL of our own windows closes
        // the popover (and any orphaned menu / sheet along with it).
        popoverGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            // Don't dismiss while a modal sheet (e.g. the snippet editor)
            // is attached — closing the popover would orphan the sheet and
            // wedge the UI. The sheet's own Cancel / Save buttons are the
            // intended dismissal path.
            if let popoverWindow = self.popover.contentViewController?.view.window,
               popoverWindow.attachedSheet != nil {
                return
            }
            // A global monitor only fires for clicks in OTHER apps — clicks
            // inside our own windows go through the local monitor. So if we
            // got here, the click was outside us; close down cleanly. The
            // monitor's closure already runs on the main thread; we don't
            // need to hop again.
            self.popover.performClose(nil)
            ImageQuickPreview.shared.dismiss()
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
        if let m = popoverGlobalMouseMonitor {
            NSEvent.removeMonitor(m)
            popoverGlobalMouseMonitor = nil
        }
    }

    /// Pick a sensible row to highlight as soon as the popover comes up so
    /// keyboard navigation has something to anchor to. The snippets tab has
    /// its own selection state to keep the highlight stable when the user
    /// flips between tabs.
    private func seedKeyboardSelection() {
        if clipboardManager.selectedCategory == .snippets {
            if clipboardManager.keyboardSelectedSnippetID == nil {
                clipboardManager.keyboardSelectedSnippetID = clipboardManager.filteredSnippets.first?.id
            }
        } else {
            if clipboardManager.keyboardSelectedID == nil {
                clipboardManager.keyboardSelectedID = clipboardManager.filteredHistory.first?.id
            }
        }
    }

    private func handlePopoverKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let transform = PasteTransform.from(modifiers: mods)
        let isSnippets = clipboardManager.selectedCategory == .snippets

        // ⌘+digit → quick paste of the Nth visible row. Any combination of
        // ⌥/⇧/⌃ alongside selects the paste transform (see
        // `PasteTransform.from(modifiers:)`).
        let nonCmdMods = mods.subtracting([.option, .shift, .control])
        if nonCmdMods == .command,
           let chars = event.charactersIgnoringModifiers,
           let digit = Int(chars), digit >= 1, digit <= 9 {
            if isSnippets {
                let list = clipboardManager.filteredSnippets
                if digit <= list.count {
                    clipboardManager.pasteSnippet(list[digit - 1], transform: transform)
                    popover.performClose(nil)
                    return nil
                }
            } else {
                let list = clipboardManager.filteredHistory
                if digit <= list.count {
                    clipboardManager.pasteItem(list[digit - 1], transform: transform)
                    popover.performClose(nil)
                    return nil
                }
            }
        }

        switch Int(event.keyCode) {
        case 125: // down
            advanceSelection(by: 1)
            return nil
        case 126: // up
            advanceSelection(by: -1)
            return nil
        case 36, 76: // return / numpad enter
            if isSnippets {
                if let id = clipboardManager.keyboardSelectedSnippetID,
                   let snippet = clipboardManager.filteredSnippets.first(where: { $0.id == id }) {
                    clipboardManager.pasteSnippet(snippet, transform: transform)
                    popover.performClose(nil)
                    return nil
                }
            } else {
                if let id = clipboardManager.keyboardSelectedID,
                   let item = clipboardManager.filteredHistory.first(where: { $0.id == id }) {
                    clipboardManager.pasteItem(item, transform: transform)
                    popover.performClose(nil)
                    return nil
                }
            }
            return event
        case 53: // esc
            popover.performClose(nil)
            return nil
        default:
            return event
        }
    }

    private func advanceSelection(by delta: Int) {
        if clipboardManager.selectedCategory == .snippets {
            let list = clipboardManager.filteredSnippets
            guard !list.isEmpty else { return }
            let currentIndex = list.firstIndex(where: { $0.id == clipboardManager.keyboardSelectedSnippetID }) ?? -1
            let nextIndex = max(0, min(list.count - 1, currentIndex + delta))
            clipboardManager.keyboardSelectedSnippetID = list[nextIndex].id
        } else {
            let list = clipboardManager.filteredHistory
            guard !list.isEmpty else { return }
            let currentIndex = list.firstIndex(where: { $0.id == clipboardManager.keyboardSelectedID }) ?? -1
            let nextIndex = max(0, min(list.count - 1, currentIndex + delta))
            clipboardManager.keyboardSelectedID = list[nextIndex].id
        }
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

    /// Bring up the selection overlay already in window-pick mode so the
    /// user can click any on-screen window to capture it. Bound to the
    /// user-configured `captureWindow` hotkey.
    func captureWindow() {
        ScreenshotCapture.shared.captureWindow()
    }
}
