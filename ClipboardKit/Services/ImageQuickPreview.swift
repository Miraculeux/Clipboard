import AppKit
import Quartz

/// Thin wrapper around macOS's system Quick Look (`QLPreviewPanel`).
///
/// We let macOS own the entire preview UX — zoom, scroll, arrow navigation,
/// Esc-to-close, fullscreen, Open With…, etc. all just work. Our only job
/// is to vend a `QLPreviewItem`. The panel becomes its own key window so
/// it keeps working even after the menu-bar popover dismisses.
///
/// Because our app uses the `.accessory` activation policy (LSUIElement),
/// panels owned by it cannot normally become key. We temporarily switch to
/// `.regular` while the preview is open and restore `.accessory` on close.
final class ImageQuickPreview: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = ImageQuickPreview()

    fileprivate var items: [QLItem] = []
    private(set) var currentPath: String?
    private var panelObserver: NSObjectProtocol?

    private override init() { super.init() }

    func show(path: String) {
        let url = URL(fileURLWithPath: path)
        items = [QLItem(url: url)]
        currentPath = path

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self

        // Watch for the panel disappearing (Esc / close box) so we can drop
        // the dock icon again. The panel uses `windowWillClose` notifications.
        if panelObserver == nil {
            panelObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.cleanup()
            }
        }

        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }

        // Maximize to fill the screen's visible area (excluding menu bar and
        // Dock). Deferred to the next runloop because QLPreviewPanel sets up
        // its own initial frame asynchronously when first shown.
        DispatchQueue.main.async {
            let target = (panel.screen ?? NSScreen.main)?.visibleFrame
            if let target = target {
                panel.setFrame(target, display: true, animate: false)
            }
        }
    }

    /// Toggle the preview for `path`: open if closed (or showing a different
    /// image), close if already previewing this image.
    func toggle(path: String) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible, currentPath == path {
            panel.orderOut(nil)
            cleanup()
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
        items.removeAll()
        currentPath = nil
        if let observer = panelObserver {
            NotificationCenter.default.removeObserver(observer)
            panelObserver = nil
        }
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - QLPreviewPanelDataSource & Delegate

extension ImageQuickPreview: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items[index]
    }
}

/// Minimal `QLPreviewItem`-conforming wrapper around a file URL.
private final class QLItem: NSObject, QLPreviewItem {
    let url: URL
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { url.lastPathComponent }
    init(url: URL) { self.url = url }
}
