import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Coordinates an interactive **long (scrolling) screenshot** capture.
///
/// Flow:
///   1. `toggle()` shows the same drag-to-select overlay used by `ScreenshotCapture`.
///   2. After the user picks a region, a small floating "Recording" panel appears
///      outside the region. The selected region is repeatedly captured (~8 fps).
///   3. The user scrolls the underlying content. Each new frame is vertically
///      aligned against the bottom of the accumulated canvas and the newly
///      revealed rows are appended.
///   4. Pressing the hotkey again, clicking **Done**, or pressing Return finishes
///      the capture; the stitched PNG is written to `NSPasteboard.general`.
///      Pressing **Cancel** or Esc throws the result away.
final class LongScreenshotCapture {
    static let shared = LongScreenshotCapture()

    private var overlayWindows: [SelectionWindow] = []
    private var indicator: LongCaptureIndicatorPanel?
    private var stitcher: VerticalStitcher?

    private var captureFilter: SCContentFilter?
    private var captureConfig: SCStreamConfiguration?

    private var isSelecting = false
    private var isCapturing = false
    private var authDenied = false

    private init() {}

    /// Public entry point — called by the global hotkey.
    /// Behavior depends on current state:
    ///   • idle              → show selection overlay
    ///   • selecting region  → cancel selection
    ///   • capturing frames  → stop and commit result
    func toggle() {
        DispatchQueue.main.async {
            if self.isCapturing {
                self.stop(commit: true)
            } else if self.isSelecting {
                self.cancelSelection()
            } else {
                self.beginSelection()
            }
        }
    }

    // MARK: - Selection phase

    private func beginSelection() {
        if authDenied { NSSound.beep(); return }
        guard !isSelecting, !isCapturing else { return }
        isSelecting = true

        overlayWindows = NSScreen.screens.map { screen in
            let w = SelectionWindow(screen: screen)
            w.onFinish = { [weak self] rect, screen in
                self?.startCapture(rect: rect, on: screen)
            }
            w.onCancel = { [weak self] in
                self?.cancelSelection()
            }
            return w
        }
        overlayWindows.forEach { $0.orderFrontRegardless() }
        NSApp.activate()
        overlayWindows.first?.makeKey()
    }

