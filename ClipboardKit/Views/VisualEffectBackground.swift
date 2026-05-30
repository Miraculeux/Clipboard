import AppKit
import SwiftUI

/// Lightweight `NSVisualEffectView` bridge. SwiftUI's `.regularMaterial` etc.
/// look fine on most surfaces but don't render the same blurred backdrop as
/// AppKit's `headerView` / `titlebar` materials inside an `NSPopover`. The
/// system clipboard popovers we model against (Spotlight, the menu bar
/// extras) use real `NSVisualEffectView`, so do the same.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .followsWindowActiveState
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
