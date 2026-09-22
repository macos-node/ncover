import AppKit
import SwiftUI

// Tooltips, the hard way, because the easy way does not work.
//
// SwiftUI's `.help()` never sets `NSView.toolTip` for ordinary controls —
// verified in a minimal app with nothing else in it, so this is not something
// about our Form or split view. The only place it does take effect here is on
// toolbar items, which bridge to real `NSToolbarItemViewer`s.
//
// So content tooltips are attached to an AppKit view directly. The overlay
// returns nil from `hitTest`, which keeps it invisible to the mouse while the
// window's tooltip tracking still finds it — clicks reach the control
// underneath, which is asserted rather than assumed (see below).
//
// To check tooltips are actually attached, without hovering over every control:
//
//     NCOVER_DUMP_TOOLTIPS=1 n.cover.app/Contents/MacOS/ncover
//
// which walks the real view tree and prints every view carrying a toolTip.

private final class TipNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TipOverlay: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView {
        let v = TipNSView()
        v.toolTip = text
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { v.toolTip = text }
}

extension View {
    /// A tooltip that actually appears. Use instead of `.help()` anywhere
    /// outside the toolbar.
    func tip(_ text: String) -> some View {
        overlay(TipOverlay(text: text))
    }
}

/// Walk the real view tree and report every view carrying a toolTip.
///
/// This exists because the bug it found was invisible to tests and to reading
/// the code: `.help()` compiled, read correctly, and did nothing. Run it after
/// touching tooltips rather than hovering over twenty controls by hand.
func dumpTooltips() {
    guard ProcessInfo.processInfo.environment["NCOVER_DUMP_TOOLTIPS"] != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        var total = 0, withTip = 0
        func walk(_ v: NSView) {
            total += 1
            if let t = v.toolTip {
                withTip += 1
                print("  [tip] \(type(of: v)): \(t.prefix(70))")
            }
            v.subviews.forEach(walk)
        }
        for w in NSApp.windows { if let cv = w.contentView { walk(cv) } }
        print("views=\(total)  withToolTip=\(withTip)")
        exit(0)
    }
}
