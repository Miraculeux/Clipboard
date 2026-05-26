import AppKit
import Quartz

/// QuickLook-backed image preview.
///
/// Uses the system `QLPreviewPanel`, which opens at a sensible default
/// (non-fullscreen) size, is freely resizable, and supports the standard
/// QuickLook chrome (zoom, share, open-with). The panel is shared across
/// the system so there can only be one at a time; we register ourselves
/// as its `delegate` / `dataSource` while we own it.
///
/// Public API (`show`, `toggle`, `dismiss`, `currentPath`) is preserved so
/// the call sites in `ClipboardHistoryView` and `ClipboardKitApp` don't
/// have to change.
final class ImageQuickPreview: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = ImageQuickPreview()

    private(set) var currentPath: String?

    private override init() { super.init() }

    func show(path: String) {
        // Switch to .regular so a panel owned by an LSUIElement app can
        // actually become key and receive keyboard input.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()

        currentPath = path

        guard let panel = QLPreviewPanel.shared() else {
            NSSound.beep()
            return
        }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func toggle(path: String) {
        if currentPath == path,
           let panel = QLPreviewPanel.shared(),
           panel.isVisible {
            dismiss()
        } else {
            show(path: path)
        }
    }

    func dismiss() {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        cleanup()
    }

    private func cleanup() {
        currentPath = nil
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - QLPreviewPanel data source / delegate

extension ImageQuickPreview: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentPath == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let path = currentPath else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
    }
}
