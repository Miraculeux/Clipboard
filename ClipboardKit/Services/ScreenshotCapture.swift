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
            SelectionWindow(screen: screen, coordinator: self)
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
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            bitmap.size = screenRect.size
            guard let pngData = bitmap.representation(using: .png, properties: [:]),
                  let tiffData = bitmap.tiffRepresentation else {
                print("Screenshot: failed to encode image data")
                NSSound.beep()
                return
            }

            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(pngData, forType: .png)
                pb.setData(tiffData, forType: .tiff)
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

private final class SelectionWindow: NSWindow {
    weak var coordinator: ScreenshotCapture?
    let targetScreen: NSScreen

    init(screen: NSScreen, coordinator: ScreenshotCapture) {
        self.targetScreen = screen
        self.coordinator = coordinator
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
            coordinator?.cancel()
            return
        }
        super.keyDown(with: event)
    }
}

private final class SelectionView: NSView {
    weak var host: SelectionWindow?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        currentRect = NSRect(origin: p, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = Self.rect(from: start, to: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let host = host, let coordinator = host.coordinator else { return }
        guard let rect = currentRect, rect.width >= 2, rect.height >= 2 else {
            coordinator.cancel()
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
        coordinator.finish(with: screenRect, on: host.targetScreen)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.35)
        dim.setFill()

        guard let sel = currentRect, sel.width > 0, sel.height > 0 else {
            bounds.fill()
            return
        }

        let b = bounds
        // Top strip
        NSRect(x: b.minX, y: sel.maxY, width: b.width, height: b.maxY - sel.maxY).fill()
        // Bottom strip
        NSRect(x: b.minX, y: b.minY, width: b.width, height: sel.minY - b.minY).fill()
        // Left strip (between top and bottom strips)
        NSRect(x: b.minX, y: sel.minY, width: sel.minX - b.minX, height: sel.height).fill()
        // Right strip
        NSRect(x: sel.maxX, y: sel.minY, width: b.maxX - sel.maxX, height: sel.height).fill()

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
