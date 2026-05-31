import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Lightweight post-capture annotation window.
///
/// Tools: arrow, rectangle, text, redact (filled black box). Output is
/// pushed back through `CaptureOutput` so it lands on the pasteboard /
/// disk just like a fresh capture.
final class AnnotationWindowController: @unchecked Sendable {
    nonisolated(unsafe) static let shared = AnnotationWindowController()

    private var window: NSWindow?

    /// `savedPath`, when provided, is the on-disk PNG to overwrite when the
    /// annotation window closes (auto-save). Passing nil disables auto-save
    /// — the user can still hit ⌘C/↩ to copy out the result.
    func present(image: NSImage, savedPath: String? = nil) {
        if let win = window {
            win.close()
            window = nil
        }

        // Compute the on-screen canvas size: fit the image inside ~85% of the
        // current screen, leaving room for the toolbar.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let maxW = (screen?.visibleFrame.width ?? 1400) * 0.85
        let maxH = (screen?.visibleFrame.height ?? 900) * 0.80 - 60
        let imgSize = image.size
        let scale = min(1, min(maxW / max(imgSize.width, 1),
                               maxH / max(imgSize.height, 1)))
        let canvasSize = NSSize(width: floor(imgSize.width * scale),
                                height: floor(imgSize.height * scale))
        let toolbarHeight: CGFloat = 88 // two rows: drawing tools + actions
        let contentSize = NSSize(width: max(canvasSize.width, 920),
                                 height: canvasSize.height + toolbarHeight)

        let controller = AnnotationViewController(image: image,
                                                  canvasSize: canvasSize,
                                                  savedPath: savedPath)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Annotate Screenshot"
        win.center()
        win.contentViewController = controller
        win.isReleasedWhenClosed = false
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Tools / Model

enum AnnotationTool: String, CaseIterable {
    case arrow
    case rectangle
    case oval
    case text
    case pen
    case highlighter
    case callout
    case redact
    case blur
    case blurTorn
    case crop

    var symbolName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .oval: return "oval"
        case .text: return "textformat"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .callout: return "bubble.left"
        case .redact: return "eye.slash"
        case .blur: return "drop.degreesign"
        case .blurTorn: return "scribble.variable"
        case .crop: return "crop"
        }
    }

    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .oval: return "Oval"
        case .text: return "Text"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .callout: return "Callout"
        case .redact: return "Redact"
        case .blur: return "Blur"
        case .blurTorn: return "Torn Blur"
        case .crop: return "Crop"
        }
    }
}

/// Background presets for the "Beautify" action. Each preset places the
/// screenshot on a padded background with rounded corners and a soft drop
/// shadow — the same UX as Xnapper/CleanShot's "Wallpaper"/"Background"
/// modes. Add cases here to introduce new looks; the toolbar pull-down
/// auto-populates from `allCases`.
enum BeautifyPreset: Int, CaseIterable {
    case gradientBlue = 0
    case gradientSunset = 1
    case gradientForest = 2
    case gradientPeach = 3
    case gradientGraphite = 4
    case solidWhite = 5

    var title: String {
        switch self {
        case .gradientBlue: return "Background: Ocean"
        case .gradientSunset: return "Background: Sunset"
        case .gradientForest: return "Background: Forest"
        case .gradientPeach: return "Background: Peach"
        case .gradientGraphite: return "Background: Graphite"
        case .solidWhite: return "Background: White"
        }
    }

    /// Two-colour stop the renderer uses for a top-left → bottom-right
    /// linear gradient. Solid presets use the same colour twice.
    var colors: (NSColor, NSColor) {
        switch self {
        case .gradientBlue:
            return (NSColor(srgbRed: 0.20, green: 0.45, blue: 0.95, alpha: 1),
                    NSColor(srgbRed: 0.45, green: 0.85, blue: 1.00, alpha: 1))
        case .gradientSunset:
            return (NSColor(srgbRed: 1.00, green: 0.45, blue: 0.40, alpha: 1),
                    NSColor(srgbRed: 1.00, green: 0.78, blue: 0.45, alpha: 1))
        case .gradientForest:
            return (NSColor(srgbRed: 0.10, green: 0.55, blue: 0.40, alpha: 1),
                    NSColor(srgbRed: 0.55, green: 0.85, blue: 0.55, alpha: 1))
        case .gradientPeach:
            return (NSColor(srgbRed: 0.97, green: 0.65, blue: 0.75, alpha: 1),
                    NSColor(srgbRed: 1.00, green: 0.88, blue: 0.72, alpha: 1))
        case .gradientGraphite:
            return (NSColor(srgbRed: 0.18, green: 0.20, blue: 0.24, alpha: 1),
                    NSColor(srgbRed: 0.36, green: 0.40, blue: 0.46, alpha: 1))
        case .solidWhite:
            return (.white, .white)
        }
    }
}

struct Annotation {
    var tool: AnnotationTool
    /// In image-pixel space (origin bottom-left, same as NSImage default).
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""
    /// For pen / highlighter strokes, the recorded path in display coords.
    var path: [CGPoint] = []
}

// MARK: - View controller (toolbar + canvas)

private final class AnnotationViewController: NSViewController {
    private let image: NSImage
    private let canvasSize: NSSize
    /// Path of the on-disk PNG this annotation session originated from.
    /// `nil` means "no auto-save target" — the user opened a transient image
    /// (rare path, kept for safety).
    private let savedPath: String?
    private var canvas: AnnotationCanvasView!
    private var currentTool: AnnotationTool = .arrow
    private var currentColor: NSColor = .systemRed
    private var currentWidth: CGFloat = 3

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var colorButtons: [ColorSwatchButton] = []
    private weak var customColorWell: CustomColorPickerButton?
    /// Window-scoped key monitor token so ⌘C (and a few other shortcuts) can
    /// fire without stealing keystrokes from text-annotation editing inside
    /// child windows. Installed in `viewDidAppear`, removed on disappear.
    private var keyMonitor: Any?
    /// Notification observer for our window's `willClose` event so we can
    /// flush the flattened PNG back to disk before the window goes away.
    private var willCloseObserver: NSObjectProtocol?

    init(image: NSImage, canvasSize: NSSize, savedPath: String? = nil) {
        self.image = image
        self.canvasSize = canvasSize
        self.savedPath = savedPath
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let toolbarHeight: CGFloat = 88
        let rootSize = NSSize(width: max(canvasSize.width, 920),
                              height: canvasSize.height + toolbarHeight)
        let root = NSView(frame: NSRect(origin: .zero, size: rootSize))
        root.autoresizingMask = [.width, .height]

        // Toolbar pinned to top.
        let toolbar = makeToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)