    private func teardownOverlay() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
    }

    private func cancelSelection() {
        teardownOverlay()
        isSelecting = false
    }

    // MARK: - Capture phase

    private func startCapture(rect screenRect: NSRect, on screen: NSScreen) {
        teardownOverlay()
        isSelecting = false

        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            NSSound.beep()
            return
        }

        // Same AppKit→top-left conversion ScreenshotCapture does.
        let originX = screenRect.origin.x - screen.frame.origin.x
        let originYFromTop = screen.frame.height - ((screenRect.origin.y - screen.frame.origin.y) + screenRect.height)
        let sourceRect = CGRect(x: originX, y: originYFromTop, width: screenRect.width, height: screenRect.height)
        let scale = screen.backingScaleFactor

        // Show the indicator panel BEFORE building the SCContentFilter so we can
        // exclude its window from capture (otherwise it would be stitched in).
        let indicator = LongCaptureIndicatorPanel()
        indicator.statusText = "Scroll to capture…"
        indicator.onDone = { [weak self] in self?.stop(commit: true) }
        indicator.onCancel = { [weak self] in self?.stop(commit: false) }
        positionIndicator(indicator, near: screenRect, on: screen)
        indicator.orderFrontRegardless()
        self.indicator = indicator

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                    NSSound.beep()
                    self.indicator?.orderOut(nil); self.indicator = nil
                    return
                }
                // Exclude our own indicator panel so it doesn't appear in stitched output.
                let indicatorWindowID = CGWindowID(indicator.windowNumber)
                let excluded = content.windows.filter { $0.windowID == indicatorWindowID }

                let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
                let config = SCStreamConfiguration()
                config.sourceRect = sourceRect
                config.width = Int(screenRect.width * scale)
                config.height = Int(screenRect.height * scale)
                config.showsCursor = false
                config.capturesAudio = false
                config.scalesToFit = false

                self.captureFilter = filter
                self.captureConfig = config
                self.stitcher = VerticalStitcher()
                self.isCapturing = true

                // Give compositor a moment so the dim overlay is gone from the screen.
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.runCaptureLoop()
            } catch {
                let nsError = error as NSError
                print("Long screenshot setup failed: \(nsError.domain) \(nsError.code) — \(error.localizedDescription)")
                if nsError.domain.contains("SCStream") || nsError.domain.contains("SCContent") {
                    self.authDenied = true
                }
                NSSound.beep()
                self.indicator?.orderOut(nil); self.indicator = nil
            }
        }
    }

    private func runCaptureLoop() {
        Task { @MainActor in
            while self.isCapturing {
                await self.captureOneFrame()
                try? await Task.sleep(nanoseconds: 120_000_000) // ~8 fps
            }
        }
    }

    private func captureOneFrame() async {
        guard let filter = captureFilter, let config = captureConfig, let stitcher = stitcher else { return }
        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let result = stitcher.add(frame: cgImage)
            await MainActor.run {
                let h = stitcher.height
                switch result {
                case .firstFrame(let rows):
                    self.indicator?.statusText = "Recording · \(h)px"
                    print("LongShot: first frame \(rows) rows")
                    self.indicator?.flashAppend()
                case .appended(let rows, let perPixel):
                    self.indicator?.statusText = "Recording · \(h)px (+\(rows))"
                    print("LongShot: appended \(rows) rows, perPixel=\(Int(perPixel))")
                    self.indicator?.flashAppend()
                case .duplicate:
                    self.indicator?.statusText = "Scroll to continue… \(h)px"
                case .lowConfidence(let perPixel, let bestS):
                    self.indicator?.statusText = "Scroll slower… \(h)px"
                    print("LongShot: low confidence perPixel=\(Int(perPixel)) bestS=\(bestS)")
                case .widthMismatch:
                    self.indicator?.statusText = "Width changed, stopping"
                    print("LongShot: width mismatch, aborting")
                    self.isCapturing = false
                }
            }
        } catch {
            print("LongShot: frame capture failed: \(error)")
        }
    }

    private func stop(commit: Bool) {
        guard isCapturing || indicator != nil else { return }
        isCapturing = false
        indicator?.orderOut(nil)
        indicator = nil

        if commit, let stitcher = stitcher, let cgImage = stitcher.finalize() {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(png, forType: .png)
            } else {
                NSSound.beep()
            }
        }

        stitcher = nil
        captureFilter = nil
        captureConfig = nil
    }

    // MARK: - Indicator placement

    /// Position the indicator panel just above the selected region (or below
    /// it if there isn't enough room) — and always inside the target screen.
    private func positionIndicator(_ panel: NSPanel, near captureRect: NSRect, on screen: NSScreen) {
        let panelSize = panel.frame.size
        let margin: CGFloat = 12
        let screenFrame = screen.frame

        // Prefer placement above the selection in AppKit coords (y up).
        var x = captureRect.midX - panelSize.width / 2
        var y = captureRect.maxY + margin
        if y + panelSize.height > screenFrame.maxY {
            // Not enough room above — try below.
            y = captureRect.minY - margin - panelSize.height
        }
        if y < screenFrame.minY {
            // Clamp inside screen as a last resort.
            y = screenFrame.minY + margin
        }
        x = max(screenFrame.minX + margin, min(x, screenFrame.maxX - panelSize.width - margin))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Indicator panel

/// Small floating panel with status + Done / Cancel buttons.
/// Uses `.nonactivatingPanel` so it doesn't steal focus from the app the user
/// is scrolling. It's a borderless panel — drag from anywhere to move it.
final class LongCaptureIndicatorPanel: NSPanel {
    private let statusLabel = NSTextField(labelWithString: "")
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let dot = NSView()

    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    var statusText: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
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
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false

        let bg = NSVisualEffectView(frame: .zero)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        bg.translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail

        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(handleDone)
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.keyEquivalent = "\u{1b}" // Esc
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 64))
        content.addSubview(bg)
        content.addSubview(dot)
        content.addSubview(statusLabel)
        content.addSubview(cancelButton)
        content.addSubview(doneButton)

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: content.topAnchor),
            bg.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            dot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

            cancelButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -6),
            cancelButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            doneButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        self.contentView = content

        // Slow pulsing dot — indicates capture is live.
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.3
        anim.duration = 0.9
        anim.autoreverses = true
        anim.repeatCount = .infinity
        dot.layer?.add(anim, forKey: "pulse")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Briefly tint the dot green when a frame contributed new rows.
    func flashAppend() {
        let original = NSColor.systemRed.cgColor
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.dot.layer?.backgroundColor = original
        }
    }

    @objc private func handleDone() { onDone?() }
    @objc private func handleCancel() { onCancel?() }
}

// MARK: - Vertical stitcher

