import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Watches typed keystrokes system-wide and expands snippet abbreviations
/// inline. When the user types an abbreviation followed by a word-boundary
/// trigger (space, tab, return, punctuation), the expander:
///
///  1. Posts ⌫ to erase the abbreviation + the trigger character.
///  2. Writes the (expanded) snippet body to the pasteboard.
///  3. Posts ⌘V to paste it.
///
/// Requires Accessibility permission (System Settings → Privacy & Security
/// → Accessibility). We check at enable time and prompt; without permission
/// the tap won't fire, so the worst-case is "feature silently does nothing"
/// rather than crashing.
///
/// All state lives on the main thread. The CGEvent callback hops to main
/// before mutating the buffer.
@MainActor
final class SnippetAbbreviationExpander {
    static let shared = SnippetAbbreviationExpander()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var enabled = false
    /// Rolling buffer of recently typed characters. Bounded so we don't
    /// keep history forever; the longest snippet abbreviation determines
    /// the lower bound, plus a small margin.
    private var buffer: String = ""
    private static let maxBufferLength = 64
    /// Set while we're posting our own ⌫/⌘V events so the callback can
    /// ignore them — otherwise the synthetic backspaces would themselves
    /// re-trigger the expander.
    private var isInjecting = false

    private init() {}

    /// Bring the expander up to `enabled`, installing or tearing down the
    /// event tap as needed. Idempotent — calling with the current state is
    /// a no-op. If permission is missing the call prompts the user and
    /// returns without installing (will succeed on next call once granted).
    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    // MARK: - Install / uninstall

    private func install() {
        // Prompt for Accessibility if we don't have it yet. The prompt
        // option is intentional — users who toggle this on want to see why
        // it's not working immediately.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let opts: [CFString: Bool] = [promptKey: true]
        guard AXIsProcessTrustedWithOptions(opts as CFDictionary) else {
            // We'll quietly fail; the next toggle-on will retry. Reset our
            // own state so the next attempt isn't a no-op.
            self.enabled = false
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: SnippetAbbreviationExpander.eventCallback,
            userInfo: selfPtr
        ) else {
            NSLog("[SnippetAbbreviationExpander] failed to create event tap")
            self.enabled = false
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        self.buffer = ""
    }

    private func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        runLoopSource = nil
        buffer = ""
    }

    // MARK: - Callback

    private static let eventCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        // The tap can be auto-disabled by the system if our callback runs too
        // long. Re-enable inline and fall through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let refcon {
                let me = Unmanaged<SnippetAbbreviationExpander>.fromOpaque(refcon).takeUnretainedValue()
                if let tap = me.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let me = Unmanaged<SnippetAbbreviationExpander>.fromOpaque(refcon).takeUnretainedValue()
        // The callback runs on a CF runloop thread; everything that touches
        // shared state has to hop to main. Pass the key code + Unicode chars
        // through, then return the event unmodified — we never block the
        // user's typing.
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &actualLength, unicodeString: &chars)
        let typed = String(utf16CodeUnits: chars, count: actualLength)
        DispatchQueue.main.async {
            me.handleKey(keyCode: keyCode, typed: typed, flags: flags)
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Buffer management (main thread)

    private func handleKey(keyCode: Int, typed: String, flags: CGEventFlags) {
        if isInjecting { return }
        // Modifier-only events (shift / option held while typing a letter
        // still produces a printable char in `typed`, so we only filter the
        // hot keys that shouldn't even feed the buffer).
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer.removeAll()
            return
        }

        // Special keys: arrows / page / etc. reset the buffer so the user
        // can't accumulate a trigger across cursor movements.
        switch keyCode {
        case kVK_Delete:
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Escape, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            buffer.removeAll()
            return
        default:
            break
        }

        guard !typed.isEmpty else { return }

        // A "word boundary" character finishes the abbreviation. Check the
        // buffer ending in `abbreviation` + ANY printable typed boundary.
        let isBoundary = typed.unicodeScalars.contains { scalar in
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
        }

        if isBoundary {
            // Look for a snippet whose `abbreviation` matches the end of the
            // buffer. We require at least one snippet to be eligible for
            // expansion; bail otherwise so we don't iterate on every space.
            let snippets = ClipboardManager.shared.snippets.filter { !$0.abbreviation.isEmpty }
            if !snippets.isEmpty {
                if let match = snippets.first(where: { buffer.hasSuffix($0.abbreviation) }) {
                    expand(match: match, boundary: typed)
                    buffer.removeAll()
                    return
                }
            }
            buffer.append(typed)
        } else {
            buffer.append(typed)
        }

        if buffer.count > Self.maxBufferLength {
            buffer.removeFirst(buffer.count - Self.maxBufferLength)
        }
    }

    // MARK: - Injection

    /// Delete the typed abbreviation + boundary, then paste the expanded
    /// snippet body. `boundary` is the trigger character (e.g. " "); we
    /// re-emit it after the paste so the user's cursor lands in a natural
    /// place ("hi[expanded] " instead of "hi[expanded]").
    private func expand(match snippet: Snippet, boundary: String) {
        let toDelete = snippet.abbreviation.count + boundary.count
        let expanded = SnippetExpander.expand(snippet.content)
        guard !expanded.isEmpty else { return }

        isInjecting = true
        defer { isInjecting = false }

        // 1) ⌫ × N to erase the abbreviation + the trigger character.
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<toDelete {
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }

        // 2) Put the expansion on the pasteboard and post ⌘V. We
        // intentionally don't restore the previous clipboard here — the
        // user's most recent copy is preserved by `pasteSnippet` only
        // because that flow snapshots beforehand; this fast-path opts out
        // to keep latency low.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(expanded, forType: .string)

        let vKey = CGKeyCode(kVK_ANSI_V)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}
