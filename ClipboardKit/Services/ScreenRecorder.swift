import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Records a rectangular region (or a whole display) as an MP4 video,
/// optionally producing an animated GIF afterwards.
///
/// Flow:
///   1. `beginRegion()` shows the same selection overlay as the screenshot
///      flow but with the "Record" hint; on mouse-up, recording starts.
///   2. SCStream delivers `CMSampleBuffer` video frames; AVAssetWriter
///      appends them to a temporary `.mov` file (H.264 + AAC if mic is on).
///   3. A floating HUD shows elapsed time and a Stop button.
///   4. On stop the file is finalized, copied to the user's screenshots
///      folder, and a thumbnail HUD appears with a still-frame preview.
///      If `outputGIF` is true, the file is then transcoded to .gif via
///      sampled CGImages and ImageIO.
final class ScreenRecorder: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = ScreenRecorder()

    enum Output { case mp4, gif }

    private var stream: SCStream?
    private var sampleQueue = DispatchQueue(label: "com.clipboard.screenrecorder.samples")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startedAt: CMTime?
    private var indicator: RecordingIndicatorPanel?
    private var timer: Timer?

    /// Where the in-flight recording is written. Promoted to the final
    /// destination on stop.
    private var workingURL: URL?

    /// Selected output mode for the current run; controls whether stop
    /// kicks off a GIF transcode after MP4 finalization.
    private var requestedOutput: Output = .mp4

    /// Region in CG global coords + the screen it sits on, for sourceRect
    /// math at start time.
    private var activeRect: CGRect?
    private var activeScreen: NSScreen?

    /// Frames sampled for the optional GIF pass. We keep at most ~120 stills
    /// (≈ 10 s @ 12 fps) so even a long recording stays under control.
    private var gifFrames: [(image: CGImage, time: CMTime)] = []
    private let gifMaxFrames = 120
    private let gifTargetFPS: Double = 12

    /// True once the stream is delivering frames. Used by the writer's
    /// `sourceTime` to start the timeline at zero instead of an absolute
    /// host time, otherwise GIF / MP4 viewers misinterpret the leading
    /// timestamp as a long blank prefix.
    private var isWriting = false

    private override init() { super.init() }

    // MARK: - Entry points

    /// Show the region overlay; on mouse-up start recording the selected
    /// rect with the requested output format.
    @MainActor
    func beginRegion(output: Output) {
        requestedOutput = output
        // Reuse the screenshot selection overlay. We give it our own onFinish
        // closure that starts recording instead of grabbing a still.
        RegionPickerForRecording.shared.pickRegion { [weak self] rect, screen in
            self?.startRecording(rect: rect, screen: screen)
        }
    }

    /// Stop hotkey / Stop button. Finalize the MP4 and, if requested, the GIF.
    func stop() {
        Task { @MainActor in await self.finishRecording() }
    }

    // MARK: - Recording

    @MainActor
    private func startRecording(rect screenRect: NSRect, screen: NSScreen) {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            NSSound.beep(); return
        }
        activeScreen = screen
        // Convert AppKit screen-coords (bottom-left origin) into the
        // ScreenCaptureKit `sourceRect` space (points relative to the
        // display, top-left origin).
        let originX = screenRect.origin.x - screen.frame.origin.x
        let originYFromTop = screen.frame.height - ((screenRect.origin.y - screen.frame.origin.y) + screenRect.height)
        let cgRect = CGRect(x: originX, y: originYFromTop,
                            width: screenRect.width, height: screenRect.height)
        activeRect = cgRect

        Task { [weak self] in
            await self?.bootstrapStream(displayID: displayID, sourceRect: cgRect, scale: screen.backingScaleFactor, screen: screen, screenRect: screenRect)
        }
    }

    @MainActor
    private func bootstrapStream(displayID: CGDirectDisplayID, sourceRect: CGRect, scale: CGFloat, screen: NSScreen, screenRect: NSRect) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                NSSound.beep(); return
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = sourceRect
            // Even-pixel dimensions are required by the H.264 encoder.
            let pxW = Int(sourceRect.width * scale) & ~1
            let pxH = Int(sourceRect.height * scale) & ~1
            cfg.width = max(2, pxW)
            cfg.height = max(2, pxH)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30) // ~30 fps cap
            cfg.queueDepth = 6
            cfg.showsCursor = true
            cfg.scalesToFit = false
            cfg.pixelFormat = kCVPixelFormatType_32BGRA

            // Output file (temp .mov, then move/rename on stop).
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipboardKit-Recording", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let url = tmpDir.appendingPathComponent("rec-\(Int(Date().timeIntervalSince1970)).mov")
            try? FileManager.default.removeItem(at: url)
            workingURL = url

            // AVAssetWriter (H.264, even-pixel size).
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            let vSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: cfg.width,
                AVVideoHeightKey: cfg.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(2_000_000, cfg.width * cfg.height * 4),
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
            vInput.expectsMediaDataInRealTime = true
            // BGRA → YUV happens automatically inside AVAssetWriter using
            // the pixel adaptor; we keep the source format as 32BGRA so the
            // pixel buffers from SCStream pass straight through.
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: cfg.width,
                    kCVPixelBufferHeightKey as String: cfg.height
                ]
            )
            writer.add(vInput)
            self.writer = writer
            self.videoInput = vInput
            self.pixelAdaptor = adaptor

            // SCStream.
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            self.stream = stream
            try await stream.startCapture()

            // Show the floating HUD next to the recorded region.
            showIndicator(near: screenRect, on: screen)
            startTimer()
        } catch {
            print("Screen recorder: failed to start — \(error)")
            cleanupOnFailure()
            NSSound.beep()
        }
    }

    @MainActor
    private func showIndicator(near rect: NSRect, on screen: NSScreen) {
        let panel = RecordingIndicatorPanel()
        panel.onStop = { [weak self] in self?.stop() }
        // Place the HUD just below the recording rect, fall back to above.
        let panelSize = panel.frame.size
        let margin: CGFloat = 12
        var x = rect.midX - panelSize.width / 2
        var y = rect.minY - panelSize.height - margin
        if y < screen.frame.minY + 8 { y = rect.maxY + margin }
        x = max(screen.frame.minX + 8, min(x, screen.frame.maxX - panelSize.width - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        indicator = panel
    }

    private func startTimer() {
        let start = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async { self?.indicator?.update(elapsed: elapsed) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor
    private func finishRecording() async {
        guard let stream, let writer, let vInput = videoInput else { return }
        // Tear down user-facing UI first so we get a clean final frame
        // (the HUD itself is shielded but the timer is now stopped).
        timer?.invalidate(); timer = nil
        indicator?.orderOut(nil); indicator = nil

        do {
            try await stream.stopCapture()
        } catch {
            print("Screen recorder: stopCapture failed — \(error)")
        }
        self.stream = nil

        vInput.markAsFinished()
        await writer.finishWriting()
        let finalState = writer.status
        self.writer = nil
        self.videoInput = nil
        self.pixelAdaptor = nil
        self.isWriting = false

        guard finalState == .completed, let workingURL else {
            NSSound.beep()
            cleanupOnFailure()
            return
        }

        // Move into the screenshots folder so it survives reboots and the
        // file inspector / Finder can find it next to stills.
        let destURL = persistedDestinationURL(forSourceExtension: "mp4")
        do {
            try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: workingURL, to: destURL)
        } catch {
            print("Screen recorder: move failed — \(error). Falling back to working URL.")
        }
        let finalMP4 = (try? destURL.checkResourceIsReachable()) == true ? destURL : workingURL
        self.workingURL = nil
        self.activeRect = nil

        // Pasteboard: file URL of the MP4 (and a fallback string for apps
        // that only accept text). Lets users immediately paste the recording
        // into chat / file pickers. Setting the one-shot screenshot hint
        // before writing makes ClipboardManager tag the resulting history
        // item as a capture so it lands in the Screenshots tab.
        let pb = NSPasteboard.general
        pb.clearContents()
        CaptureOutput.pendingScreenshotHint = true
        pb.writeObjects([finalMP4 as NSURL])
        pb.setString(finalMP4.path, forType: .string)

        // Thumbnail HUD with the first frame.
        if let preview = thumbnailImage(for: finalMP4) {
            CaptureThumbnailHUD.shared.show(image: preview, savedURL: finalMP4)
        }
        ToastCenter.shared.show("Recorded \(finalMP4.lastPathComponent)")

        // GIF post-processing if requested. Done off-main since the sampled
        // CGImages may be tens of MB on a 4K capture.
        if requestedOutput == .gif {
            let frames = gifFrames
            gifFrames = []
            let baseURL = finalMP4.deletingPathExtension().appendingPathExtension("gif")
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let url = self?.writeGIF(frames: frames, to: baseURL) else { return }
                DispatchQueue.main.async {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    CaptureOutput.pendingScreenshotHint = true
                    pb.writeObjects([url as NSURL])
                    pb.setString(url.path, forType: .string)
                    if let preview = self?.firstFrameImage(frames: frames) {
                        CaptureThumbnailHUD.shared.show(image: preview, savedURL: url)
                    }
                    ToastCenter.shared.show("GIF: \(url.lastPathComponent)")
                }
            }
        } else {
            gifFrames = []
        }
    }

    private func cleanupOnFailure() {
        videoInput?.markAsFinished()
        writer?.cancelWriting()
        writer = nil
        videoInput = nil
        pixelAdaptor = nil
        if let workingURL { try? FileManager.default.removeItem(at: workingURL) }
        workingURL = nil
        gifFrames = []
        timer?.invalidate(); timer = nil
        DispatchQueue.main.async { [weak self] in
            self?.indicator?.orderOut(nil); self?.indicator = nil
        }
        Task { [stream] in try? await stream?.stopCapture() }
        stream = nil
        isWriting = false
    }

    // MARK: - Output paths

    private func persistedDestinationURL(forSourceExtension ext: String) -> URL {
        let folder = SettingsManager.shared.screenshotsFolderPath
        let url = URL(fileURLWithPath: folder)
        let stamp = Self.filenameFormatter.string(from: Date())
        let name = "Recording \(stamp).\(ext)"
        return url.appendingPathComponent(name)
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    private func thumbnailImage(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let cg: CGImage?
        do {
            cg = try gen.copyCGImage(at: CMTime(seconds: 0.05, preferredTimescale: 600), actualTime: nil)
        } catch {
            cg = nil
        }
        guard let cg else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func firstFrameImage(frames: [(CGImage, CMTime)]) -> NSImage? {
        guard let first = frames.first?.0 else { return nil }
        return NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height))
    }

    // MARK: - GIF encoding

    private func writeGIF(frames raw: [(image: CGImage, time: CMTime)], to url: URL) -> URL? {
        guard !raw.isEmpty else { return nil }
        let frames = raw // already capped during capture
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }

        // GIF loop forever.
        let gifProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)

        // Use uniform per-frame delay based on the requested fps cap.
        let delay = 1.0 / gifTargetFPS
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: delay,
                kCGImagePropertyGIFDelayTime: delay
            ]
        ]
        // Downsample frames to a max 720 px short side so the GIF stays
        // under a sensible file size on a 4K source.
        for (cg, _) in frames {
            let scaled = downsample(cg, maxShortSide: 720) ?? cg
            CGImageDestinationAddImage(dest, scaled, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }

    private func downsample(_ cg: CGImage, maxShortSide: Int) -> CGImage? {
        let w = cg.width, h = cg.height
        let shorter = min(w, h)
        if shorter <= maxShortSide { return cg }
        let scale = CGFloat(maxShortSide) / CGFloat(shorter)
        let newW = Int(CGFloat(w) * scale)
        let newH = Int(CGFloat(h) * scale)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension ScreenRecorder: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(buffer),
              CMSampleBufferDataIsReady(buffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }

        // Drop the very first sample if SCStream marks it as not complete
        // (the system signals a partial first frame on some configurations).
        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        if let info = attachmentsArray?.first,
           let statusRaw = info[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        var sampleTime = CMSampleBufferGetPresentationTimeStamp(buffer)
        if !isWriting {
            // Start the writer's timeline at this frame's PTS so playback
            // starts at t=0 in the final file.
            startedAt = sampleTime
            writer?.startWriting()
            writer?.startSession(atSourceTime: sampleTime)
            isWriting = true
        }
        guard let writer = writer, writer.status == .writing else { return }
        guard let videoInput = videoInput, videoInput.isReadyForMoreMediaData else { return }
        guard let adaptor = pixelAdaptor else { return }

        adaptor.append(pixelBuffer, withPresentationTime: sampleTime)

        // GIF sampling at ~12 fps so the captured slice list stays compact
        // even on long recordings. Uses a CG snapshot of the frame.
        if requestedOutput == .gif {
            let interval = CMTime(seconds: 1.0 / gifTargetFPS, preferredTimescale: 600)
            let lastTime = gifFrames.last?.time ?? .negativeInfinity
            if CMTimeCompare(CMTimeSubtract(sampleTime, lastTime), interval) >= 0 {
                if let cg = Self.cgImage(from: pixelBuffer) {
                    gifFrames.append((cg, sampleTime))
                    if gifFrames.count > gifMaxFrames {
                        gifFrames.removeFirst()
                    }
                }
            }
        }
        _ = sampleTime
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Screen recorder: SCStream stopped with error — \(error)")
        Task { @MainActor in self.cleanupOnFailure() }
    }

    private static func cgImage(from pb: CVPixelBuffer) -> CGImage? {
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
        return cg
    }
}

// MARK: - Region picker reuse

/// Lightweight wrapper that reuses the screenshot SelectionWindow flow
/// just for region selection; on mouse-up it calls the closure instead
/// of capturing a still.
final class RegionPickerForRecording: @unchecked Sendable {
    nonisolated(unsafe) static let shared = RegionPickerForRecording()

    private var overlayWindows: [SelectionWindow] = []
    private var completion: ((NSRect, NSScreen) -> Void)?

    private init() {}

    @MainActor
    func pickRegion(_ done: @escaping (NSRect, NSScreen) -> Void) {
        completion = done

        // Snapshot displays first so the dim overlay can show a frozen
        // mirror, same UX as still-capture region selection.
        Task { @MainActor in
            var snapshots: [NSScreen: CGImage] = [:]
            for screen in NSScreen.screens {
                if let img = await Self.snapshot(of: screen) {
                    snapshots[screen] = img
                }
            }
            self.overlayWindows = NSScreen.screens.map { screen in
                let w = SelectionWindow(screen: screen, snapshot: snapshots[screen])
                w.onFinish = { [weak self] rect, screen in
                    self?.finish(rect: rect, screen: screen)
                }
                w.onFinishWindow = { [weak self] _, _ in
                    self?.cancel()
                }
                w.onCancel = { [weak self] in self?.cancel() }
                return w
            }
            let nums = Set(overlayWindows.map { $0.windowNumber })
            overlayWindows.forEach { $0.ignoredWindowNumbers = nums }
            overlayWindows.forEach { $0.orderFrontRegardless() }
            NSApp.activate()
            overlayWindows.first?.makeKey()
        }
    }

    @MainActor
    private func finish(rect: NSRect, screen: NSScreen) {
        teardown()
        let cb = completion; completion = nil
        // Give the compositor a beat to hide the overlay before SCStream
        // starts sampling, so the dim layer doesn't bake into frame 1.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            cb?(rect, screen)
        }
    }

    @MainActor
    func cancel() {
        teardown()
        completion = nil
    }

    private func teardown() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
    }

    @MainActor
    private static func snapshot(of screen: NSScreen) async -> CGImage? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * scale)
            cfg.height = Int(screen.frame.height * scale)
            cfg.showsCursor = false
            cfg.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            return nil
        }
    }
}

