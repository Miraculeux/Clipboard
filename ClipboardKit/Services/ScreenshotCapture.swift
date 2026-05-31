import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Coordinates an interactive screen-region snapshot.
///
/// On `begin()`, a dim gray overlay is shown over every connected display.
/// The user drags to define a rectangle (which becomes a clear "hole" in the
/// overlay). On mouse-up the overlay is dismissed and the selected region is
/// captured into `NSPasteboard.general` as an image. Pressing ESC cancels.
final class ScreenshotCapture: @unchecked Sendable {
    nonisolated(unsafe) static let shared = ScreenshotCapture()

    private var overlayWindows: [SelectionWindow] = []
    private var isActive = false
    /// Set to true once we have observed a real authorization failure from
    /// ScreenCaptureKit. While true, we refuse to call SCK again so that
    /// macOS does not keep popping its own TCC prompt on every hotkey press.
    private var authDenied = false

    private init() {}

    /// Show the selection overlay across every screen. No-op if already active.
    func begin() {
        let delay = SettingsManager.shared.captureDelaySeconds
        if delay > 0 {
            DispatchQueue.main.async { [weak self] in
                CountdownHUD.shared.start(seconds: delay) {
                    Task { @MainActor in await self?._begin(initialMode: .region) }
                }
            }
        } else {
            Task { @MainActor in await self._begin(initialMode: .region) }
        }
    }

    /// Skip the drag-to-select phase entirely and bring the overlay up
    /// already in window-pick mode, so the user can just click the desired
    /// window. Honors the capture delay like the other entry points.
    func captureWindow() {
        let delay = SettingsManager.shared.captureDelaySeconds
        if delay > 0 {
            DispatchQueue.main.async { [weak self] in
                CountdownHUD.shared.start(seconds: delay) {
                    Task { @MainActor in await self?._begin(initialMode: .window) }
                }
            }
        } else {
            Task { @MainActor in await self._begin(initialMode: .window) }
        }
    }

    /// Capture the entire main display in one shot. Honors the user's
    /// configured capture delay so a countdown still runs first.
    func captureFullScreen() {
        let delay = SettingsManager.shared.captureDelaySeconds
        if delay > 0 {
            DispatchQueue.main.async {
                CountdownHUD.shared.start(seconds: delay) {
                    Task { @MainActor in await self._captureFullScreen() }
                }
            }
        } else {
            Task { @MainActor in await self._captureFullScreen() }
        }
    }