        // Canvas sized for the window, centered horizontally.
        canvas = AnnotationCanvasView(image: image, displaySize: canvasSize)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.toolProvider = { [weak self] in
            guard let self else { return (.arrow, .systemRed, 3) }
            return (self.currentTool, self.currentColor, self.currentWidth)
        }
        canvas.onCrop = { [weak self] rect in
            self?.applyCrop(displayRect: rect)
        }
        root.addSubview(canvas)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),

            canvas.topAnchor.constraint(greaterThanOrEqualTo: toolbar.bottomAnchor, constant: 8),
            canvas.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            canvas.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: toolbarHeight / 2),
            canvas.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -8)
        ])

        self.view = root
        updateToolSelection()
        updateColorSelection()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitorIfNeeded()
        installWillCloseObserverIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let token = keyMonitor {
            NSEvent.removeMonitor(token)
            keyMonitor = nil
        }
        if let token = willCloseObserver {
            NotificationCenter.default.removeObserver(token)
            willCloseObserver = nil
        }
    }

    /// Subscribe to our window's `willClose` notification so we can flush
    /// the flattened PNG to disk before the window goes away. Using the
    /// notification rather than `windowShouldClose` keeps the close action
    /// non-cancellable from the user's perspective: edits always land.
    private func installWillCloseObserverIfNeeded() {
        guard willCloseObserver == nil, let win = view.window else { return }
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.flushToSourceFile()
        }
    }

    /// Watch local key events while this view is on-screen so users can hit
    /// ⌘C to copy the annotated PNG. NSButton only supports one `keyEquivalent`
    /// each (Copy already uses Return as the default-action accelerator), so
    /// we route the conventional ⌘C through a monitor instead of stealing the
    /// Return binding. The monitor scopes itself to events whose window is
    /// ours so other apps' shortcuts are unaffected.
    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let win = self.view.window,
                  event.window === win else { return event }
            // Ignore the shortcut while a text editor is first responder so
            // ⌘C inside an annotation-text field still copies the selected
            // characters instead of the whole image.
            if let fr = win.firstResponder, fr is NSText {
                return event
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
                // ⌘C copies but keeps the annotator open so the user can
                // keep tweaking and paste elsewhere; the toolbar's Copy
                // button (and ↩) still closes the window for the "done"
                // affordance.
                self.copyToClipboardKeepOpen()
                return nil
            }
            return event
        }
    }

    private func makeToolbar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // --- Row 1: drawing tools + colors + width ---
        let toolsStack = NSStackView()
        toolsStack.translatesAutoresizingMaskIntoConstraints = false
        toolsStack.orientation = .horizontal
        toolsStack.spacing = 8
        toolsStack.alignment = .centerY
        toolsStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        for tool in AnnotationTool.allCases {
            let btn = NSButton()
            btn.bezelStyle = .texturedRounded
            btn.image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.label)
            btn.toolTip = tool.label
            btn.target = self
            btn.action = #selector(toolTapped(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            btn.setButtonType(.pushOnPushOff)
            toolButtons[tool] = btn
            toolsStack.addArrangedSubview(btn)
        }

        toolsStack.addArrangedSubview(verticalDivider())

        for color in [NSColor.systemRed, .systemOrange, .systemYellow, .systemGreen,
                       .systemBlue, .systemPurple, .systemPink, .black, .white] {
            let btn = ColorSwatchButton(color: color)
            btn.target = self
            btn.action = #selector(colorTapped(_:))
            colorButtons.append(btn)
            toolsStack.addArrangedSubview(btn)
        }

        // Custom color picker — rainbow ring around the currently selected
        // color makes it obvious this opens the system color panel /
        // eyedropper instead of just being another preset swatch.
        let well = CustomColorPickerButton()
        well.color = currentColor
        well.target = self
        well.action = #selector(colorWellChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.toolTip = "Custom color (opens color picker)…"
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 26),
            well.heightAnchor.constraint(equalToConstant: 26)
        ])
        customColorWell = well
        toolsStack.addArrangedSubview(well)

        toolsStack.addArrangedSubview(verticalDivider())

        let widthSeg = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne,
                                          target: self, action: #selector(widthChanged(_:)))
        widthSeg.selectedSegment = 1
        toolsStack.addArrangedSubview(widthSeg)

        toolsStack.addArrangedSubview(NSView()) // tail spacer to keep items left-aligned

        // --- Row 2: actions ---
        let actionsStack = NSStackView()
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.orientation = .horizontal
        actionsStack.spacing = 8
        actionsStack.alignment = .centerY
        actionsStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        let undoBtn = Self.makeActionButton(symbol: "arrow.uturn.backward",
                                            label: "Undo (⌘Z)",
                                            target: self,
                                            action: #selector(performUndo(_:)))
        undoBtn.keyEquivalent = "z"
        undoBtn.keyEquivalentModifierMask = [.command]
        let redoBtn = Self.makeActionButton(symbol: "arrow.uturn.forward",
                                            label: "Redo (⇧⌘Z)",
                                            target: self,
                                            action: #selector(performRedo(_:)))
        redoBtn.keyEquivalent = "z"
        redoBtn.keyEquivalentModifierMask = [.command, .shift]
        actionsStack.addArrangedSubview(undoBtn)
        actionsStack.addArrangedSubview(redoBtn)
        let borderBlurBtn = Self.makeActionButton(symbol: "rectangle.center.inset.filled",
                                                  label: "Border Blur (frame on blurred backdrop)",
                                                  target: self,
                                                  action: #selector(applyBorderBlur))
        actionsStack.addArrangedSubview(borderBlurBtn)
        let tornBorderBlurBtn = Self.makeActionButton(symbol: "scribble.variable",
                                                      label: "Torn Border Blur (hand-torn frame on blurred backdrop)",
                                                      target: self,
                                                      action: #selector(applyTornBorderBlur))
        actionsStack.addArrangedSubview(tornBorderBlurBtn)

        // "Beautify" pull-down: drops the screenshot on a colourful padded
        // background with rounded corners + soft shadow (Xnapper-style).
        let beautifyBtn = NSPopUpButton(frame: .zero, pullsDown: true)
        beautifyBtn.bezelStyle = .rounded
        beautifyBtn.imagePosition = .imageOnly
        let beautifyMenuItem = NSMenuItem()
        beautifyMenuItem.image = NSImage(systemSymbolName: "sparkles",
                                          accessibilityDescription: "Beautify with background")
        beautifyBtn.menu?.addItem(beautifyMenuItem)
        for preset in BeautifyPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(beautifyTapped(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            beautifyBtn.menu?.addItem(item)
        }
        beautifyBtn.toolTip = "Beautify: padded gradient background with rounded corners + shadow"
        actionsStack.addArrangedSubview(beautifyBtn)

        let ocrBtn = Self.makeActionButton(symbol: "text.viewfinder",
                                           label: "Recognize Text",
                                           target: self,
                                           action: #selector(recognizeText))
        let exportBtn = Self.makeActionButton(symbol: "square.and.arrow.down",
                                              label: "Export As… (PNG / JPEG / HEIC)",
                                              target: self,
                                              action: #selector(exportAs))
        let copyBtn = Self.makeActionButton(symbol: "doc.on.doc",
                                            label: "Copy to Clipboard (⌘C / ↩)",
                                            target: self,
                                            action: #selector(copyToClipboard),
                                            tint: .controlAccentColor)
        copyBtn.keyEquivalent = "\r"
        actionsStack.addArrangedSubview(ocrBtn)
        actionsStack.addArrangedSubview(exportBtn)
        actionsStack.addArrangedSubview(copyBtn)
        actionsStack.addArrangedSubview(NSView()) // tail spacer so the row stays left-aligned

        bar.addSubview(toolsStack)
        bar.addSubview(actionsStack)
        NSLayoutConstraint.activate([
            toolsStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            toolsStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            toolsStack.topAnchor.constraint(equalTo: bar.topAnchor),
            toolsStack.heightAnchor.constraint(equalToConstant: 44),

            actionsStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            actionsStack.topAnchor.constraint(equalTo: toolsStack.bottomAnchor),
            actionsStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
        ])
        return bar
    }

    private func verticalDivider() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 22)
        ])
        return v
    }

    /// Builds an icon-only action button using SF Symbols. Action buttons use
    /// the standard rounded push-button bezel, which looks visibly different
    /// from the textured/toggle tool buttons in the row above so users don't
    /// confuse "select a tool" with "perform an action".
    fileprivate static func makeActionButton(symbol: String,
                                             label: String,
                                             target: AnyObject,
                                             action: Selector,
                                             tint: NSColor? = nil) -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .rounded
        btn.imagePosition = .imageOnly
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        btn.toolTip = label
        btn.target = target
        btn.action = action
        if let tint = tint {
            btn.contentTintColor = tint
        }
        return btn
    }

    private func updateToolSelection() {
        for (tool, btn) in toolButtons {
            btn.state = (tool == currentTool) ? .on : .off
        }
    }

    private func updateColorSelection() {
        for btn in colorButtons {
            btn.isSelectedSwatch = (btn.color == currentColor)
        }
    }

    @objc private func toolTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let tool = AnnotationTool(rawValue: id) else { return }
        currentTool = tool
        updateToolSelection()
    }

    @objc private func colorTapped(_ sender: ColorSwatchButton) {
        currentColor = sender.color
        updateColorSelection()
        // Reflect the chosen swatch in the color well too so the user has a
        // single source of truth for the current color.
        customColorWell?.color = sender.color
    }

    @objc private func colorWellChanged(_ sender: CustomColorPickerButton) {
        currentColor = sender.color
        // Any preset that happens to match exactly still highlights;
        // otherwise no swatch shows the selected state.
        updateColorSelection()
    }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: currentWidth = 2
        case 1: currentWidth = 4
        default: currentWidth = 8
        }
    }

    @objc private func performUndo(_ sender: Any?) {
        canvas.undoLast()
    }

    @objc private func performRedo(_ sender: Any?) {
        canvas.redoLast()
    }

    /// Bake annotations into the image, then surround the result with a
    /// padded, heavily-blurred copy of itself for that "floating screenshot"
    /// look. Undoable.
    @objc private func applyBorderBlur(_ sender: Any?) {
        canvas.applyBorderBlur()
    }

    /// Same backdrop as Border Blur, but the inset screenshot is clipped to
    /// a hand-torn polygon for a ripped-paper boundary. Undoable.
    @objc private func applyTornBorderBlur(_ sender: Any?) {
        canvas.applyBorderBlur(torn: true)
    }

    @objc private func beautifyTapped(_ sender: NSMenuItem) {
        guard let preset = BeautifyPreset(rawValue: sender.tag) else { return }
        canvas.applyBeautify(preset: preset)
    }

    /// Crop in-place so undo can restore the previous image+annotations.
    /// The canvas owns the actual mutation; we just forward the rect.
    private func applyCrop(displayRect: NSRect) {
        guard displayRect.width >= 4, displayRect.height >= 4 else { return }
        canvas.applyCrop(displayRect: displayRect)
    }

    @objc private func copyToClipboard() {
        guard let data = canvas.flattenedPNG() else { NSSound.beep(); return }
        CaptureOutput.shared.deliver(pngData: data, showThumbnail: false)
        view.window?.close()
    }

    /// Copy variant that does NOT dismiss the annotation window. Wired to
    /// the ⌘C shortcut so users can keep iterating on the annotations and
    /// paste intermediate results elsewhere. Shows a brief toast since the
    /// usual visual confirmation (the window closing) no longer happens.
    @objc private func copyToClipboardKeepOpen() {
        guard let data = canvas.flattenedPNG() else { NSSound.beep(); return }
        CaptureOutput.shared.deliver(pngData: data, showThumbnail: false)
        ToastCenter.shared.show("Copied to clipboard")
    }

    /// Show NSSavePanel with a PNG/JPEG/HEIC format picker and a quality
    /// slider (greyed out for PNG which is lossless). Encodes from the
    /// flattened canvas at native pixel resolution.
    @objc private func exportAs() {
        guard let pngData = canvas.flattenedPNG() else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export Screenshot"
        let stamp = Self.exportFilenameFormatter.string(from: Date())
        panel.nameFieldStringValue = "Screenshot \(stamp).png"
        panel.allowedContentTypes = [.png, .jpeg, .heic]

        let accessory = ExportAccessoryView()
        accessory.onFormatChange = { format in
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
            panel.allowedContentTypes = [format.uti]
        }
        panel.accessoryView = accessory

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self else { return }
            let format = accessory.selectedFormat
            let quality = accessory.qualityValue
            let data: Data?
            switch format {
            case .png:
                data = pngData
            case .jpeg:
                data = Self.encodeJPEG(from: pngData, quality: quality)
            case .heic:
                data = Self.encodeHEIC(from: pngData, quality: quality)
            }
            guard let payload = data else {
                NSSound.beep(); return
            }
            do {
                try payload.write(to: url)
                ToastCenter.shared.show("Exported \(format.shortName)")
            } catch {
                NSSound.beep()
            }
        }
    }

    private static let exportFilenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    private static func encodeJPEG(from pngData: Data, quality: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(data: pngData) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: Double(quality))])
    }

    private static func encodeHEIC(from pngData: Data, quality: CGFloat) -> Data? {
        // Re-encode through ImageIO so we get a real HEIF/HEIC file rather
        // than just a renamed PNG. macOS 26 ships HEIC writer support.
        guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.heic" as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    @objc private func recognizeText() {
        // OCR uses the *un-annotated* source image at native pixel resolution.
        // The baked image (a) is down-sampled to point size on Retina because
        // `image.size` is in points and (b) has the user's rectangles / arrows
        // drawn over the text, which actively confuses Vision.
        guard let source = canvas.sourceImageAtNativePixels() else { NSSound.beep(); return }
        let anchor = view.window
        OCRService.recognizeText(in: source) { result in
            switch result {
            case .success(let text):
                OCRResultWindowController.present(recognizedText: text, anchor: anchor)
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "No text recognized"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .informational
                if let win = anchor {
                    alert.beginSheetModal(for: win, completionHandler: nil)
                } else {
                    alert.runModal()
                }
            }
        }
    }

    /// Persist the flattened PNG back to `savedPath`, overwriting the source
    /// file the annotation session started from. Returns `true` on success.
    /// Called on window close; does **not** mutate the canvas, so undo / redo
    /// stacks remain intact in case the same window is re-opened.
    @discardableResult
    private func flushToSourceFile() -> Bool {
        guard let path = savedPath else { return false }
        guard let data = canvas.flattenedPNG() else { return false }
        // Skip the write when the user opened the annotator and closed it
        // without doing anything — saves a needless I/O roundtrip and keeps
        // the file's mtime stable for sync clients.
        guard canvas.hasUserEdits else { return false }
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url, options: .atomic)
            // Drop any cached thumbnails so the popover row re-renders with
            // the new pixels next time it appears.
            ThumbnailCache.shared.invalidate(path: path)
            return true
        } catch {
            print("Annotation auto-save failed: \(error.localizedDescription)")
            return false
        }
    }

    @objc private func cancel() {
        view.window?.close()
    }
}

