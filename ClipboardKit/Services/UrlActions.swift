import AppKit
import Foundation

/// Lightweight side-actions you can offer for an item whose text body looks
/// like a URL, mailto/tel link, or a filesystem path. Each action carries a
/// label for the menu and the closure that fires it.
struct UrlAction: Identifiable {
    let id: String
    let label: String
    let perform: () -> Void
}

enum UrlActions {
    /// Open `path` in Seeker (`com.marvel.Seeker`) via its `seeker://reveal?path=…`
    /// URL handler. Used by every "Reveal in Seeker" entry point in the
    /// app so changing the integration only requires editing this method.
    /// Closes the clipboard popover before launching so Seeker can take
    /// focus and the user isn't left looking at a now-unrelated history
    /// list on top of the file they wanted to inspect.
    static func revealInSeeker(path: String) {
        var comps = URLComponents()
        comps.scheme = "seeker"
        comps.host = "reveal"
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = comps.url else { NSSound.beep(); return }
        AppDelegate.shared?.popover.close()
        NSWorkspace.shared.open(url)
    }

    /// Examine `text` and return appropriate side-actions for it. Returns
    /// `nil` (vs. an empty array) when there's nothing to attach so callers
    /// can omit the entire menu section without inserting a stray divider.
    static func detect(in text: String) -> [UrlAction]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Scheme-prefixed URLs win first — they have unambiguous handlers.
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return [openInBrowser(url), copyURL(trimmed)]
            case "mailto":
                return [composeMail(url), copyURL(trimmed)]
            case "tel", "sms", "facetime", "facetime-audio":
                return [callOrMessage(url, scheme: scheme), copyURL(trimmed)]
            case "file":
                if let path = url.path.removingPercentEncoding {
                    return fileActions(path: path)
                }
                return nil
            default:
                // Unknown scheme — still offer "Open with default handler".
                return [openInBrowser(url)]
            }
        }

        // Bare filesystem path (absolute) — only worth surfacing when it
        // actually exists, otherwise it's just a typo in a normal text
        // snippet.
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return fileActions(path: expanded)
            }
        }

        // Looks-like-a-URL without a scheme (e.g. "github.com/x/y"). Only
        // promote when the first token contains a dot and no spaces, to
        // avoid offering "Open in Browser" for ordinary sentences.
        if !trimmed.contains(" "),
           trimmed.contains("."),
           let url = URL(string: "https://" + trimmed),
           url.host?.contains(".") == true {
            return [openInBrowser(url), copyURL(trimmed)]
        }

        return nil
    }

    // MARK: - Individual actions

    private static func openInBrowser(_ url: URL) -> UrlAction {
        UrlAction(id: "open", label: "Open in Browser") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func composeMail(_ url: URL) -> UrlAction {
        UrlAction(id: "mail", label: "Compose Email…") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func callOrMessage(_ url: URL, scheme: String) -> UrlAction {
        let label: String
        switch scheme {
        case "tel":               label = "Call"
        case "sms":               label = "Send Message"
        case "facetime",
             "facetime-audio":    label = "FaceTime"
        default:                  label = "Open"
        }
        return UrlAction(id: "tel", label: label) {
            NSWorkspace.shared.open(url)
        }
    }

    private static func fileActions(path: String) -> [UrlAction] {
        let url = URL(fileURLWithPath: path)
        return [
            UrlAction(id: "open-file", label: "Open") {
                NSWorkspace.shared.open(url)
            },
            UrlAction(id: "reveal-file", label: "Reveal in Seeker") {
                Self.revealInSeeker(path: path)
            },
            UrlAction(id: "copy-path", label: "Copy Path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(path, forType: .string)
            },
        ]
    }

    private static func copyURL(_ str: String) -> UrlAction {
        UrlAction(id: "copy-url", label: "Copy URL") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(str, forType: .string)
        }
    }
}