    @MainActor
    private func _captureFullScreen() async {
        if authDenied { NSSound.beep(); return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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
            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = false
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            // Leave `bitmap.size` at its default (= cgImage pixel dimensions).
            // Overriding it to point size made the PNG encoder embed a pHYs
            // chunk that several viewers interpret as "this image is meant to
            // be shown at half resolution", which is what the user was seeing.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                NSSound.beep()
                return
            }
            // NSImage display size stays in points so the annotator renders
            // at natural on-screen size; the underlying CGImage carries the
            // full Retina pixel data either way.
            let image = NSImage(cgImage: cgImage, size: screen.frame.size)
            CaptureOutput.shared.deliver(pngData: pngData, image: image)
        } catch {
            let nsError = error as NSError
            print("Full-screen capture failed: \(nsError.domain) \(nsError.code) — \(error.localizedDescription)")
            if nsError.domain.contains("SCStream") || nsError.domain.contains("SCContent") {
                self.authDenied = true
            }
            NSSound.beep()
        }
    }

    @MainActor
    private func _begin(initialMode: SelectionView.CaptureMode) async {
        guard !isActive else { return }
        if authDenied {
            // Stay silent — prior attempt already informed the user. They can
            // re-grant via Settings → General → Permissions, then relaunch.
            NSSound.beep()
            return
        }
        isActive = true

        // Snapshot every connected display BEFORE the overlay window appears
        // so the dim/selection layer can show a perfect frozen mirror of
        // the desktop — including the system menu bar, which the overlay
        // (shielding level) would otherwise cover. The actual screenshot on
        // mouseUp re-captures the live screen via SCK so dynamic content
        // (clock seconds, notifications) is fresh.
        var snapshots: [NSScreen: CGImage] = [:]
        for screen in NSScreen.screens {
            if let img = await Self.snapshotScreen(screen) {
                snapshots[screen] = img
            }
        }

        overlayWindows = NSScreen.screens.map { screen in
            let w = SelectionWindow(screen: screen, snapshot: snapshots[screen])
            w.onFinish = { [weak self] rect, screen in
                self?.finish(with: rect, on: screen)
            }
            w.onFinishWindow = { [weak self] windowID, screen in
                self?.finishWindow(id: windowID, on: screen)
            }
            w.onCancel = { [weak self] in
                self?.cancel()
            }
            return w
        }
        // Exclude all overlay windows from window-pick hit testing.
        let overlayWindowNumbers = Set(overlayWindows.map { $0.windowNumber })
        overlayWindows.forEach { $0.ignoredWindowNumbers = overlayWindowNumbers }
        overlayWindows.forEach { $0.orderFrontRegardless() }

        // Optionally drop straight into window-pick mode so the user doesn't
        // have to press Space first when invoking the dedicated hotkey.
        if initialMode == .window {
            overlayWindows.forEach { $0.setInitialMode(.window) }
        }

        NSApp.activate()
        overlayWindows.first?.makeKey()
    }

    /// Capture a still image of `screen` via ScreenCaptureKit. Used as the
    /// frozen background for the selection overlay so the menu bar (and
    /// anything else under the shielding-level overlay) remains visible to
    /// the user while they drag a selection.
    @MainActor
    private static func snapshotScreen(_ screen: NSScreen) async -> CGImage? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }

    /// User pressed ESC or made a zero-sized selection. Tear down without capturing.
    func cancel() {
        teardown()
    }

    /// Called by a SelectionWindow when the user finished a drag.
    /// `screenRect` is in AppKit global screen coordinates (origin bottom-left of primary display).
    /// `targetScreen` is the screen the selection was made on.
    @MainActor
    func finish(with screenRect: NSRect, on targetScreen: NSScreen) {
        teardown()
        // Give the windows a moment to actually disappear from the compositor
        // before snapping the screen, otherwise the dim overlay would be captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in
                await self.captureAndCopy(screenRect: screenRect, screen: targetScreen)
            }
        }
    }

    /// Window-mode finish: capture exactly the chosen window via
    /// `SCContentFilter(desktopIndependentWindow:)`, which crops the shadow
    /// area automatically — so the resulting PNG has no extra border.
    @MainActor
    func finishWindow(id windowID: CGWindowID, on targetScreen: NSScreen) {
        teardown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in
                await self.captureWindowAndCopy(windowID: windowID, screen: targetScreen)
            }
        }
    }

    private func teardown() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        isActive = false
    }

    @MainActor
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
            //
            // Important: DON'T set `bitmap.size = screenRect.size`. That would
            // force the encoder to write a low-DPI pHYs chunk, and many viewers
            // then render the file at half its actual pixel size.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                print("Screenshot: failed to encode image data")
                NSSound.beep()
                return
            }

            await MainActor.run {
                let image = NSImage(cgImage: cgImage, size: screenRect.size)
                CaptureOutput.shared.deliver(pngData: pngData, image: image)
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

    @MainActor
    private func captureWindowAndCopy(windowID: CGWindowID, screen: NSScreen) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                NSSound.beep()
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let scale = screen.backingScaleFactor
            let contentRect = filter.contentRect
            guard contentRect.width > 0, contentRect.height > 0 else {
                NSSound.beep()
                return
            }

            let config = SCStreamConfiguration()
            config.width = Int(contentRect.width * scale)
            config.height = Int(contentRect.height * scale)
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            // See the full-screen path above: keep `bitmap.size` at its
            // pixel-dimension default so the PNG file isn't tagged with a
            // half-resolution pHYs hint.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                NSSound.beep()
                return
            }

            await MainActor.run {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: contentRect.width, height: contentRect.height))
                CaptureOutput.shared.deliver(pngData: pngData, image: image)
            }
        } catch {
            let nsError = error as NSError
            print("Window screenshot capture failed: \(nsError.domain) \(nsError.code) — \(error.localizedDescription)")
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
    var onFinish: (@MainActor (NSRect, NSScreen) -> Void)?
    var onFinishWindow: (@MainActor (CGWindowID, NSScreen) -> Void)?
    var onCancel: (@MainActor () -> Void)?
    var ignoredWindowNumbers: Set<Int> = [] {
        didSet {
            (contentView as? SelectionView)?.ignoredWindowNumbers = ignoredWindowNumbers
        }
    }

    init(screen: NSScreen, snapshot: CGImage? = nil) {
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
        // Always sit at shielding level so clicks anywhere on screen —
        // including over the menu bar area — reach this overlay instead of
        // being stolen by the system menu bar. The menu bar is visually
        // hidden by us; we paint a frozen snapshot underneath so the user
        // can still aim at it.
        self.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        self.acceptsMouseMovedEvents = true

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.host = self
        view.snapshot = snapshot
        self.contentView = view
        self.setFrame(screen.frame, display: true)
        self.invalidateCursorRects(for: view)

        // Hide the overlay from the Accessibility tree. Without this, the
        // sub-element hit test (which walks the AX tree at the cursor
        // position) lands on OUR overlay window first and returns its full
        // screen-sized frame — the user sees "drilling does nothing".
        self.setAccessibilityElement(false)
        self.setAccessibilityHidden(true)
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Force the overlay into a specific capture mode at start. Used by the
    /// dedicated window-screenshot entry point so the user doesn't have to
    /// press Space first.
    func setInitialMode(_ mode: SelectionView.CaptureMode) {
        guard let view = contentView as? SelectionView else { return }
        view.setCaptureMode(mode)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
            return
        }
        if event.keyCode == 49 { // Space
            (contentView as? SelectionView)?.toggleCaptureMode()
            return
        }
        if let view = contentView as? SelectionView,
           view.handleArrowKey(keyCode: Int(event.keyCode), shift: event.modifierFlags.contains(.shift)) {
            return
        }
        super.keyDown(with: event)
    }
}

