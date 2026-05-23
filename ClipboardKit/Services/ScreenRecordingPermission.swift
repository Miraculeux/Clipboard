import AppKit
import CoreGraphics

/// Verifies and prompts for the Screen Recording TCC permission required by ScreenCaptureKit.
enum ScreenRecordingPermission {
    /// Returns true if the app is currently authorized to capture the screen.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system permission prompt (only effective the first time).
    /// Subsequent calls are a no-op until the user toggles the entry in System Settings.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Show a blocking alert and, if the user agrees, jump to the Screen Recording pane.
    static func promptAndGuideToSettings() {
        // Trigger the OS prompt first; if the app has never been listed, this adds it.
        request()

        let alert = NSAlert()
        alert.messageText = "Screen Recording permission required"
        alert.informativeText = """
        ClipboardKit needs Screen Recording access to capture screenshots with \
        Cmd+Shift+S. Enable it in System Settings → Privacy & Security → \
        Screen Recording, then quit and relaunch ClipboardKit.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
