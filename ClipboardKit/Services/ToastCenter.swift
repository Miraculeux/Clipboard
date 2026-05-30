import AppKit
import SwiftUI

/// Floating, auto-dismissing confirmation chip — shown near the menu-bar
/// status item after a paste so the user gets visual proof the action
/// fired. Lives in a borderless transparent window so it doesn't steal
/// focus and clears itself after ~1s.
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    private var window: NSWindow?
    private var dismissWork: DispatchWorkItem?

    private init() {}

    func show(_ text: String) {
        dismissWork?.cancel()

        let hosting = NSHostingController(rootView: ToastView(text: text))
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize

        // Anchor under the menu bar, roughly centered horizontally.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height - 12
        )

        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.ignoresMouseEvents = true
            window = w
        }

        window?.contentViewController = hosting
        window?.setContentSize(size)
        window?.setFrameOrigin(origin)
        window?.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(2)
    }
}
