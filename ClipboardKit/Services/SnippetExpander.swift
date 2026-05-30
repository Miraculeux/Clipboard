import AppKit
import Foundation

/// Expands template placeholders inside a snippet body at paste time.
///
/// Supported placeholders:
///
/// - `{date}`              – current date in the user's locale, medium style
/// - `{date:FORMAT}`       – `Date` formatted via `DateFormatter` with `FORMAT`
///                           (e.g. `{date:yyyy-MM-dd}`)
/// - `{time}`              – current time, medium style
/// - `{datetime}`          – current date + time
/// - `{clipboard}`         – current pasteboard string contents
/// - `{uuid}`              – fresh lowercase UUID
/// - `{cursor}`            – stripped (no cursor positioning; we paste via
///                           a single ⌘V, no IME insertion point control)
///
/// Unknown placeholders are left untouched on purpose so users don't lose
/// data on a typo — a bare `{foo}` is more likely a literal they want.
enum SnippetExpander {

    /// Regex compiled once. `[\w:.\\- ]+` allows the `date:format` form,
    /// dots in formats, hyphens, and spaces — enough for typical date
    /// patterns without letting arbitrary nested braces through.
    private static let placeholderRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\{([A-Za-z]+)(?::([^}]+))?\\}")
    }()

    /// Apply variable substitution to `template`. Returns the input
    /// unchanged when there are no `{…}` placeholders.
    static func expand(_ template: String, now: Date = Date()) -> String {
        let ns = template as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = placeholderRegex.matches(in: template, range: range)
        guard !matches.isEmpty else { return template }

        var result = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            if full.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let arg: String? = {
                let r = m.range(at: 2)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }()
            if let replacement = replacement(for: name, arg: arg, now: now) {
                result += replacement
            } else {
                // Unknown placeholder — leave it in so the user notices.
                result += ns.substring(with: full)
            }
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }

    private static func replacement(for name: String, arg: String?, now: Date) -> String? {
        switch name {
        case "date":
            if let format = arg {
                let f = DateFormatter()
                f.dateFormat = format
                return f.string(from: now)
            }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f.string(from: now)
        case "time":
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .medium
            return f.string(from: now)
        case "datetime":
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .medium
            return f.string(from: now)
        case "clipboard":
            return NSPasteboard.general.string(forType: .string) ?? ""
        case "uuid":
            return UUID().uuidString.lowercased()
        case "cursor":
            // No cursor positioning support — drop the marker.
            return ""
        default:
            return nil
        }
    }
}