/// Accumulates a growing vertical canvas by aligning each new frame against
/// the bottom of the canvas using a downsampled-grayscale cross-strip search.
///
/// Coordinate convention: frame row 0 is the TOP. When the user scrolls the
/// content downward, the new frame's content has shifted UP, so the canvas's
/// bottom strip matches a strip somewhere in the upper half of the new frame.
/// We then append the rows below that strip as freshly-revealed content.
final class VerticalStitcher {
    enum AddResult {
        case firstFrame(rows: Int)
        case appended(rows: Int, perPixel: Double)
        case duplicate
        case lowConfidence(perPixel: Double, bestS: Int)
        case widthMismatch
    }

    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var frameCount: Int = 0

    private var rgba: [UInt8] = []   // width * height * 4 (RGBA premultiplied)
    private var gray: [UInt8] = []   // grayWidth * height (downsampled luma for matching)
    private let grayWidth = 64

    /// Confidence threshold for matching (sum-of-squared-diff per gray sample).
    /// Raised from initial 600 so that anti-aliased text, font hinting and
    /// subpixel scroll positions still pass.
    private let perPixelRejectThreshold: Double = 3500

    func add(frame: CGImage) -> AddResult {
        frameCount += 1
        guard let frameRGBA = Self.rgbaBytes(of: frame) else { return .duplicate }
        let frameW = frame.width
        let frameH = frame.height
        let frameGray = Self.grayDownsample(rgba: frameRGBA, w: frameW, h: frameH, targetW: grayWidth)

        if width == 0 {
            width = frameW
            height = frameH
            rgba = frameRGBA
            gray = frameGray
            return .firstFrame(rows: frameH)
        }

        guard frameW == width else { return .widthMismatch }

        // Match a strip of size K rows from the canvas's bottom against every
        // candidate position in the new frame.
        let K = max(8, min(height, frameH) / 3)
        if K >= frameH { return .duplicate }

        let canvasStartRow = height - K
        var bestS = -1
        var bestErr = Int64.max

        for s in 0...(frameH - K) {
            var err: Int64 = 0
            var rejected = false
            for r in 0..<K {
                let canvasOff = (canvasStartRow + r) * grayWidth
                let frameOff = (s + r) * grayWidth
                var rowErr: Int64 = 0
                for x in 0..<grayWidth {
                    let d = Int32(gray[canvasOff + x]) - Int32(frameGray[frameOff + x])
                    rowErr += Int64(d * d)
                }
                err += rowErr
                if err >= bestErr { rejected = true; break }
            }
            if !rejected && err < bestErr {
                bestErr = err
                bestS = s
            }
        }
        guard bestS >= 0 else { return .duplicate }

        let perPixel = Double(bestErr) / Double(K * grayWidth)
        if perPixel > perPixelRejectThreshold {
            return .lowConfidence(perPixel: perPixel, bestS: bestS)
        }

        let appendRows = frameH - K - bestS
        if appendRows <= 0 { return .duplicate }

        // Append RGBA rows: frame rows [bestS + K ..< frameH]
        let rgbaStart = (bestS + K) * width * 4
        let rgbaCount = appendRows * width * 4
        rgba.append(contentsOf: frameRGBA[rgbaStart..<(rgbaStart + rgbaCount)])

        // Append matching gray rows.
        let grayStart = (bestS + K) * grayWidth
        let grayCount = appendRows * grayWidth
        gray.append(contentsOf: frameGray[grayStart..<(grayStart + grayCount)])

        height += appendRows
        return .appended(rows: appendRows, perPixel: perPixel)
    }

    func finalize() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let provider = CGDataProvider(data: Data(rgba) as CFData)
        guard let provider = provider else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: Pixel helpers

    /// Draw `image` into a tightly-packed RGBA8 (premultiplied last) buffer.
    private static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: h * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        let ok = bytes.withUnsafeMutableBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: w,
                                      height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? bytes : nil
    }

    /// Sample a `targetW`-wide grayscale projection from RGBA, one byte per pixel.
    /// Uses simple nearest-x point sampling — fast and good enough for SSD matching.
    private static func grayDownsample(rgba: [UInt8], w: Int, h: Int, targetW: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: targetW * h)
        let denom = max(1, targetW)
        for y in 0..<h {
            for tx in 0..<targetW {
                let sx = min(w - 1, (tx * w) / denom)
                let off = (y * w + sx) * 4
                let r = Int(rgba[off])
                let g = Int(rgba[off + 1])
                let b = Int(rgba[off + 2])
                out[y * targetW + tx] = UInt8((r * 30 + g * 59 + b * 11) / 100)
            }
        }
        return out
    }
}
