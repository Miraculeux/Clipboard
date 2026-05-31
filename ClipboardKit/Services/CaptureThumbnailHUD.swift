import AppKit

/// macOS-style floating thumbnail that appears in the bottom-right corner of
/// the active screen right after a capture. Click to open the annotator;
/// click ✕ to dismiss; auto-fades after a few seconds.
final class CaptureThumbnailHUD: @unchecked Sendable {
    nonisolated(unsafe) static let shared = CaptureThumbnailHUD()

    private var panel: ThumbnailPanel?
    private var dismissWork: DispatchWorkItem?

    /// Seconds to keep the HUD on screen before fading out.
    private let autoDismissAfter: TimeInterval = 4

    private init() {}

    func show(image: NSImage, savedURL: URL?) {
        dismissWork?.cancel()

        if let existing = panel {
            existing.update(image: image, savedURL: savedURL)
            position(panel: existing)
            existing.orderFrontRegardless()
        } else {
            let p = ThumbnailPanel(image: image, savedURL: savedURL)
            p.onDismissRequested = { [weak self] in self?.dismiss() }
            self.panel = p
            position(panel: p)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                p.animator().alphaValue = 1
            }
        }

        scheduleAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissAfter, execute: work)
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func position(panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let margin: CGFloat = 24
        let size = panel.frame.size
        let x = screen.visibleFrame.maxX - size.width - margin
        let y = screen.visibleFrame.minY + margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Panel

private final class ThumbnailPanel: NSPanel {
    var onDismissRequested: (() -> Void)?
    private let container: ThumbnailContainerView
    private(set) var savedURL: URL?

    init(image: NSImage, savedURL: URL?) {
        let size = NSSize(width: 220, height: 140)
        let containerFrame = NSRect(origin: .zero, size: size)
        self.container = ThumbnailContainerView(frame: containerFrame)
        super.init(
            contentRect: containerFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.ignoresMouseEvents = false

        container.image = image
        self.savedURL = savedURL
        container.onClick = { [weak self] in self?.openAnnotator() }
        container.onClose = { [weak self] in self?.onDismissRequested?() }
        container.onReveal = { [weak self] in self?.revealSavedFile() }
        container.onPin = { [weak self] in self?.pinFloatingCopy() }
        self.contentView = container
    }

    func update(image: NSImage, savedURL: URL?) {
        container.image = image
        self.savedURL = savedURL
    }

    private func openAnnotator() {
        guard let image = container.image else { return }
        onDismissRequested?()
        AnnotationWindowController.shared.present(image: image, savedPath: savedURL?.path)
    }

    private func revealSavedFile() {
        guard let url = savedURL else { return }
        UrlActions.revealInSeeker(path: url.path)
    }

    private func pinFloatingCopy() {
        guard let image = container.image else { return }
        onDismissRequested?()
        PinnedImageWindow.pin(image: image)
    }
}

// MARK: - Container view

/// The actual visual: rounded HUD background with the thumbnail image,
/// a close button, and a reveal-in-Finder button when the file was saved.
private final class ThumbnailContainerView: NSView, NSDraggingSource {
    var image: NSImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onReveal: (() -> Void)?
    var onPin: (() -> Void)?

    private let imageView = NSImageView()
    private let closeButton = NSButton()
    private let revealButton = NSButton()
    private let pinButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 12
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds.insetBy(dx: 10, dy: 10)
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        closeButton.bezelStyle = .circular
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")
        closeButton.isBordered = false
        closeButton.frame = NSRect(x: bounds.width - 24, y: bounds.height - 24, width: 20, height: 20)
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)

        revealButton.bezelStyle = .circular
        revealButton.title = ""
        revealButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Reveal in Seeker")
        revealButton.isBordered = false
        revealButton.frame = NSRect(x: 4, y: bounds.height - 24, width: 20, height: 20)
        revealButton.autoresizingMask = [.maxXMargin, .minYMargin]
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        addSubview(revealButton)

        pinButton.bezelStyle = .circular
        pinButton.title = ""
        pinButton.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pin to screen")
        pinButton.isBordered = false
        pinButton.frame = NSRect(x: 28, y: bounds.height - 24, width: 20, height: 20)
        pinButton.autoresizingMask = [.maxXMargin, .minYMargin]
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        pinButton.toolTip = "Pin floating copy on screen"
        addSubview(pinButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Whole panel area triggers the annotator; the buttons stop it via
    /// their own action so a click on ✕ won't bubble.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(p) || revealButton.frame.contains(p) || pinButton.frame.contains(p) {
            super.mouseDown(with: event)
            return
        }
        // Defer until mouseDragged so a click without drag still opens annotator.
        clickStart = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = clickStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - start.x, dy = p.y - start.y
        // Only begin a drag once the user moved past the system slop.
        guard hypot(dx, dy) > 4 else { return }
        clickStart = nil
        beginDragSession(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { clickStart = nil }
        // If we never escalated to a drag, treat it as a click → open annotator.
        guard clickStart != nil else { return }
        onClick?()
    }

    private var clickStart: NSPoint?

    /// Write the current thumbnail image to a temp PNG and start an NSDragging
    /// session whose pasteboard advertises that file URL — so dropping into
    /// Finder, Slack, etc. produces a real PNG file.
    private func beginDragSession(with event: NSEvent) {
        guard let image else { return }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return
        }

        // Write to a stable per-app cache dir so drops keep working until the
        // next capture replaces the file.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardKit-DragOut", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("Screenshot \(Int(Date().timeIntervalSince1970)).png")
        do {
            try png.write(to: url)
        } catch {
            print("Thumbnail drag: couldn't write temp PNG: \(error)")
            return
        }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageView.frame, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy]
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func revealTapped() {
        onReveal?()
    }

    @objc private func pinTapped() {
        onPin?()
    }
}
