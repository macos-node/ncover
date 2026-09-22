import AppKit
import SwiftUI

// Tooltips, presented by us.
//
// Two earlier attempts failed for different reasons, both worth recording so
// nobody walks back into them:
//
//  1. SwiftUI's `.help()` never sets `NSView.toolTip` for ordinary controls —
//     verified in a minimal app containing nothing else. Only toolbar items
//     work, because they bridge to real `NSToolbarItemViewer`s.
//  2. Setting `NSView.toolTip` on an overlay did attach it — the views were
//     present, correctly sized and not hidden — and still nothing appeared.
//     AppKit's `NSToolTipManager` has to hit-test its way to the view, and the
//     overlay returned nil from `hitTest` so that clicks could reach the
//     control beneath. The thing that made it harmless made it invisible.
//
// So this owns the whole mechanism: `.onHover` for the trigger, a delay so it
// does not flash while the pointer is passing through, and a borderless panel
// for the presentation. A panel rather than a SwiftUI overlay because a
// tooltip inside a `Form` would be clipped by it.
//
// The only thing this still depends on is `.onHover` firing, which needs the
// window to accept mouse-moved events — see `AppDelegate`.

@MainActor
final class TipPresenter {
    static let shared = TipPresenter()

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?

    /// Long enough not to fire while the pointer crosses a control on its way
    /// somewhere else; short enough that asking "what is this" feels answered.
    private let delay: TimeInterval = 0.5

    func schedule(_ text: String) {
        cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(text) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .toolTipsFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .controlTextColor
        label.drawsBackground = false
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 260
        label.sizeToFit()

        let pad: CGFloat = 6
        let size = NSSize(width: label.frame.width + pad * 2, height: label.frame.height + pad * 2)
        label.setFrameOrigin(NSPoint(x: pad, y: pad))

        let backing = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backing.material = .toolTip
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 5
        backing.layer?.borderWidth = 0.5
        backing.layer?.borderColor = NSColor.separatorColor.cgColor
        backing.addSubview(label)

        // Below and right of the pointer, the way a system tooltip sits, and
        // nudged back on-screen if that would put it off the edge.
        var origin = NSEvent.mouseLocation
        origin.x += 12
        origin.y -= size.height + 12
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let f = screen.visibleFrame
            origin.x = min(origin.x, f.maxX - size.width - 4)
            origin.y = max(origin.y, f.minY + 4)
        }

        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = backing
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true          // never steals the pointer
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.orderFrontRegardless()
        panel = p
    }
}

extension View {
    /// A tooltip that we present ourselves. Use instead of `.help()` anywhere
    /// outside the toolbar, where `.help()` does work.
    func tip(_ text: String) -> some View {
        onHover { inside in
            if hoverTracingEnabled() { traceHover(inside, text) }
            if inside { TipPresenter.shared.schedule(text) }
            else { TipPresenter.shared.cancel() }
        }
    }
}

/// Diagnostic: does hover reach us at all? Prints each enter/exit.
///
///     NCOVER_TRACE_HOVER=1 n.cover.app/Contents/MacOS/ncover
///
/// If nothing prints while the pointer crosses controls, the fault is mouse
/// tracking rather than the tooltip — see `AppDelegate`.
func hoverTracingEnabled() -> Bool {
    ProcessInfo.processInfo.environment["NCOVER_TRACE_HOVER"] != nil
}

/// Written to stderr, which is unbuffered. `print` is line-buffered on a
/// terminal but **fully** buffered when redirected to a file, so a trace that
/// used it came back empty from a redirect while the feature was working
/// perfectly — a diagnostic that lies is worse than none.
func traceHover(_ inside: Bool, _ text: String) {
    FileHandle.standardError.write(
        "hover \(inside ? "in " : "out") — \(text.prefix(48))\n".data(using: .utf8)!)
}