// MARK: - Canvas

/// Displays the image scaled to `displaySize` and lets the user lay shape
/// annotations on top in canvas-local coordinates. `flattenedPNG()` scales
/// the shapes back to the image's native pixel size so exports stay sharp.
private final class AnnotationCanvasView: NSView {
    /// Full state snapshot used to power undo / redo. Crop mutates `image`
    /// and `displaySize`, so both are versioned; annotations are versioned
    /// per add so each shape can be undone independently.
    private struct Snapshot {
        let image: NSImage
        let displaySize: NSSize
        let annotations: [Annotation]
    }

    private var image: NSImage
    private var displaySize: NSSize
    private var annotations: [Annotation] = []
    private var current: Annotation?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// Sticky flag flipped to `true` the first time the user mutates the
    /// canvas (adds an annotation, crops, applies a border-blur action, ...).
    /// Used by the controller's auto-save to skip writes when the window was
    /// opened and closed without any real edits. Doesn't reset on undo so
    /// "edit → undo → close" still considers the user to have touched the
    /// document; the resulting PNG bytes match the original anyway.
    private(set) var hasUserEdits: Bool = false
    /// Cached gaussian-blurred copy of the source image, used by the blur
    /// annotation tool. Recomputed lazily after each crop because the
    /// underlying pixels change.
    private var blurredImageCache: NSImage?
    private var blurredImage: NSImage {
        if let cached = blurredImageCache { return cached }
        let made = Self.makeBlurred(image)
        blurredImageCache = made
        return made
    }