// MARK: - Recording HUD

/// Small floating panel shown next to the recording region with the
/// elapsed timer + Stop button.
final class RecordingIndicatorPanel: NSPanel {
    private let label = NSTextField(labelWithString: "00:00")
    private let dot = NSView()
    private let stopButton = StopRecordingButton(frame: .zero)
    private var pulseTimer: Timer?

    var onStop: (() -> Void)?

    init() {
        // Wider panel so the Stop chip can carry an icon + label and not
        // get squashed against the timer.
        let size = NSSize(width: 200, height: 42)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false

        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        bg.layer?.cornerRadius = 12
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        bg.layer?.borderWidth = 1

        dot.frame = NSRect(x: 12, y: 14, width: 14, height: 14)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 7
        bg.addSubview(dot)

        label.frame = NSRect(x: 32, y: 11, width: 70, height: 20)
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBordered = false
        bg.addSubview(label)

        // Solid-red Stop chip sits on the right. The stock NSButton with
        // the dark-panel background blends into the chrome on most screens
        // so we draw our own pill so the user can always spot it.
        stopButton.frame = NSRect(x: size.width - 84, y: 7, width: 76, height: 28)
        stopButton.target = self
        stopButton.action = #selector(handleStop)
        bg.addSubview(stopButton)

        contentView = bg

        // Pulse the red dot so the panel reads as "actively recording".
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.togglePulse()
        }
        if let t = pulseTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private var pulsed = false
    private func togglePulse() {
        pulsed.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.55
            dot.animator().alphaValue = pulsed ? 0.35 : 1.0
        }
    }

    func update(elapsed: TimeInterval) {
        let m = Int(elapsed) / 60
        let s = Int(elapsed) % 60
        label.stringValue = String(format: "%02d:%02d", m, s)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func handleStop() {
        pulseTimer?.invalidate(); pulseTimer = nil
        onStop?()
    }
}

