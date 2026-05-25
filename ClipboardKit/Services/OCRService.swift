import Foundation
import AppKit
import Vision

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

    /// Languages we ask Vision to consider. The system will still
    /// auto-detect when `automaticallyDetectsLanguage` is enabled (macOS 13+),
    /// but providing hints biases the model toward better results for mixed
    /// Chinese / English content, which is the common case for users of this
    /// app.
    private static let preferredLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]

    /// Recognize all text in `image`, returning the joined lines (top-to-bottom)
    /// or an error. `completion` is invoked on the main queue.
    static func recognizeText(in image: NSImage,
                              completion: @Sendable @escaping (Result<String, OCRError>) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            DispatchQueue.main.async { completion(.failure(.invalidImage)) }
            return
        }
        recognize(cgImage: cgImage, completion: completion)
    }

    /// Recognize all text in the PNG/JPEG at `url`. `completion` is on main.
    static func recognizeText(at url: URL,
                              completion: @Sendable @escaping (Result<String, OCRError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                DispatchQueue.main.async { completion(.failure(.invalidImage)) }
                return
            }
            recognize(cgImage: cgImage, completion: completion)
        }
    }

    private static func recognize(cgImage: CGImage,
                                  completion: @Sendable @escaping (Result<String, OCRError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    let msg = error.localizedDescription
                    DispatchQueue.main.async { completion(.failure(.visionFailed(msg))) }
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
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
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { completion(.failure(.visionFailed(msg))) }
            }
        }
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