    var toolProvider: () -> (AnnotationTool, NSColor, CGFloat) = { (.arrow, .systemRed, 4) }
    /// Invoked when the user finishes a `.crop` selection. Receiver should
    /// forward to `applyCrop(displayRect:)` so the canvas can mutate.
    var onCrop: ((NSRect) -> Void)?

    init(image: NSImage, displaySize: NSSize) {
        self.image = image
        self.displaySize = displaySize
        super.init(frame: NSRect(origin: .zero, size: displaySize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Flip so (0,0) is top-left like the underlying screenshot. Keeps mouse
    /// coordinates and image rendering aligned with how users expect to draw.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize { displaySize }

    // MARK: - State / Undo plumbing

    private var currentSnapshot: Snapshot {
        Snapshot(image: image, displaySize: displaySize, annotations: annotations)
    }

    /// Run `change`, after first snapshotting the current state so it can be
    /// recovered by Undo. Any new mutation clears the redo stack.
    private func performMutation(_ change: () -> Void) {
        undoStack.append(currentSnapshot)
        redoStack.removeAll()
        hasUserEdits = true
        change()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func restore(_ snapshot: Snapshot) {
        image = snapshot.image
        displaySize = snapshot.displaySize
        annotations = snapshot.annotations
        blurredImageCache = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func undoLast() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        restore(prev)
    }

    func redoLast() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        restore(next)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let (tool, color, width) = toolProvider()

        if tool == .text {
            // For text we don't drag — prompt immediately at the click point.
            promptText(title: "Add text") { [weak self] str in
                guard let self, let str, !str.isEmpty else { return }
                var ann = Annotation(tool: .text, start: p, end: p,
                                     color: color, lineWidth: width, text: str)
                ann.end = p
                self.performMutation { self.annotations.append(ann) }
            }
            return
        }

        var ann = Annotation(tool: tool, start: p, end: p, color: color, lineWidth: width)
        if tool == .pen || tool == .highlighter {
            ann.path = [p]
        }
        current = ann
    }

    override func mouseDragged(with event: NSEvent) {
        guard current != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        current?.end = p
        if current?.tool == .pen || current?.tool == .highlighter {
            current?.path.append(p)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var ann = current else { return }
        ann.end = convert(event.locationInWindow, from: nil)
        let dragged = hypot(ann.end.x - ann.start.x, ann.end.y - ann.start.y) >= 2

        if ann.tool == .crop {
            current = nil
            needsDisplay = true
            if dragged {
                let r = NSRect(
                    x: min(ann.start.x, ann.end.x),
                    y: min(ann.start.y, ann.end.y),
                    width: abs(ann.end.x - ann.start.x),
                    height: abs(ann.end.y - ann.start.y)
                )
                onCrop?(r)
            }
            return
        }

        if ann.tool == .callout {
            current = nil
            needsDisplay = true
            guard dragged else { return }
            promptText(title: "Callout text") { [weak self] str in
                guard let self, let str, !str.isEmpty else { return }
                var finalized = ann
                finalized.text = str
                self.performMutation { self.annotations.append(finalized) }
            }
            return
        }

        if dragged {
            performMutation { annotations.append(ann) }
        }
        current = nil
        needsDisplay = true
    }

    /// Bake annotations + frame the image with a heavily-blurred padded
    /// backdrop derived from itself. Aspect ratio is preserved (same %
    /// padding all sides), so `displaySize` doesn't need to change — the
    /// new image is just rendered at higher pixel resolution into the same
    /// on-screen canvas. Undoable. When `torn` is true the output stays the
    /// same size as the input (no extra frame padding); the original image
    /// is clipped to a hand-torn polygon and the small inset around it
    /// reveals the blurred backdrop of the screenshot itself.
    func applyBorderBlur(torn: Bool = false) {
        guard let baked = bakedImage() else { NSSound.beep(); return }
        let bakedSize = baked.size
        let shorter = min(bakedSize.width, bakedSize.height)

        let newSize: NSSize
        let imageRect: NSRect
        let referenceInset: CGFloat
        if torn {
            // Torn variant: keep the canvas exactly the size of the input.
            // The torn polygon is inset just enough that its perpendicular
            // jitter (capped below) cannot poke past the canvas bounds.
            newSize = bakedSize
            referenceInset = max(8, floor(shorter * 0.06))
            imageRect = NSRect(x: referenceInset, y: referenceInset,
                               width: bakedSize.width - referenceInset * 2,
                               height: bakedSize.height - referenceInset * 2)
        } else {
            // Padded frame variant: grow the canvas by `padPx` on every side
            // so the original screenshot sits on a visible blurred border.
            referenceInset = floor(shorter * 0.10)
            newSize = NSSize(width: bakedSize.width + referenceInset * 2,
                             height: bakedSize.height + referenceInset * 2)
            imageRect = NSRect(x: referenceInset, y: referenceInset,
                               width: bakedSize.width, height: bakedSize.height)
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newSize.width),
            pixelsHigh: Int(newSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { NSSound.beep(); return }
        rep.size = newSize

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            NSSound.beep()
            return
        }
        NSGraphicsContext.current = ctx

        // No CTM Y-flip here: `bakedImage()` returns pixels in natural
        // orientation, and `NSImage.draw(in:)` does *not* compensate for a
        // flipped CTM (it queries `NSGraphicsContext.current.isFlipped`,
        // which stays false). Drawing through a Y-flipped CTM would invert
        // the screenshot in bitmap memory each invocation. Since this pass
        // contains no annotation drawing in canvas-space coords (only
        // image composition + a drop shadow), keeping the standard CG
        // (Y-up) orientation produces correctly-oriented output.
        let cg = ctx.cgContext

        // 1. Backdrop: a heavily-blurred copy of the baked image scaled to
        //    fill the (same-aspect) canvas. Same aspect means a simple
        //    uniform scale — no cropping needed. Skipped for the torn
        //    variant so the area outside the torn polygon stays fully
        //    transparent — the result looks like a real torn-paper cut-out.
        if !torn {
            let backdrop = Self.makeBlurred(baked, heavy: true)
            backdrop.draw(in: NSRect(origin: .zero, size: newSize),
                          from: .zero,
                          operation: .copy,
                          fraction: 1.0)
        }

        // 2. Subtle drop shadow underneath the screenshot for a floating feel.
        //    Shadow offset is in CTM (Y-up) space here, so a *negative* Y
        //    component drops the shadow toward the visible bottom edge.
        //    The torn variant uses a softer shadow because it only has the
        //    small inset band to render into.
        let shadow = NSShadow()
        if torn {
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = max(4, referenceInset * 0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -max(2, referenceInset * 0.10))
        } else {
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = max(8, referenceInset * 0.4)
            shadow.shadowOffset = NSSize(width: 0, height: -max(4, referenceInset * 0.12))
        }
        shadow.set()

        // 3. Foreground screenshot.
        if torn {
            // Clip the screenshot to a jagged perimeter. The outer shadow set
            // above gets applied to the composited layer at endTransparency
            // Layer, so it traces the irregular silhouette instead of a
            // rectangle. The image itself is drawn at its native size (no
            // padding), so the clipped band reveals the blurred backdrop.
            let seed = Self.tornSeed(start: CGPoint(x: imageRect.minX, y: imageRect.minY),
                                     end: CGPoint(x: imageRect.maxX, y: imageRect.maxY))
            // amplitude < inset so jitter never escapes the canvas.
            let amplitude = max(6, min(min(imageRect.width, imageRect.height) * 0.025,
                                       referenceInset * 0.7))
            let path = Self.tornRectPath(in: imageRect,
                                         seed: seed,
                                         amplitude: amplitude,
                                         segmentsPerEdge: 32)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            path.addClip()
            baked.draw(in: NSRect(origin: .zero, size: newSize),
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0)
            cg.endTransparencyLayer()
        } else {
            baked.draw(in: imageRect,
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0)
        }

        NSGraphicsContext.restoreGraphicsState()

        let framed = NSImage(size: newSize)
        framed.addRepresentation(rep)

        performMutation {
            self.image = framed
            self.annotations.removeAll()
            self.blurredImageCache = nil
        }
    }

    /// Drop the screenshot onto a padded, gradient-coloured background with
    /// rounded corners and a soft drop shadow — the same UX as Xnapper /
    /// CleanShot's "Background" mode. Undoable. Output is the union of the
    /// padding + the screenshot, at native pixel resolution.
    func applyBeautify(preset: BeautifyPreset) {
        guard let baked = bakedImage() else { NSSound.beep(); return }
        let bakedSize = baked.size
        let shorter = min(bakedSize.width, bakedSize.height)
        // Padding ~12% of shorter side feels right at common screen sizes
        // (small screenshots get proportionally more breathing room).
        let pad = max(48, floor(shorter * 0.12))
        let cornerRadius = max(6, floor(shorter * 0.012))
        let newSize = NSSize(width: bakedSize.width + pad * 2,
                             height: bakedSize.height + pad * 2)
        let imageRect = NSRect(x: pad, y: pad,
                               width: bakedSize.width, height: bakedSize.height)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newSize.width),
            pixelsHigh: Int(newSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { NSSound.beep(); return }
        rep.size = newSize

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            NSSound.beep()
            return
        }
        NSGraphicsContext.current = ctx

        // 1. Gradient (or solid) background filling the whole canvas.
        let (c1, c2) = preset.colors
        let bgRect = NSRect(origin: .zero, size: newSize)
        if c1 == c2 {
            c1.setFill()
            bgRect.fill()
        } else {
            let gradient = NSGradient(starting: c1, ending: c2)
            // 135° gives a tasteful top-left → bottom-right sweep.
            gradient?.draw(in: bgRect, angle: 315)
        }

        // 2. Drop shadow under the screenshot. Negative Y in CG (Y-up)
        // pushes the shadow toward the visible bottom edge.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = max(12, pad * 0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -max(6, pad * 0.12))
        shadow.set()

        // 3. Foreground screenshot, clipped to a rounded rect so the corners
        // match the modern macOS window aesthetic. The shadow above traces
        // the rounded silhouette because it's applied to the transparency
        // layer's final alpha.
        let clipPath = NSBezierPath(roundedRect: imageRect,
                                    xRadius: cornerRadius,
                                    yRadius: cornerRadius)
        ctx.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        clipPath.addClip()
        baked.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.cgContext.endTransparencyLayer()

        NSGraphicsContext.restoreGraphicsState()

        let framed = NSImage(size: newSize)
        framed.addRepresentation(rep)

        performMutation {
            self.image = framed
            self.annotations.removeAll()
            self.blurredImageCache = nil
        }
    }

    /// Bake current annotations into a fresh pixel-resolution image cropped
    /// to `displayRect`, then atomically swap it into the canvas. The pre-crop
    /// state is pushed to the undo stack so the user can recover it.
    func applyCrop(displayRect: NSRect) {
        guard let baked = bakedImage() else { NSSound.beep(); return }
        let sx = baked.size.width / displaySize.width
        let sy = baked.size.height / displaySize.height
        let pxRect = CGRect(
            x: displayRect.minX * sx,
            y: displayRect.minY * sy,
            width: displayRect.width * sx,
            height: displayRect.height * sy
        ).integral
        guard let cropped = baked.cropped(to: pxRect) else { NSSound.beep(); return }
        performMutation {
            self.image = cropped
            self.displaySize = displayRect.size
            self.annotations.removeAll()
            self.blurredImageCache = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        for ann in annotations { drawAnnotation(ann) }
        if let ann = current { drawAnnotation(ann) }
    }

    func flattenedPNG() -> Data? {
        guard let rep = makeFlattenedRep() else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Bake the source image + every annotation (except the in-progress crop
    /// rectangle) into a fresh NSImage at the source's pixel resolution.
    func bakedImage() -> NSImage? {
        guard let rep = makeFlattenedRep() else { return nil }
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }

    /// Returns the original (un-annotated) source image at its native pixel
    /// resolution as a fresh `NSImage`. Used by OCR — annotations baked over
    /// text confuse Vision, and `image.size` is in points on Retina, so we
    /// can't just hand back `self.image` directly.
    func sourceImageAtNativePixels() -> NSImage? {
        let pixelSize = nativePixelSize()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = pixelSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: pixelSize))
        let out = NSImage(size: pixelSize)
        out.addRepresentation(rep)
        return out
    }

    /// Resolves the true pixel size of the underlying bitmap, ignoring NSImage's
    /// point-based `size` property. Falls back to point size if no bitmap rep
    /// is available (e.g. for vector images, which we don't actually use).
    private func nativePixelSize() -> NSSize {
        // `representations` is ordered "best last" for some image sources, so
        // iterate and pick the rep with the largest pixel area.
        var best: NSSize?
        for rep in image.representations {
            let w = rep.pixelsWide
            let h = rep.pixelsHigh
            // `pixelsWide == NSImageRepMatchesDevice` (-1) means the rep is
            // resolution-independent; skip those.
            guard w > 0, h > 0 else { continue }
            let size = NSSize(width: w, height: h)
            if let b = best {
                if size.width * size.height > b.width * b.height { best = size }
            } else {
                best = size
            }
        }
        return best ?? image.size
    }

    private func makeFlattenedRep() -> NSBitmapImageRep? {
        // Use native pixel resolution, NOT `image.size` (which is points and
        // halves resolution on Retina captures). This matters for OCR quality
        // and for not blurring "Save as…" outputs.
        let pixelSize = nativePixelSize()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = pixelSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx

        // 1) Draw the base image in the *unflipped* CG context. Going through
        // `NSImage.draw(in:)` in a CTM-flipped context inverts the image's
        // own pixels in bitmap memory (it doesn't compensate for the CTM —
        // it queries `NSGraphicsContext.current.isFlipped`, which stays
        // false here), so the resulting PNG re-opens upside-down. Drawing
        // first, before any CTM transform, keeps the source pixels right-
        // side up on disk.
        image.draw(in: NSRect(origin: .zero, size: pixelSize))

        // 2) Annotations were recorded in the canvas's flipped (top-left
        // origin) space. Apply the Y-flip *only* for the annotation pass so
        // the drawing math lines up with what the user saw on-screen,
        // without contaminating the image we just rendered above.
        let cg = ctx.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: pixelSize.height)
        cg.scaleBy(x: 1, y: -1)

        // Scale annotations from the on-screen canvas size back to native px.
        let sx = pixelSize.width / displaySize.width
        let sy = pixelSize.height / displaySize.height
        for ann in annotations where ann.tool != .crop {
            drawAnnotation(ann, scaleX: sx, scaleY: sy)
        }
        cg.restoreGState()
        return rep
    }

    private func drawAnnotation(_ ann: Annotation, scaleX: CGFloat = 1, scaleY: CGFloat = 1) {
        ann.color.setStroke()
        ann.color.setFill()
        let path = NSBezierPath()
        let strokeWidth = ann.lineWidth * scaleX
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let p0 = CGPoint(x: ann.start.x * scaleX, y: ann.start.y * scaleY)
        let p1 = CGPoint(x: ann.end.x * scaleX, y: ann.end.y * scaleY)

        switch ann.tool {
        case .rectangle:
            let r = NSRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                           width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            path.appendRect(r)
            path.stroke()
        case .oval:
            let r = NSRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                           width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            let oval = NSBezierPath(ovalIn: r)
            oval.lineWidth = strokeWidth
            oval.stroke()
        case .arrow:
            path.move(to: p0)
            path.line(to: p1)
            path.stroke()
            drawArrowhead(from: p0, to: p1, color: ann.color, lineWidth: strokeWidth)
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: max(14, ann.lineWidth * 6) * scaleX),
                .foregroundColor: ann.color
            ]
            NSAttributedString(string: ann.text, attributes: attrs).draw(at: p0)
        case .pen:
            guard ann.path.count >= 2 else {
                // Single-point click — draw a dot so it isn't invisible.
                let dot = NSBezierPath(ovalIn: NSRect(
                    x: p0.x - strokeWidth / 2, y: p0.y - strokeWidth / 2,
                    width: strokeWidth, height: strokeWidth))
                dot.fill()
                break
            }
            let pen = NSBezierPath()
            pen.lineCapStyle = .round
            pen.lineJoinStyle = .round
            pen.lineWidth = strokeWidth
            pen.move(to: CGPoint(x: ann.path[0].x * scaleX, y: ann.path[0].y * scaleY))
            for i in 1..<ann.path.count {
                pen.line(to: CGPoint(x: ann.path[i].x * scaleX, y: ann.path[i].y * scaleY))
            }
            pen.stroke()
        case .highlighter:
            guard ann.path.count >= 2 else { break }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .multiply
            let hl = NSBezierPath()
            hl.lineCapStyle = .round
            hl.lineJoinStyle = .round
            hl.lineWidth = strokeWidth * 3.5
            hl.move(to: CGPoint(x: ann.path[0].x * scaleX, y: ann.path[0].y * scaleY))
            for i in 1..<ann.path.count {
                hl.line(to: CGPoint(x: ann.path[i].x * scaleX, y: ann.path[i].y * scaleY))
            }
            ann.color.withAlphaComponent(0.35).setStroke()
            hl.stroke()
            NSGraphicsContext.restoreGraphicsState()
        case .callout:
            drawCallout(p0: p0, p1: p1, text: ann.text, color: ann.color, scale: scaleX)
        case .redact:
            let r = NSRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                           width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            NSColor.black.setFill()
            r.fill()
        case .blur:
            let r = NSRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                           width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            guard r.width > 0, r.height > 0,
                  let cgctx = NSGraphicsContext.current?.cgContext else { break }

            // Feather scales with the shorter side so wide and tall selections
            // both fade pleasantly; clamped so tiny rects still have a visible
            // soft edge and large rects don't lose their entire interior.
            let feather = max(2, min(min(r.width, r.height) * 0.22, 48 * scaleX))

            NSGraphicsContext.saveGraphicsState()
            cgctx.beginTransparencyLayer(auxiliaryInfo: nil)

            // Clip both the blurred image and the alpha-mask gradients to the
            // user's rectangle so the soft-edge math is confined to that area.
            NSBezierPath(rect: r).addClip()

            // Draw the pre-blurred image so the blurred region stays visually
            // continuous with the surrounding screenshot.
            if scaleX == 1 && scaleY == 1 {
                blurredImage.draw(in: NSRect(origin: .zero, size: bounds.size))
            } else {
                blurredImage.draw(in: NSRect(origin: .zero,
                                             size: NSSize(width: displaySize.width * scaleX,
                                                          height: displaySize.height * scaleY)))
            }

            // Multiply the layer's alpha by four 1D ramps (one per edge) so
            // the rectangle's interior stays fully blurred while every edge
            // fades naturally. Overlapping ramps at corners give a soft
            // rounded falloff for free.
            cgctx.setBlendMode(.destinationIn)
            let clearColor = CGColor(gray: 1, alpha: 0)
            let opaqueColor = CGColor(gray: 1, alpha: 1)
            if let ramp = CGGradient(colorsSpace: nil,
                                     colors: [clearColor, opaqueColor] as CFArray,
                                     locations: [0, 1]) {
                let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                cgctx.drawLinearGradient(ramp,
                                         start: CGPoint(x: r.minX, y: r.midY),
                                         end: CGPoint(x: r.minX + feather, y: r.midY),
                                         options: opts)
                cgctx.drawLinearGradient(ramp,
                                         start: CGPoint(x: r.maxX, y: r.midY),
                                         end: CGPoint(x: r.maxX - feather, y: r.midY),
                                         options: opts)
                cgctx.drawLinearGradient(ramp,
                                         start: CGPoint(x: r.midX, y: r.minY),
                                         end: CGPoint(x: r.midX, y: r.minY + feather),
                                         options: opts)
                cgctx.drawLinearGradient(ramp,
                                         start: CGPoint(x: r.midX, y: r.maxY),
                                         end: CGPoint(x: r.midX, y: r.maxY - feather),
                                         options: opts)
            }

            cgctx.endTransparencyLayer()
            NSGraphicsContext.restoreGraphicsState()
        case .blurTorn:
            let r = NSRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                           width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            guard r.width > 0, r.height > 0 else { break }

            // Hand-torn paper look: clip the pre-blurred image to a jagged
            // polygon walked around the rect perimeter. The random offsets
            // are seeded from the annotation's anchor coords so the pattern
            // stays identical between the on-screen preview and the exported
            // pixels (and between re-renders during scroll, undo, etc.).
            let seed = Self.tornSeed(start: ann.start, end: ann.end)
            let amplitude = max(3, min(min(r.width, r.height) * 0.05, 16 * scaleX))
            let path = Self.tornRectPath(in: r,
                                         seed: seed,
                                         amplitude: amplitude,
                                         segmentsPerEdge: 18)

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            if scaleX == 1 && scaleY == 1 {
                blurredImage.draw(in: NSRect(origin: .zero, size: bounds.size))
            } else {
                blurredImage.draw(in: NSRect(origin: .zero,
                                             size: NSSize(width: displaySize.width * scaleX,
                                                          height: displaySize.height * scaleY)))
            }
            NSGraphicsContext.restoreGraphicsState()
        case .crop:
            // Crop has no permanent representation; only the in-progress drag
            // overlay is rendered.
            let r = NSRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                           width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            NSColor.black.withAlphaComponent(0.25).setFill()
            let outer = NSBezierPath()
            outer.appendRect(bounds)
            outer.appendRect(r)
            outer.windingRule = .evenOdd
            outer.fill()
            NSColor.systemYellow.setStroke()
            let stroked = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            stroked.lineWidth = 1.5
            stroked.setLineDash([6, 4], count: 2, phase: 0)
            stroked.stroke()
        }
    }

    private func drawArrowhead(from p0: CGPoint, to p1: CGPoint, color: NSColor, lineWidth: CGFloat) {        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        guard hypot(dx, dy) > 1 else { return }
        let angle = atan2(dy, dx)
        let len = max(10, lineWidth * 3.5)
        let a = CGPoint(x: p1.x - len * cos(angle - .pi / 6),
                        y: p1.y - len * sin(angle - .pi / 6))
        let b = CGPoint(x: p1.x - len * cos(angle + .pi / 6),
                        y: p1.y - len * sin(angle + .pi / 6))
        let head = NSBezierPath()
        head.move(to: p1)
        head.line(to: a)
        head.line(to: b)
        head.close()
        color.setFill()
        head.fill()
    }

    // MARK: - Torn Blur helpers

    /// Tiny deterministic RNG (xorshift64) so the torn-edge pattern stays
    /// identical between the on-screen preview and the exported pixels, and
    /// across undo/redo or window resizes.
    private struct TornRNG {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0xDEADBEEFCAFEBABE : seed }
        mutating func next() -> UInt64 {
            var x = state
            x ^= x << 13
            x ^= x >> 7
            x ^= x << 17
            state = x
            return x
        }
        mutating func unit() -> CGFloat {
            // Top 53 bits of xorshift output have the best statistical quality.
            let u = next() >> 11
            return CGFloat(u) / CGFloat(UInt64(1) << 53)
        }
        mutating func signed(_ amplitude: CGFloat) -> CGFloat {
            (unit() * 2 - 1) * amplitude
        }
    }