// MARK: - Stop button

/// Custom NSButton drawn as a solid-red rounded "Stop" pill with an
/// SF Symbol on the left. Replaces the stock NSButton in
/// `RecordingIndicatorPanel` because the system control's translucent
/// chrome got lost against the panel's dark backdrop, making it hard to
/// see (and hit). Lights up brighter while pressed.
private final class StopRecordingButton: NSButton {
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        title = "" // we draw our own label
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        toolTip = "Stop recording"
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (pressed
            ? NSColor.systemRed.blended(withFraction: 0.2, of: .white)
            : NSColor.systemRed)?.cgColor
        layer?.cornerRadius = bounds.height / 2
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.borderWidth = 0.5
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset: CGFloat = 8

        // Filled square icon (acts as the "stop" glyph) on the left.
        let iconSide: CGFloat = 10
        let iconRect = NSRect(x: inset,
                              y: (bounds.height - iconSide) / 2,
                              width: iconSide, height: iconSide)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(iconRect)

        // "Stop" label to the right of the icon.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: "Stop", attributes: attrs)
        let textSize = str.size()
        let textOrigin = NSPoint(
            x: iconRect.maxX + 6,
            y: (bounds.height - textSize.height) / 2
        )
        str.draw(at: textOrigin)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        super.mouseDown(with: event)
        pressed = false
    }
}
