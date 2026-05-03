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
    static private(set) var shared: AppDelegate!
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var settingsWindow: NSWindow?
    var clipboardManager = ClipboardManager.shared
    var settingsManager = SettingsManager.shared
    var previousApp: NSRunningApplication?
    var hotKeyRef: EventHotKeyRef?
    var screenshotHotKeyRef: EventHotKeyRef?

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

        // Register global hotkey: Cmd+Shift+V
        registerCarbonHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardManager.stopMonitoring()
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = screenshotHotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
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
            }
        }
    }

    func closePopoverAndRestoreFocus(then action: @escaping () -> Void) {
        popover.performClose(nil)
        // Re-activate the previous app so paste goes into the right place
        if let app = previousApp {
            app.activate()
        }
        // Small delay to let the OS switch focus before simulating keystrokes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
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
        // Install Carbon event handler for hotkey
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerResult = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotkeyID)
            guard status == noErr else { return status }

            DispatchQueue.main.async {
                switch hotkeyID.id {
                case 1:
                    AppDelegate.shared?.togglePopover()
                case 2:
                    AppDelegate.shared?.captureScreenRegion()
                default:
                    break
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        guard handlerResult == noErr else {
            print("Failed to install event handler: \(handlerResult)")
            return
        }

        let signature = OSType(0x434C4950) // "CLIP"

        // Register Cmd+Shift+V — show clipboard history
        let pasteHotkeyID = EventHotKeyID(signature: signature, id: 1)
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let pasteStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), modifiers, pasteHotkeyID,
                                              GetApplicationEventTarget(), 0, &hotKeyRef)
        if pasteStatus != noErr {
            print("Failed to register Cmd+Shift+V hotkey: \(pasteStatus)")
        } else {
            print("Global hotkey Cmd+Shift+V registered successfully")
        }

        // Register Cmd+Shift+S — interactive screen region snapshot to clipboard
        let snapHotkeyID = EventHotKeyID(signature: signature, id: 2)
        let snapStatus = RegisterEventHotKey(UInt32(kVK_ANSI_S), modifiers, snapHotkeyID,
                                             GetApplicationEventTarget(), 0, &screenshotHotKeyRef)
        if snapStatus != noErr {
            print("Failed to register Cmd+Shift+S hotkey: \(snapStatus)")
        } else {
            print("Global hotkey Cmd+Shift+S registered successfully")
        }
    }

    /// Launches macOS's interactive screen-region capture, copying the result to the clipboard.
    /// Mirrors the Win+Shift+S behaviour: the screen dims, the user drags a region, and the
    /// resulting image lives only on the pasteboard (no file is written).
    func captureScreenRegion() {
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        // -i interactive, -c copy to clipboard, -x silent (no shutter sound)
        task.arguments = ["-i", "-c", "-x"]
        do {
            try task.run()
        } catch {
            print("Failed to launch screencapture: \(error)")
        }
    }
}
