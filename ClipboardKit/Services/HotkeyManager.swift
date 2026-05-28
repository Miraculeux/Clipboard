import AppKit
import Carbon.HIToolbox

/// All user-bindable hotkey actions.
enum HotkeyAction: Int, CaseIterable, Codable {
    case toggleHistory = 1
    case captureRegion = 2
    case captureLongScreenshot = 3
    case captureFullScreen = 4
    case captureWindow = 5

    var title: String {
        switch self {
        case .toggleHistory: return "Toggle clipboard history"
        case .captureRegion: return "Capture screen region"
        case .captureLongScreenshot: return "Long (scrolling) screenshot"
        case .captureFullScreen: return "Capture full screen"
        case .captureWindow: return "Capture window"
        }
    }

    /// Default Carbon keyCode + modifier mask shipped with the app.
    var defaultBinding: HotkeyBinding {
        switch self {
        case .toggleHistory:
            return HotkeyBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        case .captureRegion:
            return HotkeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
        case .captureLongScreenshot:
            return HotkeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | shiftKey))
        case .captureFullScreen:
            // No default to avoid clashing with macOS's own ⌘⇧3; users opt in.
            return .disabled
        case .captureWindow:
            // No default to avoid clashing with macOS's own ⌘⇧4 (Space);
            // users opt in.
            return .disabled
        }
    }
}

/// Persistable representation of one hotkey. `keyCode == UInt32.max` means disabled.
struct HotkeyBinding: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let disabled = HotkeyBinding(keyCode: .max, modifiers: 0)

    var isDisabled: Bool { keyCode == .max }

    /// Pretty form like "⌘⇧V".
    var displayString: String {
        if isDisabled { return "—" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += KeyCodeNames.name(for: keyCode)
        return s
    }
}

/// Centralized Carbon hotkey registration. Replaces per-call boilerplate
/// scattered across `AppDelegate`. Bindings come from `SettingsManager`.
final class HotkeyManager: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HotkeyManager()

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var onPressed: ((HotkeyAction) -> Void)?

    private init() {}

    /// Install the global Carbon handler and (re)register every action's
    /// current binding. Call once at app launch.
    func install(_ onPressed: @escaping (HotkeyAction) -> Void) {
        self.onPressed = onPressed
        installEventHandler()
        reregisterAll()
    }

    /// Re-read all bindings from settings and re-register. Call after the
    /// user changes a hotkey.
    func reregisterAll() {
        for action in HotkeyAction.allCases {
            register(action, binding: SettingsManager.shared.hotkey(for: action))
        }
    }

    private func register(_ action: HotkeyAction, binding: HotkeyBinding) {
        if let existing = refs[action] {
            UnregisterEventHotKey(existing)
            refs[action] = nil
        }
        guard !binding.isDisabled else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x434C4950), id: UInt32(action.rawValue))
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[action] = ref
        } else {
            print("HotkeyManager: failed to register \(action) — status \(status)")
        }
    }

    private func installEventHandler() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil, &hkID)
            guard status == noErr, let userData else { return status }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let action = HotkeyAction(rawValue: Int(hkID.id)) {
                DispatchQueue.main.async { mgr.onPressed?(action) }
            }
            return noErr
        }, 1, &eventType, selfPtr, nil)
        handlerInstalled = true
    }
}

/// Best-effort key name for a Carbon virtual keycode. Covers the characters
/// most users will pick for shortcuts — anything else falls back to a hex tag.
enum KeyCodeNames {
    static func name(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "␣"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return String(format: "0x%02X", keyCode)
        }
    }
}

/// Convert from Cocoa `NSEvent.modifierFlags` to Carbon's mask used by
/// `RegisterEventHotKey`. Only the four standard modifiers are surfaced.
enum HotkeyModifierConversion {
    static func carbonMask(from cocoa: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if cocoa.contains(.command) { mask |= UInt32(cmdKey) }
        if cocoa.contains(.shift)   { mask |= UInt32(shiftKey) }
        if cocoa.contains(.option)  { mask |= UInt32(optionKey) }
        if cocoa.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}
