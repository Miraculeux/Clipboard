import Foundation
import AppKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Optical character recognition wrapper around `VNRecognizeTextRequest`.
///
/// All public APIs are non-blocking: work happens on a utility-QoS background
/// queue and `completion` fires on the main queue so callers can update UI
/// directly. Designed for ad-hoc invocation from the annotator and the
/// history context menu — there is no batching / queue, callers serialize
/// themselves if they need to.
enum OCRService {
    enum OCRError: LocalizedError, Sendable {
        case invalidImage
        case visionFailed(String)
        case noTextFound

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Couldn’t read the image for recognition."
            case .visionFailed(let msg): return "Recognition failed: \(msg)"
            case .noTextFound: return "No text was found in the image."
            }
        }
    }

    /// Languages we ask Vision to consider, in priority order. We deliberately
    /// disable `automaticallyDetectsLanguage` (see below) because on macOS 13+
    /// turning it on causes Vision to *ignore* this list and pick a single
    /// language, which produces terrible results on the common case here —
    /// screenshots that mix Simplified Chinese and English.
    private static let preferredLanguages: [String] = [
        "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"
    ]

    /// Recognize all text in `image`, returning the joined lines (top-to-bottom)
    /// or an error. `completion` is invoked on the main queue.
    static func recognizeText(in image: NSImage,
                              completion: @Sendable @escaping (Result<String, OCRError>) -> Void) {
        // Pull the highest-resolution CGImage we can. `cgImage(forProposedRect:)`
        // returns the best available bitmap representation for screenshots
        // loaded from disk or pasteboard, at native pixel size.
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Fallback: rasterize through TIFFRepresentation in case the image
            // is a vector / wrapped representation that doesn't expose a CGImage
            // directly.
            if let tiff = image.tiffRepresentation,
               let src = CGImageSourceCreateWithData(tiff as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                recognize(cgImage: preprocess(cg), orientation: .up, completion: completion)
                return
            }
            DispatchQueue.main.async { completion(.failure(.invalidImage)) }
            return
        }
        recognize(cgImage: preprocess(cgImage), orientation: .up, completion: completion)
    }

    /// Recognize all text in the PNG/JPEG at `url`. `completion` is on main.
    /// Loads via `CGImageSource` so we can honor EXIF orientation, then runs
    /// the same preprocessing as the in-memory path.
    static func recognizeText(at url: URL,
                              completion: @Sendable @escaping (Result<String, OCRError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                DispatchQueue.main.async { completion(.failure(.invalidImage)) }
                return
            }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
            // `preprocess` bakes the orientation into the returned CGImage so
            // by the time it reaches Vision the image is already upright.
            let processed = preprocess(cg, orientation: orientation)
            recognize(cgImage: processed, orientation: .up, completion: completion)
        }
    }

    /// Cached CI context. CIContext is expensive to construct; reusing one
    /// across OCR calls is the documented Apple recommendation.
    private static let ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Image preprocessing that materially improves Vision's accuracy on
    /// small / low-contrast screenshots:
    ///   • Bakes EXIF orientation so observations come back in screen space.
    ///   • Upscales to a minimum short-side of 1600 px via Lanczos (Vision
    ///     starts struggling on text smaller than ~14 px tall; doubling
    ///     resolution effectively doubles glyph height).
    ///   • Slight contrast bump (×1.10) — helps with low-contrast UI text
    ///     like greyed-out labels or dark-on-dark dropdowns.
    /// If the source is already large enough we still bake orientation but
    /// skip resampling.
    private static func preprocess(_ cg: CGImage,
                                   orientation: CGImagePropertyOrientation = .up) -> CGImage {
        var ci = CIImage(cgImage: cg).oriented(orientation)
        let extent = ci.extent
        let shortSide = min(extent.width, extent.height)
        let targetShortSide: CGFloat = 1600
        if shortSide > 0 && shortSide < targetShortSide {
            let scale = targetShortSide / shortSide
            if let scaler = CIFilter(name: "CILanczosScaleTransform") {
                scaler.setValue(ci, forKey: kCIInputImageKey)
                scaler.setValue(scale, forKey: kCIInputScaleKey)
                scaler.setValue(1.0, forKey: kCIInputAspectRatioKey)
                if let out = scaler.outputImage {
                    ci = out
                }
            }
        }
        let contrast = CIFilter.colorControls()
        contrast.inputImage = ci
        contrast.contrast = 1.10
        contrast.saturation = 1.0
        contrast.brightness = 0
        if let out = contrast.outputImage {
            ci = out
        }
        return ciContext.createCGImage(ci, from: ci.extent) ?? cg
    }

    private static func recognize(cgImage: CGImage,
                                  orientation: CGImagePropertyOrientation,
                                  completion: @Sendable @escaping (Result<String, OCRError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = makeTextRequest(completion: completion)
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { completion(.failure(.visionFailed(msg))) }
            }
        }
    }

    /// Build a single configured `VNRecognizeTextRequest`. Centralized so the
    /// URL-based and CGImage-based entry points use the *exact same* tuning.
    private static func makeTextRequest(
        completion: @Sendable @escaping (Result<String, OCRError>) -> Void
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                let msg = error.localizedDescription
                DispatchQueue.main.async { completion(.failure(.visionFailed(msg))) }
                return
            }
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []

            // Vision returns observations in an internal order that's roughly
            // reading order for simple layouts but scrambles on multi-column
            // screenshots. Re-sort top→bottom, left→right using bounding-box
            // centers. Y is in normalized image coords (origin bottom-left).
            let lineTolerance: CGFloat = 0.012
            let sorted = observations.sorted { lhs, rhs in
                let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
                if abs(dy) > lineTolerance { return dy > 0 } // higher = earlier
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
            if lines.isEmpty {
                DispatchQueue.main.async { completion(.failure(.noTextFound)) }
            } else {
                let joined = lines.joined(separator: "\n")
                DispatchQueue.main.async { completion(.success(joined)) }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = preferredLanguages
        // CRITICAL: on macOS 13+ this defaults to `true`, which silently
        // ignores `recognitionLanguages` and lets Vision pick a single
        // language. For mixed CN/EN screenshots that almost always loses
        // one side of the text. Force it off so our priority list wins.
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = false
        }
        // Pin to the newest available revision so we get the latest Chinese
        // training data instead of whatever the historical default is.
        request.revision = VNRecognizeTextRequest.currentRevision
        // Don't filter small text — UI screenshots often have 11–13pt labels.
        request.minimumTextHeight = 0
        return request
    }
}