    /// Hash the annotation's start/end (always in display coords, immutable
    /// after the drag finishes) into a 64-bit seed for the torn-edge RNG.
    private static func tornSeed(start: CGPoint, end: CGPoint) -> UInt64 {
        func quant(_ v: CGFloat) -> UInt64 {
            UInt64(bitPattern: Int64((v * 100).rounded()))
        }
        var h = quant(start.x) &* 73856093
        h ^= quant(start.y) &* 19349663
        h ^= quant(end.x) &* 83492791
        h ^= quant(end.y) &* 472882049
        return h == 0 ? 0xA5A5A5A5A5A5A5A5 : h
    }

    /// Walks the four edges of `r`, dropping `segmentsPerEdge` vertices per
    /// edge with a perpendicular jitter of ±`amplitude`. The closed polygon
    /// roughly tracks the rectangle but has the ragged contour of torn paper.
    private static func tornRectPath(in r: NSRect,
                                     seed: UInt64,
                                     amplitude: CGFloat,
                                     segmentsPerEdge: Int) -> NSBezierPath {
        var rng = TornRNG(seed: seed)
        let steps = max(4, segmentsPerEdge)
        let corners: [CGPoint] = [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY)
        ]
        // Perpendicular (outward) unit vector for each edge in screen coords.
        let perps: [CGPoint] = [
            CGPoint(x: 0, y: -1), // bottom edge
            CGPoint(x: 1, y: 0),  // right edge
            CGPoint(x: 0, y: 1),  // top edge
            CGPoint(x: -1, y: 0)  // left edge
        ]
        let path = NSBezierPath()
        for edge in 0..<4 {
            let s = corners[edge]
            let e = corners[(edge + 1) % 4]
            let perp = perps[edge]
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                // Dampen the very-near-corner samples so adjacent edges meet
                // without wild spikes at the four corners.
                let damp: CGFloat = (i == 0 || i == steps - 1) ? 0.25 : 1.0
                let off = rng.signed(amplitude) * damp
                let pt = CGPoint(x: s.x + (e.x - s.x) * t + perp.x * off,
                                 y: s.y + (e.y - s.y) * t + perp.y * off)
                if edge == 0 && i == 0 {
                    path.move(to: pt)
                } else {
                    path.line(to: pt)
                }
            }
        }
        path.close()
        return path
    }

    /// `p0` is the tail tip (the anchor in the screenshot), `p1` is the
    /// centre of the rounded balloon. We size the balloon to fit `text` and
    /// route a triangular tail from the nearest balloon edge to `p0`.
    private func drawCallout(p0: CGPoint, p1: CGPoint, text: String, color: NSColor, scale: CGFloat) {
        let fontSize = max(13, 13 * scale)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attr = NSAttributedString(string: text.isEmpty ? "Note" : text, attributes: textAttrs)
        let textSize = attr.size()
        let pad: CGFloat = 10 * scale
        let balloon = NSRect(
            x: p1.x - textSize.width / 2 - pad,
            y: p1.y - textSize.height / 2 - pad,
            width: textSize.width + pad * 2,
            height: textSize.height + pad * 2
        )

        let dx = p0.x - balloon.midX
        let dy = p0.y - balloon.midY
        let tailHalf: CGFloat = 8 * scale
        let baseX: CGFloat
        let baseY: CGFloat
        let horizontal = abs(dx) > abs(dy)
        if horizontal {
            baseX = dx > 0 ? balloon.maxX : balloon.minX
            baseY = max(balloon.minY + tailHalf, min(balloon.maxY - tailHalf, p0.y))
        } else {
            baseX = max(balloon.minX + tailHalf, min(balloon.maxX - tailHalf, p0.x))
            baseY = dy > 0 ? balloon.maxY : balloon.minY
        }

        let corner: CGFloat = 8 * scale
        let balloonPath = NSBezierPath(roundedRect: balloon, xRadius: corner, yRadius: corner)
        let tailPath = NSBezierPath()
        if horizontal {
            tailPath.move(to: CGPoint(x: baseX, y: baseY - tailHalf))
            tailPath.line(to: CGPoint(x: baseX, y: baseY + tailHalf))
        } else {
            tailPath.move(to: CGPoint(x: baseX - tailHalf, y: baseY))
            tailPath.line(to: CGPoint(x: baseX + tailHalf, y: baseY))
        }
        tailPath.line(to: p0)
        tailPath.close()

        color.setFill()
        balloonPath.fill()
        tailPath.fill()

        attr.draw(at: CGPoint(x: balloon.minX + pad, y: balloon.minY + pad))
    }

    private func promptText(title: String = "Add text", _ completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Text…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let resp = alert.runModal()
        completion(resp == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    /// Pre-compute a Gaussian-blurred copy of `source` so the blur tool can
    /// composite from it cheaply. Falls back to the original on any failure.
    /// `heavy` ramps the radius up significantly for backdrop framing where
    /// individual features should dissolve into colour gradients.
    static func makeBlurred(_ source: NSImage, heavy: Bool = false) -> NSImage {
        guard let tiff = source.tiffRepresentation,
              let ciInput = CIImage(data: tiff) else {
            return source
        }
        let filter = CIFilter.gaussianBlur()
        // Clamp to extend edges before blurring so the result fills the full
        // extent without dark fall-off at the borders (matters most for the
        // heavy/backdrop variant).
        filter.inputImage = ciInput.clampedToExtent()
        if heavy {
            filter.radius = Float(max(40, min(160, ciInput.extent.width * 0.06)))
        } else {
            // Radius scaled by image size so screenshots from any display feel similar.
            filter.radius = Float(max(8, min(36, ciInput.extent.width * 0.014)))
        }
        guard let outputCI = filter.outputImage?.cropped(to: ciInput.extent) else {
            return source
        }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(outputCI, from: ciInput.extent) else {
            return source
        }
        return NSImage(cgImage: cg, size: source.size)
    }
}

// MARK: - NSImage cropping helper

private extension NSImage {
    /// Crop to `rect` in pixel coordinates with top-left origin (CoreGraphics
    /// convention). Returns a new NSImage sized to the cropped pixel extent.
    func cropped(to rect: CGRect) -> NSImage? {
        var proposedRect = NSRect(origin: .zero, size: self.size)
        guard let cg = self.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              let cropped = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: rect.size)
    }
}

