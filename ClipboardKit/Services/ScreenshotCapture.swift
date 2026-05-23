import AppKit
import ScreenCaptureKit

/// Coordinates an interactive screen-region snapshot.
///
/// On `begin()`, a dim gray overlay is shown over every connected display.
/// The user drags to define a rectangle (which becomes a clear "hole" in the
/// overlay). On mouse-up the overlay is dismissed and the selected region is
/// captured into `NSPasteboard.general` as an image. Pressing ESC cancels.
final class ScreenshotCapture {
    static let shared = ScreenshotCapture()

    private var overlayWindows: [SelectionWindow] = []
    private var isActive = false
    /// Set to true once we have observed a real authorization failure from
    /// ScreenCaptureKit. While true, we refuse to call SCK again so that
    /// macOS does not keep popping its own TCC prompt on every hotkey press.
    private var authDenied = false

    private init() {}

    /// Show the selection overlay across every screen. No-op if already active.
    func begin() {
        DispatchQueue.main.async { self._begin() }
    }

    private func _begin() {
        guard !isActive else { return }
        if authDenied {
            // Stay silent — prior attempt already informed the user. They can
            // re-grant via Settings → General → Permissions, then relaunch.
            NSSound.beep()
            return
        }
        isActive = true

        overlayWindows = NSScreen.screens.map { screen in
            let w = SelectionWindow(screen: screen)
            w.onFinish = { [weak self] rect, screen in
                self?.finish(with: rect, on: screen)
            }
            w.onCancel = { [weak self] in
                self?.cancel()
            }
            return w
        }
        overlayWindows.forEach { $0.orderFrontRegardless() }

        NSApp.activate()
        overlayWindows.first?.makeKey()
    }

    /// User pressed ESC or made a zero-sized selection. Tear down without capturing.
    func cancel() {
        teardown()
    }

    /// Called by a SelectionWindow when the user finished a drag.
    /// `screenRect` is in AppKit global screen coordinates (origin bottom-left of primary display).
    /// `targetScreen` is the screen the selection was made on.
    func finish(with screenRect: NSRect, on targetScreen: NSScreen) {
        teardown()
        // Give the windows a moment to actually disappear from the compositor
        // before snapping the screen, otherwise the dim overlay would be captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { await self.captureAndCopy(screenRect: screenRect, screen: targetScreen) }
        }
    }

    private func teardown() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        isActive = false
    }

    private func captureAndCopy(screenRect: NSRect, screen: NSScreen) async {
        // Resolve the SCDisplay that matches the NSScreen the user selected on.
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            NSSound.beep()
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                NSSound.beep()
                return
            }

            // Convert the AppKit global rect into screen-local coordinates with origin top-left,
            // which is what ScreenCaptureKit's sourceRect expects (in points relative to the display).
            let originX = screenRect.origin.x - screen.frame.origin.x
            let originYFromTop = (screen.frame.height) - ((screenRect.origin.y - screen.frame.origin.y) + screenRect.height)
            let sourceRect = CGRect(x: originX, y: originYFromTop, width: screenRect.width, height: screenRect.height)

            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.sourceRect = sourceRect
            config.width = Int(screenRect.width * scale)
            config.height = Int(screenRect.height * scale)
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            // Encode to PNG so any pasteboard observer sees a concrete `public.png` payload.
            // Skip TIFF: it's uncompressed (~30+ MB for a 4K capture), forces a
            // second encode pass here, and then ClipboardManager would re-decode
            // it to derive PNG anyway. Modern macOS consumers handle PNG fine.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            bitmap.size = screenRect.size
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                print("Screenshot: failed to encode image data")
                NSSound.beep()
                return
            }

            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(pngData, forType: .png)
            }
        } catch {
            let nsError = error as NSError
            print("Screenshot capture failed: \(nsError.domain) \(nsError.code) — \(error.localizedDescription)")

            // Treat any SCStream/SCContent failure as a likely permission problem
            // and stop calling SCK for the rest of this launch. Otherwise macOS
            // will pop its own TCC prompt on every subsequent hotkey press.
            let isLikelyAuth = nsError.domain.contains("SCStream") || nsError.domain.contains("SCContent")
            await MainActor.run {
                if isLikelyAuth { self.authDenied = true }
                NSSound.beep()
            }
        }
    }
}

// MARK: - Overlay window

/// Borderless full-screen overlay used to drag-select a rectangle.
/// Generic over its caller — invoke `onFinish` / `onCancel` to react.
final class SelectionWindow: NSWindow {
    let targetScreen: NSScreen
    var onFinish: ((NSRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?

    init(screen: NSScreen) {
        self.targetScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        self.acceptsMouseMovedEvents = true

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.host = self
        self.contentView = view
        self.setFrame(screen.frame, display: true)
        self.invalidateCursorRects(for: view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

final class SelectionView: NSView {
    weak var host: SelectionWindow?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?
    /// Previous selection rect, used to compute a minimal dirty union so we
    /// don't invalidate the whole (potentially 5K) overlay on every drag
    /// frame. Without this, ProMotion can fire `mouseDragged` ~120 times per
    /// second, each repainting millions of pixels.
    private var previousRect: NSRect?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        let newRect = NSRect(origin: p, size: .zero)
        invalidate(from: currentRect, to: newRect)
        currentRect = newRect
        previousRect = newRect
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        let newRect = Self.rect(from: start, to: p)
        invalidate(from: previousRect, to: newRect)
        currentRect = newRect
        previousRect = newRect
    }

    /// Mark only the union of the old and new selection rects as needing
    /// redraw (with a small inset so the 1-px border isn't clipped).
    /// AppKit then clips `draw(_:)`'s drawing context to this rect, so the
    /// existing fill code automatically becomes incremental.
    private func invalidate(from oldRect: NSRect?, to newRect: NSRect) {
        let union: NSRect
        if let oldRect = oldRect {
            union = oldRect.union(newRect)
        } else {
            union = newRect
        }
        // Inset by -2 to cover the 1-px stroke + AA fringe on both sides.
        let dirty = union.insetBy(dx: -2, dy: -2).intersection(bounds)
        if !dirty.isEmpty {
            setNeedsDisplay(dirty)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let host = host else { return }
        guard let rect = currentRect, rect.width >= 2, rect.height >= 2 else {
            host.onCancel?()
            return
        }
        // Convert from view coordinates to global AppKit screen coordinates.
        let origin = host.targetScreen.frame.origin
        let screenRect = NSRect(
            x: origin.x + rect.origin.x,
            y: origin.y + rect.origin.y,
            width: rect.width,
            height: rect.height
        )
        host.onFinish?(screenRect, host.targetScreen)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.35)
        dim.setFill()

        guard let sel = currentRect, sel.width > 0, sel.height > 0 else {
            bounds.fill()
            return
        }

        // Fill the dim region as a single path with even-odd rule: outer
        // rect minus the selection becomes the four "strips" in one draw
        // call. AppKit clips this to `dirtyRect`, so we still benefit from
        // the per-drag invalidation in `invalidate(from:to:)`.
        let mask = NSBezierPath()
        mask.appendRect(bounds)
        mask.appendRect(sel)
        mask.windingRule = .evenOdd
        mask.fill()

        // Selection border
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    private static func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