// MARK: - Result panel

/// Lightweight modal-ish panel that shows the recognized text and offers
/// Copy / Close. Designed to be presented from either the annotator or the
/// history row context menu without taking over the rest of the app.
final class OCRResultWindowController: NSWindowController, NSWindowDelegate {

    /// Keep a strong reference while presented; release on close.
    private static var current: OCRResultWindowController?

    static func present(recognizedText: String,
                        title: String = "Recognized Text",
                        anchor: NSWindow? = nil) {
        // Always copy immediately so users can paste right away without
        // pressing Copy.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(recognizedText, forType: .string)

        let wc = OCRResultWindowController(text: recognizedText, title: title)
        wc.showWindow(nil)
        if let anchor = anchor, let win = wc.window {
            // Center over the anchor window.
            var frame = win.frame
            let aFrame = anchor.frame
            frame.origin = NSPoint(
                x: aFrame.midX - frame.width / 2,
                y: aFrame.midY - frame.height / 2
            )
            win.setFrame(frame, display: true)
        } else {
            wc.window?.center()
        }
        NSApp.activate()
        wc.window?.makeKeyAndOrderFront(nil)
        Self.current = wc
    }

    private init(text: String, title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 220)
        super.init(window: panel)
        panel.delegate = self
        buildUI(text: text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI(text: String) {
        guard let window = self.window else { return }
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        // Header label with a hint that the text is already on the clipboard.
        let hint = NSTextField(labelWithString: "Already copied to clipboard. Edit below or copy again.")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        // Scrollable text view with the recognized text.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        let textView = NSTextView()
        textView.string = text
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        content.addSubview(scroll)
        self.textView = textView

        // Buttons row.
        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyAll))
        copyBtn.bezelStyle = .rounded
        copyBtn.keyEquivalent = "\r"
        copyBtn.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}" // Esc
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [closeBtn, copyBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    private weak var textView: NSTextView?

    @objc private func copyAll() {
        let str = textView?.string ?? ""
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: .string)
        // Brief visual ack via title flash.
        let prev = window?.title
        window?.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.window?.title = prev ?? "Recognized Text"
        }
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if OCRResultWindowController.current === self {
            OCRResultWindowController.current = nil
        }
    }
}