// MARK: - Color swatch button

private final class ColorSwatchButton: NSButton {
    let color: NSColor
    var isSelectedSwatch: Bool = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        self.title = ""
        self.isBordered = false
        self.bezelStyle = .smallSquare // suppress default rounded bezel under the layer
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// NSButton's default intrinsic size collapses to ~0 when there's no
    /// title, image, or bezel content. Under NSStackView that means the
    /// swatch disappears entirely. Force the layout-driven size instead.
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        color.setFill()
        let p = NSBezierPath(ovalIn: r)
        p.fill()
        (isSelectedSwatch ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        p.lineWidth = isSelectedSwatch ? 2 : 1
        p.stroke()
    }
}

// MARK: - Custom color picker button

/// A button that visually screams "open the color picker" by drawing a
/// rainbow conic-gradient ring around the currently selected color.
/// Tapping it brings up the shared `NSColorPanel` and reports color changes
/// through `action`/`target`. We deliberately don't use `NSColorWell`:
/// its boxy "color rectangle" look was too easy to mistake for one of the
/// preset swatches that sit right next to it.
final class CustomColorPickerButton: NSControl {
    var color: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }

    private static var sharedPanelObserverInstalled = false
    /// Tracks whether this particular button is currently the recipient of
    /// the shared color panel. Without this, every picker on screen would
    /// react to one user dragging the panel.
    private var isActive = false
    /// Weakly tracks the button that currently owns the shared color panel
    /// so we can clear its `isActive` flag when ownership transfers.
    private static weak var currentOwner: CustomColorPickerButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let panel = NSColorPanel.shared
        panel.color = color
        panel.showsAlpha = false
        // Reset any previous picker's hold on the panel so only one button
        // listens at a time. The shared panel doesn't expose its current
        // target/action publicly, so we track ownership ourselves.
        Self.currentOwner?.isActive = false
        Self.currentOwner = self
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        isActive = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        guard isActive else { return }
        color = sender.color
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let ringWidth: CGFloat = max(3, outerRadius * 0.32)
        let innerRadius = outerRadius - ringWidth

        // --- Rainbow ring (drawn as many small filled wedges). 36 steps
        // gives a smooth gradient without going overboard on draw calls.
        let steps = 36
        for i in 0..<steps {
            let startAngle = (CGFloat(i)     / CGFloat(steps)) * 2 * .pi
            let endAngle   = (CGFloat(i + 1) / CGFloat(steps)) * 2 * .pi
            let hue = CGFloat(i) / CGFloat(steps)
            let segColor = NSColor(hue: hue, saturation: 1.0, brightness: 1.0, alpha: 1.0).cgColor
            ctx.setFillColor(segColor)
            ctx.beginPath()
            ctx.move(to: center)
            ctx.addArc(center: center, radius: outerRadius,
                       startAngle: startAngle, endAngle: endAngle, clockwise: false)
            ctx.closePath()
            ctx.fillPath()
        }

        // Punch out the inner disc so the rainbow becomes a ring, and fill
        // the inner disc with the current color so the button doubles as a
        // preview of what's selected.
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                   width: innerRadius * 2, height: innerRadius * 2))
        let swatchInset: CGFloat = 1.5
        let swatchRect = CGRect(x: center.x - innerRadius + swatchInset,
                                y: center.y - innerRadius + swatchInset,
                                width: (innerRadius - swatchInset) * 2,
                                height: (innerRadius - swatchInset) * 2)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: swatchRect)

        // Subtle hairline so the button reads on light + dark backgrounds.
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: CGRect(x: center.x - outerRadius + 0.25,
                                     y: center.y - outerRadius + 0.25,
                                     width: outerRadius * 2 - 0.5,
                                     height: outerRadius * 2 - 0.5))
    }
}