final class SelectionView: NSView {
    enum CaptureMode {
        case region
        case window
    }

    weak var host: SelectionWindow?
    var ignoredWindowNumbers: Set<Int> = []
    /// Frozen mirror of this screen captured just before the overlay was
    /// shown. Rendered as the bottom layer so dim/selection-hole drawing
    /// reveals the menu bar and any windows beneath the shielding-level
    /// overlay.
    var snapshot: CGImage?

    private var captureMode: CaptureMode = .region

    private var startPoint: NSPoint?
    private var currentRect: NSRect?
    /// In window mode, the CGWindowID currently under the cursor.
    private var currentWindowID: CGWindowID?
    /// In sub-element mode (window mode + ⌥ held), the AX-resolved rect
    /// under the cursor in this view's coordinate space. When non-nil the
    /// mouseUp handler treats the action as a region capture instead of a
    /// window capture (SCK has no sub-window filter).
    private var currentSubElementViewRect: NSRect?
    /// AX ancestor chain at the current cursor position (leaf first). Lets
    /// the scroll wheel walk between granularities — e.g. tree row → list →
    /// File Explorer panel → whole VS Code window.
    private var currentSubElementChain: [NSRect] = []
    private var currentSubElementRoles: [String?] = []
    /// Index into `currentSubElementChain`. 0 = deepest leaf, larger values
    /// climb toward the window. Reset whenever the cursor moves to a
    /// different leaf so a new hover starts from "smallest" again.
    private var subElementDepth: Int = 0
    /// Accumulated scroll delta so a single notch advances depth even when
    /// the trackpad emits small fractional values.
    private var scrollAccumulator: CGFloat = 0
    /// Cached state of the ⌥ modifier between flags-changed events. We use
    /// it to decide between whole-window and sub-element resolution on the
    /// next `mouseMoved`/`mouseUp`.
    private var optionHeld: Bool = false
    /// Set when we observe `optionHeld && AX not trusted` so the overlay
    /// can show a centered banner and we only pop the system Alert once
    /// per session.
    private var axPermissionDenied: Bool = false
    private var axAlertShown: Bool = false
    /// Previous selection rect, used to compute a minimal dirty union so we
    /// don't invalidate the whole (potentially 5K) overlay on every drag
    /// frame. Without this, ProMotion can fire `mouseDragged` ~120 times per
    /// second, each repainting millions of pixels.
    private var previousRect: NSRect?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func toggleCaptureMode() {
        switch captureMode {
        case .region:
            captureMode = .window
            startPoint = nil
            previousRect = nil
            let oldRect = currentRect
            currentRect = nil
            currentSubElementViewRect = nil
            currentSubElementChain = []
            currentSubElementRoles = []
            subElementDepth = 0
            scrollAccumulator = 0
            if let oldRect {
                invalidate(from: oldRect, to: oldRect)
            }
        case .window:
            captureMode = .region
            let oldRect = currentRect
            currentRect = nil
            previousRect = nil
            currentSubElementViewRect = nil
            currentSubElementChain = []
            currentSubElementRoles = []
            subElementDepth = 0
            scrollAccumulator = 0
            currentWindowID = nil
            if let oldRect {
                invalidate(from: oldRect, to: oldRect)
            }
        }
        setNeedsDisplay(bounds)
    }

