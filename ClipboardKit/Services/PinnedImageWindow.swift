import AppKit

/// Snipaste-style floating image window.
///
/// Once pinned, the screenshot sits above other windows so the user can keep
/// it on screen as a reference while they work in another app. Supports:
///   - Drag to move (anywhere on the window).
///   - Pinch / scroll-with-modifier to scale.
///   - Right-click for actions (copy, save, close, lock-on-top toggle).
///   - ⌘C: copy current scaled image to clipboard.
///   - ⌫ / Esc: close.
///   - Drag-out to other apps (writes a temp PNG).
final class PinnedImageWindow: NSPanel {
    static func pin(image: NSImage, near anchor: NSScreen? = nil) {
        let win = PinnedImageWindow(image: image)
        win.position(near: anchor ?? NSScreen.main ?? NSScreen.screens.first)
        win.makeKeyAndOrderFront(nil)
        PinnedWindowRegistry.shared.register(win)
    }

    private let imageView: NSImageView
    private let baseSize: NSSize
    private var currentScale: CGFloat = 1.0
    private let originalImage: NSImage

    init(image: NSImage) {
        self.originalImage = image
        // Cap the initial on-screen size so massive screenshots don't take
        // over the whole desktop; user can scale up via pinch/scroll.
        let cap: CGFloat = 800
        let raw = image.size
        let scale = min(1.0, cap / max(raw.width, raw.height))
        let pt = NSSize(width: raw.width * scale, height: raw.height * scale)
        self.baseSize = pt

        let view = NSImageView(frame: NSRect(origin: .zero, size: pt))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 4
        view.layer?.masksToBounds = true
        self.imageView = view

        super.init(
            contentRect: NSRect(origin: .zero, size: pt),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = false

        let container = PinnedContainerView(frame: NSRect(origin: .zero, size: pt))
        container.imageView = view
        container.onCopy = { [weak self] in self?.copyToClipboard() }
        container.onSaveAs = { [weak self] in self?.saveAs() }
        container.onClose = { [weak self] in self?.closePin() }
        container.onToggleStickiness = { [weak self] in self?.toggleStickiness() }
        container.onScale = { [weak self] delta in self?.scaleBy(delta) }
        container.onResetScale = { [weak self] in self?.resetScale() }
        container.dragImageProvider = { [weak self] in self?.originalImage }
        container.addSubview(view)
        self.contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    fileprivate func closePin() {
        PinnedWindowRegistry.shared.unregister(self)
        self.orderOut(nil)
    }

    private func position(near screen: NSScreen?) {
        guard let screen else { return }
        let f = screen.visibleFrame
        // Centre the pin a bit off-centre so it doesn't fully cover whatever
        // the user was looking at.
        let origin = NSPoint(
            x: f.midX - baseSize.width / 2,
            y: f.midY - baseSize.height / 2
        )
        self.setFrameOrigin(origin)
    }

    fileprivate func copyToClipboard() {
        guard let tiff = originalImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        ToastCenter.shared.show("Copied")
    }

    fileprivate func saveAs() {
        guard let tiff = originalImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Pinned Screenshot.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }

    fileprivate func toggleStickiness() {
        if self.level == .floating {
            // Promote above modal panels — useful as a permanent reference.
            self.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
            ToastCenter.shared.show("Pin: locked on top")
        } else {
            self.level = .floating
            ToastCenter.shared.show("Pin: floating")
        }
    }

    /// Scale the pinned image by a multiplicative factor (1.0 = unchanged).
    /// Clamped to a sensible range so the user can't accidentally make it
    /// invisible or fill the screen.
    fileprivate func scaleBy(_ factor: CGFloat) {
        let newScale = max(0.2, min(4.0, currentScale * factor))
        guard abs(newScale - currentScale) > 0.001 else { return }
        currentScale = newScale
        applyCurrentScale()
    }

    fileprivate func resetScale() {
        currentScale = 1.0
        applyCurrentScale()
    }

    private func applyCurrentScale() {
        let newSize = NSSize(width: baseSize.width * currentScale,
                             height: baseSize.height * currentScale)
        // Anchor on the window's centre so scaling feels like a zoom from
        // the centre instead of from the top-left.
        let oldFrame = self.frame
        let originX = oldFrame.midX - newSize.width / 2
        let originY = oldFrame.midY - newSize.height / 2
        self.setFrame(NSRect(x: originX, y: originY, width: newSize.width, height: newSize.height), display: true)
        imageView.frame = NSRect(origin: .zero, size: newSize)
        (contentView as? PinnedContainerView)?.setFrameSize(newSize)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53, 51: // ESC, delete
            closePin(); return
        case 8 where mods == .command: // ⌘C
            copyToClipboard(); return
        default: break
        }
        super.keyDown(with: event)
    }
}

/// Holds strong references to active pinned windows so they aren't released
/// by ARC when the caller scope ends.
private final class PinnedWindowRegistry: @unchecked Sendable {
    nonisolated(unsafe) static let shared = PinnedWindowRegistry()
    private var windows: Set<NSPanel> = []
    func register(_ w: NSPanel) { windows.insert(w) }
    func unregister(_ w: NSPanel) { windows.remove(w) }
}

// MARK: - Container view

private final class PinnedContainerView: NSView, NSDraggingSource {
    var imageView: NSImageView?
    var onCopy: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleStickiness: (() -> Void)?
    var onScale: ((CGFloat) -> Void)?
    var onResetScale: (() -> Void)?
    var dragImageProvider: (() -> NSImage?)?

    private var dragStart: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - start.x, p.y - start.y) > 4 {
            // Hold ⌥ to drag the image OUT to other apps; default is to
            // move the window (handled by isMovableByWindowBackground).
            if event.modifierFlags.contains(.option) {
                dragStart = nil
                beginDragOut(with: event)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyAction), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Save As\u{2026}", action: #selector(saveAction), keyEquivalent: "s").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Toggle Lock on Top", action: #selector(stickyAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset Zoom", action: #selector(resetZoomAction), keyEquivalent: "0").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Close Pin", action: #selector(closeAction), keyEquivalent: "w").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Scroll wheel with ⌘ scales the pinned image. Without the modifier
    /// it's a no-op so casual scrolls don't accidentally zoom.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let factor = 1.0 + (event.scrollingDeltaY * 0.01)
        onScale?(factor)
    }

    /// Trackpad pinch zoom \u2014 standard macOS gesture.
    override func magnify(with event: NSEvent) {
        onScale?(1.0 + event.magnification)
    }

    private func beginDragOut(with event: NSEvent) {
        guard let image = dragImageProvider?(),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardKit-Pin", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("Pinned \(Int(Date().timeIntervalSince1970)).png")
        do { try png.write(to: url) } catch { return }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy]
    }

    @objc private func copyAction() { onCopy?() }
    @objc private func saveAction() { onSaveAs?() }
    @objc private func stickyAction() { onToggleStickiness?() }
    @objc private func resetZoomAction() { onResetScale?() }
    @objc private func closeAction() { onClose?() }
}