// MARK: - Export accessory view

import UniformTypeIdentifiers

/// Format picker + quality slider used as `NSSavePanel.accessoryView` when
/// exporting an annotated screenshot.
private final class ExportAccessoryView: NSView {
    enum Format: Int {
        case png = 0
        case jpeg = 1
        case heic = 2

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            }
        }

        var uti: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            }
        }

        var shortName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            }
        }

        var supportsQuality: Bool { self != .png }
    }

    var onFormatChange: ((Format) -> Void)?
    private(set) var selectedFormat: Format = .png
    private(set) var qualityValue: CGFloat = 0.9

    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(value: 0.9, minValue: 0.1, maxValue: 1.0,
                                          target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Quality: 90%")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 64))
        translatesAutoresizingMaskIntoConstraints = false

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.font = .systemFont(ofSize: 12)

        formatPopup.addItems(withTitles: ["PNG (lossless)", "JPEG", "HEIC"])
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.numberOfTickMarks = 10
        qualitySlider.allowsTickMarkValuesOnly = false
        qualitySlider.isEnabled = false

        qualityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        qualityLabel.textColor = .secondaryLabelColor
        qualityLabel.isEnabled = false

        let row1 = NSStackView(views: [formatLabel, formatPopup])
        row1.orientation = .horizontal
        row1.spacing = 8
        row1.alignment = .centerY
        row1.translatesAutoresizingMaskIntoConstraints = false

        let row2 = NSStackView(views: [qualityLabel, qualitySlider])
        row2.orientation = .horizontal
        row2.spacing = 10
        row2.alignment = .centerY
        row2.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [row1, row2])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            qualitySlider.widthAnchor.constraint(equalToConstant: 200)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func formatChanged() {
        let format = Format(rawValue: formatPopup.indexOfSelectedItem) ?? .png
        selectedFormat = format
        let enabled = format.supportsQuality
        qualitySlider.isEnabled = enabled
        qualityLabel.isEnabled = enabled
        onFormatChange?(format)
    }

    @objc private func qualityChanged() {
        qualityValue = CGFloat(qualitySlider.doubleValue)
        qualityLabel.stringValue = "Quality: \(Int((qualityValue * 100).rounded()))%"
    }
}
