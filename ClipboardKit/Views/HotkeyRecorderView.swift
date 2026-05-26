import SwiftUI
import AppKit
import Carbon.HIToolbox

/// SwiftUI wrapper for a global-hotkey recorder.
///
/// Click "Record", press the desired shortcut, and the binding is persisted
/// via `SettingsManager.setHotkey(_:for:)`, which triggers `HotkeyManager` to
/// re-register. Esc cancels recording without changing anything.
struct HotkeyRecorderView: View {
    let action: HotkeyAction
    @ObservedObject var settings: SettingsManager
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 6) {
            HotkeyRecorderField(isRecording: $isRecording, action: action)
                .frame(width: 130, height: 24)
            Button(isRecording ? "Cancel" : "Record") {
                isRecording.toggle()
            }
            .frame(width: 72)
            Button {
                settings.resetHotkey(action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Restore default")
            Button {
                settings.setHotkey(.disabled, for: action)
            } label: {
                Image(systemName: "xmark")
            }
            .help("Clear shortcut")
        }
        .font(.callout)
        .controlSize(.small)
    }
}

private struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var isRecording: Bool
    let action: HotkeyAction

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let v = HotkeyRecorderNSView()
        v.action = action
        v.onCapture = { binding in
            SettingsManager.shared.setHotkey(binding, for: action)
            isRecording = false
        }
        v.onCancel = {
            isRecording = false
        }
        return v
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.action = action
        nsView.isRecording = isRecording
        nsView.refresh()
    }
}

final class HotkeyRecorderNSView: NSView {
    var action: HotkeyAction = .toggleHistory
    var onCapture: ((HotkeyBinding) -> Void)?
    var onCancel: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?

    var isRecording: Bool = false {
        didSet {
            if isRecording { installMonitor() } else { removeMonitor() }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Re-read the currently persisted binding and update the visual state.
    func refresh() {
        if isRecording {
            label.stringValue = "Press shortcut…"
            label.textColor = .secondaryLabelColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        } else {
            let binding = SettingsManager.shared.hotkey(for: action)
            label.stringValue = binding.isDisabled ? "—" : binding.displayString
            label.textColor = .labelColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Int(event.keyCode) == kVK_Escape {
                self.onCancel?()
                return nil
            }
            let cocoaMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let mods = HotkeyModifierConversion.carbonMask(from: cocoaMods)
            let binding = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: mods)
            self.onCapture?(binding)
            return nil
        }
        refresh()
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        refresh()
    }
}
