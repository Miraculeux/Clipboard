import AppKit
import ApplicationServices

/// Accessibility-API hit-test that returns the deepest UI element at a given
/// screen point — i.e. a sub-window component like a sidebar, toolbar, text
/// field, or button.
///
/// Requires the host process to be trusted in System Settings → Privacy &
/// Security → Accessibility, AND requires our overlay window to be hidden
/// from the AX tree (otherwise the system-wide hit test resolves to our
/// transparent shield first).
enum AXHitTester {
    struct Hit {
        let cgRect: CGRect
        let role: String?
    }

    /// Ordered chain of AX hits walking up from the deepest element under
    /// the cursor to its containing window. `hits[0]` is the leaf,
    /// `hits.last` is the window-level element. Used by the screenshot
    /// overlay to let the user scroll between granularities (row → list →
    /// sidebar → whole pane) when the deepest leaf is too small.
    struct Chain {
        let hits: [Hit]
    }

    /// `true` if the process has Accessibility permission. Prompts the user
    /// on the first call so the screenshot overlay can offer to enable it
    /// without forcing them to dig through System Settings.
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let opts: [CFString: Bool] = [promptKey: prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Resolve the smallest meaningful AX element at `cgPoint`.
    ///
    /// Strategy:
    ///  1. System-wide hit test gives us the first element AX considers
    ///     "at" the point. Apps with a deep AX tree (native AppKit, SwiftUI)
    ///     usually return the leaf directly.
    ///  2. If the returned element is suspiciously coarse (a window or a
    ///     huge container that's >80% the window's size), walk its
    ///     `AXChildren` looking for the smallest child that still contains
    ///     the cursor. This catches apps that hand back a top-level group
    ///     (common with Electron / web content) instead of a sub-element.
    ///  3. If we can't get a `position + size` for the result, return nil
    ///     so the caller falls back to whole-window highlighting.
    static func hit(at cgPoint: CGPoint, ownerPID: pid_t? = nil) -> Hit? {
        // If we know which process owns the window under the cursor,
        // ask THAT process's AX tree directly. The system-wide query can
        // pick the wrong process when overlapping AX hierarchies exist
        // (most painfully: the menu bar, where the foreground app owns
        // the menu titles but ControlCenter owns Wi-Fi/Bluetooth/clock).
        let root: AXUIElement = {
            if let ownerPID, ownerPID > 0 {
                return AXUIElementCreateApplication(ownerPID)
            }
            return AXUIElementCreateSystemWide()
        }()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            root, Float(cgPoint.x), Float(cgPoint.y), &element
        )
        guard err == .success, var element else { return nil }

        // Find the containing window once so we can detect the "too coarse"
        // case (element ≈ whole window) and clip the final result.
        let window = windowAncestor(of: element)
        let windowFrame = window.flatMap { frame(of: $0) }

        // Drill deeper as long as a child still contains the cursor and is
        // strictly smaller than the current element. This handles two cases
        // the previous "only if coarse relative to a window" check missed:
        //   1. The system menu bar (no AXWindow ancestor; AX usually hands
        //      back the whole AXMenuBar at the top) — we drill into the
        //      individual AXMenuExtra / AXMenuBarItem under the cursor.
        //   2. Apps whose AX hit lands on a top-level container even when
        //      it doesn't quite cross the 85% coarseness threshold.
        // Cap iterations so we can't loop on a degenerate tree.
        for _ in 0..<10 {
            let parentRect = frame(of: element) ?? .zero
            let parentArea = parentRect.width * parentRect.height
            guard let smaller = smallestChild(of: element, containing: cgPoint, biggerThan: nil) else {
                break
            }
            let childRect = frame(of: smaller) ?? .zero
            let childArea = childRect.width * childRect.height
            // Only descend if the child is meaningfully smaller — otherwise
            // we'd loop on pass-through containers that share their parent's
            // frame (common in Electron / SwiftUI).
            if childArea >= parentArea * 0.99 { break }
            element = smaller
        }

        guard let rect = frame(of: element), !rect.isEmpty else { return nil }
        let role = roleString(of: element)
        // Clip oversize results (popovers spilling off-window etc.) to the
        // owning window if we have one.
        let final = (windowFrame.map { rect.intersection($0) } ?? rect)
        if final.isEmpty { return nil }
        return Hit(cgRect: final, role: role)
    }

    /// Build the ancestor chain from the leaf at `cgPoint` upward to its
    /// containing window. Consecutive ancestors with effectively-identical
    /// frames are collapsed so scroll-wheel granularity steps feel useful
    /// (otherwise Electron's nested AXGroups produce many no-op steps).
    static func chain(at cgPoint: CGPoint, ownerPID: pid_t? = nil) -> Chain? {
        guard let leaf = hit(at: cgPoint, ownerPID: ownerPID) else { return nil }

        let root: AXUIElement = {
            if let ownerPID, ownerPID > 0 {
                return AXUIElementCreateApplication(ownerPID)
            }
            return AXUIElementCreateSystemWide()
        }()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            root, Float(cgPoint.x), Float(cgPoint.y), &element
        ) == .success, var current = element else {
            return Chain(hits: [leaf])
        }
        // Re-run the same downward drill so we start from the same leaf
        // `hit(at:)` returns.
        let window = windowAncestor(of: current)
        let windowFrame = window.flatMap { frame(of: $0) }
        for _ in 0..<10 {
            let parentRect = frame(of: current) ?? .zero
            let parentArea = parentRect.width * parentRect.height
            guard let smaller = smallestChild(of: current, containing: cgPoint, biggerThan: nil) else {
                break
            }
            let childRect = frame(of: smaller) ?? .zero
            let childArea = childRect.width * childRect.height
            if childArea >= parentArea * 0.99 { break }
            current = smaller
        }

