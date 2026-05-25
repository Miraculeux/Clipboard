import AppKit
import SwiftUI

/// One-time welcome window shown on first launch. Walks the user through
/// granting Screen Recording permission and reviewing the default hotkeys,
/// then flips `SettingsManager.hasSeenOnboarding` so it never reappears.
final class OnboardingWindowController: @unchecked Sendable {
    nonisolated(unsafe) static let shared = OnboardingWindowController()

    private var window: NSWindow?

    private init() {}

    @MainActor
    func present() {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = OnboardingView { [weak self] in
            self?.dismiss()
        }
        let host = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to ClipboardKit"
        win.contentViewController = host
        win.center()
        win.isReleasedWhenClosed = false
        // Bring app into focus for the welcome screen specifically (the rest
        // of the time we are a menu-bar accessory).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    @MainActor
    func dismiss() {
        SettingsManager.shared.hasSeenOnboarding = true
        window?.close()
        window = nil
        // Restore menu-bar-only mode.
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct OnboardingView: View {
    let onClose: () -> Void
    @State private var step: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.35, green: 0.55, blue: 1.0),
                             Color(red: 0.55, green: 0.30, blue: 0.95)],
                    startPoint: .top, endPoint: .bottom
                )
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 6, y: 3)
            }
            .frame(height: 150)

            // Content
            VStack(alignment: .leading, spacing: 14) {
                switch step {
                case 0: WelcomeStep()
                case 1: PermissionStep()
                default: ShortcutsStep()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Footer
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Button(step == 2 ? "Done" : "Next") {
                    if step == 2 { onClose() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(width: 480, height: 420)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        Text("Welcome to ClipboardKit")
            .font(.title2.bold())
        Text("Your menu-bar clipboard history and screenshot toolbox.")
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 8) {
            BulletRow(icon: "doc.on.clipboard", title: "Clipboard history", subtitle: "Press ⌘⇧V any time to see what you've copied.")
            BulletRow(icon: "selection.pin.in.out", title: "Screenshots", subtitle: "Region, window, and scrolling captures land in your clipboard.")
            BulletRow(icon: "wand.and.stars", title: "Annotate", subtitle: "Click the floating thumbnail after a capture to mark it up.")
        }
        .padding(.top, 4)
    }
}

private struct PermissionStep: View {
    var body: some View {
        Text("Grant Screen Recording")
            .font(.title2.bold())
        Text("Required for capturing screenshots via ScreenCaptureKit. Without it, the region/window/long screenshot hotkeys will simply beep.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Open Screen Recording Settings…") {
                ScreenRecordingPermission.openScreenRecordingSettings()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(.top, 6)
        Text("After enabling, you may need to quit and relaunch ClipboardKit once.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct ShortcutsStep: View {
    var body: some View {
        Text("Default Shortcuts")
            .font(.title2.bold())
        Text("All of these can be changed in Settings → Shortcuts.")
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 10) {
            ShortcutRow(combo: "⌘⇧V", desc: "Toggle clipboard history popover")
            ShortcutRow(combo: "⌘⇧S", desc: "Capture a screen region (press Space for window mode)")
            ShortcutRow(combo: "⌘⇧L", desc: "Long (scrolling) screenshot")
        }
        .padding(.top, 4)
    }
}

private struct BulletRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ShortcutRow: View {
    let combo: String
    let desc: String
    var body: some View {
        HStack(spacing: 10) {
            Text(combo)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            Text(desc)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}