    /// Idempotent variant of `toggleCaptureMode` used at overlay startup so
    /// the dedicated window-screenshot hotkey lands directly in window mode.
    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode else { return }
        toggleCaptureMode()
    }

    override func mouseDown(with event: NSEvent) {
        if captureMode == .window {
            // Re-sync ⌥ from the click event in case flagsChanged was
            // missed (e.g. modifier pressed before the overlay became key).
            optionHeld = event.modifierFlags.contains(.option)
            updateWindowSelectionFromCursor()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        let newRect = NSRect(origin: p, size: .zero)
        invalidate(from: currentRect, to: newRect)
        currentRect = newRect
        previousRect = newRect
    }

    override func mouseDragged(with event: NSEvent) {
        guard captureMode == .region else { return }
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        let constrained = event.modifierFlags.contains(.shift)
        let newRect = constrained ? Self.squareRect(from: start, to: p)
                                  : Self.rect(from: start, to: p)
        invalidate(from: previousRect, to: newRect)
        currentRect = newRect
        previousRect = newRect
    }

    /// Arrow keys nudge the current selection while in region mode. Shift
    /// boosts the step to 10px. Returns whether the key was consumed.
    @discardableResult
    func handleArrowKey(keyCode: Int, shift: Bool) -> Bool {
        guard captureMode == .region, var rect = currentRect else { return false }
        let step: CGFloat = shift ? 10 : 1
        switch keyCode {
        case 123: rect.origin.x -= step // left
        case 124: rect.origin.x += step // right
        case 125: rect.origin.y -= step // down (AppKit y-up)
        case 126: rect.origin.y += step // up
        default: return false
        }
        rect = rect.intersection(bounds)
        invalidate(from: currentRect, to: rect)
        currentRect = rect
        previousRect = rect
        return true
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
        // Inflate enough to cover (a) the 1-px stroke + AA fringe, and
        // (b) the "WxH" badge floating just outside the selection.
        let dirty = union.insetBy(dx: -120, dy: -40).intersection(bounds)
        if !dirty.isEmpty {
            setNeedsDisplay(dirty)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard captureMode == .window else { return }
        optionHeld = event.modifierFlags.contains(.option)
        updateWindowSelectionFromCursor()
    }

    /// Track ⌥ even when the mouse isn't moving so the highlight switches
    /// the moment the user presses the modifier.
    override func flagsChanged(with event: NSEvent) {
        guard captureMode == .window else {
            super.flagsChanged(with: event)
            return
        }
        let now = event.modifierFlags.contains(.option)
        if now != optionHeld {
            optionHeld = now
            updateWindowSelectionFromCursor()
            setNeedsDisplay(bounds)   // refresh hint label
        }
    }

    private func updateWindowSelectionFromCursor() {
        // ⌥ held → drill into sub-window elements via Accessibility API.
        if optionHeld {
            refreshSubElementChain()
            if let sub = currentSubElementRect() {
                invalidate(from: currentRect, to: sub)
                currentRect = sub
                previousRect = sub
                currentSubElementViewRect = sub
                currentWindowID = nil
                return
            }
        }

        let hit = windowUnderCursor()

        // The menu bar is rendered as a single CGWindow that visually
        // contains every status item (Wi-Fi, Bluetooth, clock, …). When
        // the user is hovering over it, fall through to the AX hit test
        // so they can pick an individual item without holding ⌥. The
        // resulting rect goes through the region capture path because
        // SCK can't filter individual menu-bar items.
        if let hit, hit.isOverlayWindow,
           let host,
           let cursorCG = CGEvent(source: nil)?.location,
           AXHitTester.ensureTrusted(prompt: false),
           let menuHit = AXHitTester.menuBarItem(at: cursorCG) {
            let leaf = Self.appKitViewRect(fromCG: menuHit.cgRect, on: host.targetScreen)
            if leaf.width >= 4, leaf.height >= 4 {
                invalidate(from: currentRect, to: leaf)
                currentRect = leaf
                previousRect = leaf
                currentSubElementViewRect = leaf
                currentWindowID = nil
                currentSubElementChain = [leaf]
                currentSubElementRoles = [menuHit.role]
                subElementDepth = 0
                return
            }
        }

        let newRect = hit?.viewRect
        invalidate(from: currentRect, to: newRect ?? .zero)
        currentRect = newRect
        previousRect = newRect
        currentWindowID = hit?.windowID
        // Menu bar / status item windows can't be reliably captured via
        // SCK's per-window filter, so route them through the region path
        // by stashing the rect here. mouseUp prefers `currentSubElementViewRect`
        // over `currentWindowID` when both are present.
        if let hit, hit.isOverlayWindow {
            currentSubElementViewRect = hit.viewRect
        } else {
            currentSubElementViewRect = nil
        }
        currentSubElementChain = []
        currentSubElementRoles = []
        subElementDepth = 0
        if newRect == nil {
            setNeedsDisplay(bounds)
        }
    }

    /// Re-walk the AX tree under the cursor and replace `currentSubElementChain`.
    /// Resets `subElementDepth` to 0 when the leaf moves to a different element
    /// (different origin or significantly different size) so a new hover starts
    /// from the smallest meaningful sub-window.
    private func refreshSubElementChain(ownerPID: pid_t? = nil) {
        guard let host else { return }
        guard let cursorCG = CGEvent(source: nil)?.location else { return }
        guard AXHitTester.ensureTrusted(prompt: true) else {
            currentSubElementChain = []
            currentSubElementRoles = []
            if !axPermissionDenied {
                axPermissionDenied = true
                presentAXPermissionAlertIfNeeded()
            }
            return
        }
        axPermissionDenied = false
        guard let chain = AXHitTester.chain(at: cursorCG, ownerPID: ownerPID), !chain.hits.isEmpty else {
            currentSubElementChain = []
            currentSubElementRoles = []
            return
        }

        let viewRects = chain.hits.map { Self.appKitViewRect(fromCG: $0.cgRect, on: host.targetScreen) }
        let roles = chain.hits.map { $0.role }

        let leafChanged: Bool = {
            guard let previousLeaf = currentSubElementChain.first,
                  let newLeaf = viewRects.first else { return true }
            return abs(previousLeaf.minX - newLeaf.minX) > 2 ||
                   abs(previousLeaf.minY - newLeaf.minY) > 2 ||
                   abs(previousLeaf.width - newLeaf.width) > 2 ||
                   abs(previousLeaf.height - newLeaf.height) > 2
        }()
        if leafChanged {
            subElementDepth = 0
            scrollAccumulator = 0
        }

        currentSubElementChain = viewRects
        currentSubElementRoles = roles
        subElementDepth = min(subElementDepth, max(0, viewRects.count - 1))
    }

    private func currentSubElementRect() -> NSRect? {
        guard !currentSubElementChain.isEmpty else { return nil }
        let clamped = min(max(0, subElementDepth), currentSubElementChain.count - 1)
        return currentSubElementChain[clamped]
    }

    /// One-shot NSAlert with a deeplink to the Accessibility pane. Stays
    /// out of the way after the user has dismissed it once per overlay
    /// session so the rest of the capture flow still works.
    private func presentAXPermissionAlertIfNeeded() {
        guard !axAlertShown else { return }
        axAlertShown = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility permission required"
            alert.informativeText = "To pick a sub-window (e.g. VS Code's File Explorer), grant ClipboardKit access in System Settings → Privacy & Security → Accessibility, then try again."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Scroll wheel in sub-element mode walks the AX ancestor chain.
    /// Scrolling UP climbs toward the window (larger panel), scrolling DOWN
    /// returns to the deepest leaf. Lets users dial in the right granularity
    /// for sub-windows like VS Code's File Explorer or the integrated panel.
    override func scrollWheel(with event: NSEvent) {
        guard captureMode == .window, optionHeld, !currentSubElementChain.isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        scrollAccumulator += event.scrollingDeltaY
        let threshold: CGFloat = 6
        var changed = false
        while scrollAccumulator >= threshold {
            scrollAccumulator -= threshold
            if subElementDepth < currentSubElementChain.count - 1 {
                subElementDepth += 1
                changed = true
            }
        }
        while scrollAccumulator <= -threshold {
            scrollAccumulator += threshold
            if subElementDepth > 0 {
                subElementDepth -= 1
                changed = true
            }
        }
        guard changed, let sub = currentSubElementRect() else { return }
        invalidate(from: currentRect, to: sub)
        currentRect = sub
        previousRect = sub
        currentSubElementViewRect = sub
        currentWindowID = nil
        setNeedsDisplay(bounds) // refresh hint label with new depth/role
    }

    private struct WindowHit {
        let windowID: CGWindowID
        /// Window bounds expressed in this overlay view's coordinate space.
        let viewRect: NSRect
        /// True for windows above the normal layer (menu bar, status items,
        /// Dock, etc.). SCK's per-window capture filter often refuses to
        /// snapshot these, so mouseUp routes them through the region path
        /// using `viewRect`.
        let isOverlayWindow: Bool
        /// PID of the process owning this CGWindow. The menu bar in modern
        /// macOS is split across processes (foreground app for menu titles,
        /// ControlCenter for status items), so the AX sub-element hit test
        /// needs the owner to query the right tree.
        let ownerPID: pid_t
    }

    /// Hit-test the window stack using CG global coordinates (cursor from
    /// `CGEvent`), then convert the matching window's CG rect back into this
    /// overlay view's AppKit coords for the hover highlight. Walks the list
    /// in front-to-back order; when several windows contain the cursor it
    /// returns the smallest by area so menu bar status items (Wi-Fi, clock)
    /// win over the full menu bar that visually contains them.
    private func windowUnderCursor() -> WindowHit? {
        guard let host else { return nil }
        guard let cursorCG = CGEvent(source: nil)?.location else { return nil }

        guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Anything at or below the main-menu layer is fair game (regular
        // windows = 0, Dock = 20, menu bar / status items = ~24–25). Higher
        // layers belong to cursors, drag images, the screenshot HUD, etc.
        let menuBarLayer = Int(CGWindowLevelForKey(.mainMenuWindow))

        var best: (hit: WindowHit, area: CGFloat)?
        for info in rawList {
            guard let windowNumberInt = info[kCGWindowNumber as String] as? Int else { continue }
            if ignoredWindowNumbers.contains(windowNumberInt) { continue }

            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            if layer < 0 || layer > menuBarLayer { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (boundsDict["X"] as? NSNumber)?.doubleValue,
                  let y = (boundsDict["Y"] as? NSNumber)?.doubleValue,
                  let width = (boundsDict["Width"] as? NSNumber)?.doubleValue,
                  let height = (boundsDict["Height"] as? NSNumber)?.doubleValue else {
                continue
            }
            let windowBoundsCG = CGRect(x: x, y: y, width: width, height: height)
            if windowBoundsCG.isEmpty { continue }

            if windowBoundsCG.contains(cursorCG) {
                let viewRect = Self.appKitViewRect(fromCG: windowBoundsCG, on: host.targetScreen)
                let area = windowBoundsCG.width * windowBoundsCG.height
                let pid = (info[kCGWindowOwnerPID as String] as? pid_t) ?? 0
                let hit = WindowHit(windowID: CGWindowID(windowNumberInt),
                                    viewRect: viewRect,
                                    isOverlayWindow: layer != 0,
                                    ownerPID: pid)
                if layer == 0 {
                    // Regular windows respect z-order: first match wins,
                    // matching the platform's normal hit test.
                    return hit
                }
                // Overlay windows (menu bar / status items) overlap each
                // other (the whole menu bar contains every individual
                // status item). Keep the smallest so the user can aim at
                // Wi-Fi instead of the entire bar.
                if best == nil || area < best!.area {
                    best = (hit, area)
                }
            }
        }
        return best?.hit
    }

    /// Convert a CG global rect (origin top-left of primary display) into the
    /// overlay view's AppKit coordinates (origin bottom-left of `screen`).
    private static func appKitViewRect(fromCG cgRect: CGRect, on screen: NSScreen) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let appKitGlobalY = primaryHeight - (cgRect.origin.y + cgRect.height)
        return NSRect(
            x: cgRect.origin.x - screen.frame.origin.x,
            y: appKitGlobalY - screen.frame.origin.y,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let host = host else { return }
        if captureMode == .window {
            optionHeld = event.modifierFlags.contains(.option)
            updateWindowSelectionFromCursor()
            // ⌥ held: AX resolved a sub-window element. Capture that exact
            // rect as a region — SCK's window filter would re-expand to the
            // whole window, so we go through the region path instead.
            if let subRect = currentSubElementViewRect {
                let origin = host.targetScreen.frame.origin
                let screenRect = NSRect(
                    x: origin.x + subRect.origin.x,
                    y: origin.y + subRect.origin.y,
                    width: subRect.width,
                    height: subRect.height
                )
                host.onFinish?(screenRect, host.targetScreen)
                return
            }
            guard let windowID = currentWindowID else {
                host.onCancel?()
                return
            }
            host.onFinishWindow?(windowID, host.targetScreen)
            return
        }
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
        // Paint the frozen screen snapshot first so the user can see
        // everything beneath the overlay — including the menu bar — even
        // though the overlay itself sits at shielding level.
        if let snapshot, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.draw(snapshot, in: bounds)
            ctx.restoreGState()
        }

        let dim = NSColor.black.withAlphaComponent(0.35)
        dim.setFill()

        guard let sel = currentRect, sel.width > 0, sel.height > 0 else {
            bounds.fill()
            drawHint()
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

        drawSizeBadge(for: sel)
        drawHint()
    }

    /// Floating "WxH" pill anchored just outside the selection (below if
    /// there's room, otherwise above) so the user can size precisely.
    private func drawSizeBadge(for sel: NSRect) {
        // Show in region mode always, and in sub-element mode so the user
        // can see how scroll-wheel depth changes the captured size.
        let inSubMode = captureMode == .window && optionHeld && !currentSubElementChain.isEmpty
        guard captureMode == .region || inSubMode, sel.width >= 1, sel.height >= 1 else { return }
        var label = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
        if inSubMode {
            let depth = subElementDepth + 1
            let total = currentSubElementChain.count
            let role = currentSubElementRoles.indices.contains(subElementDepth)
                ? (currentSubElementRoles[subElementDepth] ?? "")
                : ""
            let roleSuffix = role.isEmpty ? "" : " · \(role.replacingOccurrences(of: "AX", with: ""))"
            label += "   [\(depth)/\(total)\(roleSuffix)]"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: label, attributes: attrs)
        let textSize = text.size()
        let pad: CGFloat = 6
        let badgeSize = NSSize(width: textSize.width + pad * 2, height: textSize.height + pad)

        // Prefer below; fall back to above when near bottom of screen.
        let belowY = sel.minY - badgeSize.height - 6
        let aboveY = sel.maxY + 6
        let badgeOrigin: NSPoint
        if belowY >= 4 {
            badgeOrigin = NSPoint(x: sel.minX, y: belowY)
        } else {
            badgeOrigin = NSPoint(x: sel.minX, y: aboveY)
        }
        let badgeRect = NSRect(origin: badgeOrigin, size: badgeSize)

        NSColor.black.withAlphaComponent(0.75).setFill()
        let bg = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        bg.fill()
        text.draw(at: NSPoint(x: badgeOrigin.x + pad, y: badgeOrigin.y + pad / 2))
    }

    private func drawHint() {
        let hint: String
        switch captureMode {
        case .region:
            hint = "Drag to select · Shift: square · ←→↑↓: nudge (⇧×10) · Space: Window mode · Esc: Cancel"
        case .window:
            if optionHeld {
                if axPermissionDenied {
                    hint = "Accessibility permission required for sub-element mode — grant ClipboardKit in System Settings, then re-trigger the hotkey"
                } else if currentSubElementChain.isEmpty {
                    hint = "Sub-element mode (⌥): hover a panel · release ⌥ for whole window"
                } else {
                    hint = "Sub-element (⌥): scroll ↑↓ to resize (panel ↔ control) · click to capture · release ⌥ for whole window"
                }
            } else {
                hint = "Window mode: click to capture whole window · hold ⌥ to pick a sub-element (e.g. File Explorer) · Space: Region mode"
            }
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ]
        let text = NSAttributedString(string: hint, attributes: attrs)
        let size = text.size()
        let origin = NSPoint(x: 16, y: bounds.height - size.height - 16)
        text.draw(at: origin)
    }

    private static func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Same as `rect(from:to:)` but constrained to a square that grows in the
    /// direction the user actually dragged — used when Shift is held.
    private static func squareRect(from a: NSPoint, to b: NSPoint) -> NSRect {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let side = max(abs(dx), abs(dy))
        let endX = a.x + (dx >= 0 ? side : -side)
        let endY = a.y + (dy >= 0 ? side : -side)
        return NSRect(
            x: min(a.x, endX),
            y: min(a.y, endY),
            width: side,
            height: side
        )
    }
}

// MARK: - Countdown HUD (delayed capture)

/// Tiny floating numeric countdown shown before the selection overlay
/// appears, so the user can stage menus / content before the capture.
final class CountdownHUD: @unchecked Sendable {
    nonisolated(unsafe) static let shared = CountdownHUD()

    private var panel: NSPanel?
    private var timer: Timer?
    private var remaining: Int = 0
    private var label: NSTextField?
    private var completion: (() -> Void)?

    private init() {}

    func start(seconds: Int, completion: @escaping () -> Void) {
        cancel()
        guard seconds > 0 else { completion(); return }
        self.remaining = seconds
        self.completion = completion

        let size = NSSize(width: 140, height: 140)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false

        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        bg.layer?.cornerRadius = 16

        let lbl = NSTextField(labelWithString: "\(remaining)")
        lbl.font = NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        lbl.textColor = .white
        lbl.alignment = .center
        lbl.frame = bg.bounds
        lbl.autoresizingMask = [.width, .height]
        bg.addSubview(lbl)
        p.contentView = bg
        self.label = lbl

        // Position centered on the main screen.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                     y: f.midY - size.height / 2))
        }
        p.orderFrontRegardless()
        self.panel = p

        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            let done = completion
            cancel()
            done?()
        } else {
            label?.stringValue = "\(remaining)"
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        label = nil
        completion = nil
    }
}