        var hits: [Hit] = []
        if let leafRect = frame(of: current), !leafRect.isEmpty {
            let clipped = windowFrame.map { leafRect.intersection($0) } ?? leafRect
            if !clipped.isEmpty {
                hits.append(Hit(cgRect: clipped, role: roleString(of: current)))
            }
        }

        for _ in 0..<32 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent else { break }
            let parentElement = next as! AXUIElement  // swiftlint:disable:this force_cast
            guard let rect = frame(of: parentElement), !rect.isEmpty else {
                current = parentElement
                continue
            }
            // Stop once we've reached the window (or anything wrapping it).
            let role = roleString(of: parentElement)
            let clipped = windowFrame.map { rect.intersection($0) } ?? rect
            if !clipped.isEmpty {
                // Skip if essentially identical in size to the previous hit —
                // those are pass-through containers (very common in Electron).
                let isDuplicate = hits.last.map { abs($0.cgRect.width - clipped.width) < 1 &&
                                                  abs($0.cgRect.height - clipped.height) < 1 &&
                                                  abs($0.cgRect.minX - clipped.minX) < 1 &&
                                                  abs($0.cgRect.minY - clipped.minY) < 1 } ?? false
                if !isDuplicate {
                    hits.append(Hit(cgRect: clipped, role: role))
                }
            }
            current = parentElement
            if role == kAXWindowRole as String { break }
        }

        return hits.isEmpty ? Chain(hits: [leaf]) : Chain(hits: hits)
    }

    // MARK: - Tree walking

    private static func isCoarseRelativeTo(_ rect: CGRect, window: CGRect?) -> Bool {
        guard let window, !window.isEmpty, !rect.isEmpty else { return false }
        let coverage = (rect.width * rect.height) / (window.width * window.height)
        return coverage >= 0.85
    }

    /// Find the smallest direct child of `element` whose frame still
    /// contains `point`. Returns `nil` when there is no better child.
    private static func smallestChild(of element: AXUIElement,
                                      containing point: CGPoint,
                                      biggerThan minArea: CGFloat?) -> AXUIElement? {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement], !children.isEmpty else { return nil }

        var best: (AXUIElement, CGRect)?
        for child in children {
            guard let rect = frame(of: child), rect.contains(point), !rect.isEmpty else { continue }
            if let current = best {
                if rect.width * rect.height < current.1.width * current.1.height {
                    best = (child, rect)
                }
            } else {
                best = (child, rect)
            }
        }
        // Refuse to step "sideways" into something at least as large as the
        // parent (avoids infinite loops on AX trees that point children back
        // at the same frame).
        if let (childElement, childRect) = best,
           (minArea ?? .greatestFiniteMagnitude) > childRect.width * childRect.height {
            return childElement
        }
        return best?.0
    }

    /// Walk up the AX hierarchy until we hit a `kAXWindowRole` element.
    private static func windowAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<32 {
            guard let cur = current else { return nil }
            if roleString(of: cur) == kAXWindowRole as String { return cur }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent else { return nil }
            current = (next as! AXUIElement)  // swiftlint:disable:this force_cast
        }
        return nil
    }

    // MARK: - Menu bar

    /// Locate the menu-bar item (regular `AXMenuBarItem` or `AXMenuExtra`
    /// status icon) sitting under `cgPoint`. The macOS menu bar's drawing
    /// is split across multiple processes (the foreground app owns the
    /// menu titles, ControlCenter owns most status items, individual apps
    /// can own their own status icons), and `AXUIElementCopyElementAtPosition`
    /// is unreliable across that boundary at shielding window level. This
    /// directly enumerates every running app's two menu bars and returns
    /// the smallest containing item.
    static func menuBarItem(at cgPoint: CGPoint) -> Hit? {
        var best: Hit?
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            if pid <= 0 { continue }
            let appEl = AXUIElementCreateApplication(pid)

            for attribute in [kAXMenuBarAttribute, kAXExtrasMenuBarAttribute] {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appEl, attribute as CFString, &value) == .success,
                      let raw = value else { continue }
                let menuBar = raw as! AXUIElement  // swiftlint:disable:this force_cast
                if let hit = smallestMenuItem(in: menuBar, containing: cgPoint) {
                    if let prev = best {
                        let prevArea = prev.cgRect.width * prev.cgRect.height
                        let newArea = hit.cgRect.width * hit.cgRect.height
                        if newArea < prevArea { best = hit }
                    } else {
                        best = hit
                    }
                }
            }
        }
        return best
    }

    private static func smallestMenuItem(in menuBar: AXUIElement,
                                          containing point: CGPoint) -> Hit? {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }

        var best: (rect: CGRect, role: String?)?
        for child in children {
            guard let rect = frame(of: child), !rect.isEmpty, rect.contains(point) else { continue }
            let role = roleString(of: child)
            let area = rect.width * rect.height
            if let prev = best {
                if area < prev.rect.width * prev.rect.height {
                    best = (rect, role)
                }
            } else {
                best = (rect, role)
            }
        }
        guard let best else { return nil }
        return Hit(cgRect: best.rect, role: best.role)
    }

    // MARK: - AX value extraction

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let sizeErr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard posErr == .success, sizeErr == .success,
              let posValue, let sizeValue else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let pos = posValue as! AXValue   // swiftlint:disable:this force_cast
        let sz = sizeValue as! AXValue   // swiftlint:disable:this force_cast
        guard AXValueGetType(pos) == .cgPoint,
              AXValueGetType(sz) == .cgSize,
              AXValueGetValue(pos, .cgPoint, &origin),
              AXValueGetValue(sz, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func roleString(of element: AXUIElement) -> String? {
        var role: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard err == .success else { return nil }
        return role as? String
    }
}
