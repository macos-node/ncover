import AppKit
import NCoverKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything the window is showing, and the one place the pipeline is run.
@MainActor
final class AppModel: ObservableObject {
    // Source
    @Published private(set) var source: Raster?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceName: String = "no image"
    @Published private(set) var isSVG = false

    // Recipe
    @Published var canvas: Int = CANVAS_DEFAULT { didSet { rescaleFraming(from: oldValue) } }
    @Published var framing: Framing = .cover { didSet { resetFraming() } }
    @Published var discOn = false { didSet { rerender() } }
    @Published var fillKind: FillKind = .alpha { didSet { rerender() } }
    @Published var solid: Color = .white { didSet { rerender() } }
    @Published var gradInner: Color = .black { didSet { rerender() } }
    @Published var gradOuter: Color = .white { didSet { rerender() } }

    // Placement
    @Published var placement = Placement(dx: 0, dy: 0, scale: 1)
    /// Where the placement stood when the current drag began. `nil` between drags.
    private var dragAnchor: Placement?
    @Published private(set) var snappedX = false
    @Published private(set) var snappedY = false

    // Output
    @Published private(set) var preview: NSImage?
    @Published var error: String?
    @Published private(set) var busy = false

    enum FillKind: String, CaseIterable, Identifiable {
        case alpha, white, solid, gradient
        var id: String { rawValue }
        var label: String {
            switch self {
            case .alpha: return "Transparent"
            case .white: return "White"
            case .solid: return "Colour"
            case .gradient: return "Gradient"
            }
        }
    }

    var recipe: Recipe {
        Recipe(canvas: canvas, framing: framing, disc: discOn ? outerFill : nil)
    }

    private var outerFill: OuterFill {
        switch fillKind {
        case .alpha:    return .alpha
        case .white:    return .white
        case .solid:    return .solid(solid.rgb)
        case .gradient: return .gradient(inner: gradInner.rgb, outer: gradOuter.rgb)
        }
    }

    var sourceDims: String {
        guard let s = source else { return "" }
        return "\(s.width)×\(s.height)"
    }

    // MARK: - opening

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Open cover artwork"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    func load(_ url: URL) async {
        busy = true
        defer { busy = false }
        do {
            let ext = url.pathExtension.lowercased()
            let svg = ext == "svg"
            // An SVG has no intrinsic pixel size worth trusting, so rasterise it
            // big enough to interrogate and to survive any canvas we offer.
            let raster = svg
                ? try await SVGRasterizer.rasterize(url, side: 1024)
                : try Raster.load(contentsOf: url)
            source = raster
            sourceURL = url
            sourceName = url.lastPathComponent
            isSVG = svg
            error = nil
            resetFraming()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - framing

    func resetFraming() {
        guard let s = source else { preview = nil; return }
        placement = framing == .cover
            ? Placement.cover(sw: s.width, sh: s.height, canvas: canvas)
            : Placement.fit(sw: s.width, sh: s.height, canvas: canvas)
        snappedX = false; snappedY = false
        dragAnchor = nil
        rerender()
        Task { await refreshSVGRaster() }
    }

    /// Changing the output size must not re-crop what you already framed.
    private func rescaleFraming(from old: Int) {
        guard source != nil, old != canvas, old > 0 else { rerender(); return }
        placement = placement.rescaled(from: old, to: canvas)
        rerender()
        Task { await refreshSVGRaster() }
    }

    /// Dragging anchors on the placement as it was when the gesture began, and
    /// every update recomputes from **that** anchor plus the gesture's total
    /// translation.
    ///
    /// Accumulating deltas onto the *snapped* placement instead looks equivalent
    /// and is not: inside a snap zone every frame would be pulled back to the
    /// target and the motion in between thrown away, so a slow drag could never
    /// escape the centre guide while a fast flick sailed through. Snap is for
    /// display; the anchor is the truth.
    func beginDrag() {
        if dragAnchor == nil { dragAnchor = placement }
    }

    func dragTo(_ translation: CGSize, viewScale: Double) {
        guard let s = source, let anchor = dragAnchor, viewScale > 0 else { return }
        let r = resolveDrag(anchor: anchor,
                            translationX: translation.width,
                            translationY: translation.height,
                            viewScale: viewScale,
                            sw: s.width, sh: s.height, canvas: canvas)
        placement = r.placement
        snappedX = r.snappedX
        snappedY = r.snappedY
        rerender()
    }

    /// The snapped placement stays; only the guides go. They answer "why did it
    /// stop moving", which is a question about a drag in progress.
    func endDrag() {
        dragAnchor = nil
        snappedX = false
        snappedY = false
    }

    func zoom(by factor: Double) {
        guard source != nil, factor > 0 else { return }
        // Zoom about the canvas centre, so the thing you framed stays framed.
        let c = Double(canvas) / 2
        var p = placement
        p.dx = c + (p.dx - c) * factor
        p.dy = c + (p.dy - c) * factor
        p.scale = max(0.01, p.scale * factor)
        placement = p
        dragAnchor = nil   // the anchor described a different scale
        rerender()
    }

    /// Called when a magnify gesture finishes — the scale has settled, so this
    /// is the moment an SVG is worth re-rendering.
    func endZoom() {
        Task { await refreshSVGRaster() }
    }

    // MARK: - SVG resolution

    /// Re-render the SVG at the size it is actually being drawn at.
    ///
    /// An SVG has no native resolution, so the only reason to resample one is
    /// that we rendered it at the wrong size to begin with. Ask for the size it
    /// occupies on the canvas and the downscale all but disappears — what is
    /// left is WebKit rendering at the backing scale, which area-averages down
    /// as clean supersampling rather than as loss.
    ///
    /// Cheap to do because **dragging never changes the scale** — only zoom and
    /// canvas size do. So this runs on those two events, and preview and output
    /// stay the same image rather than the file quietly being the better one.
    func refreshSVGRaster() async {
        guard isSVG, let url = sourceURL, let s = source else { return }
        let placed = placement.w(s.width)          // canvas pixels
        let target = Int(placed.rounded())
        guard target > 0 else { return }
        // Only bother when it is materially wrong; re-rendering for a 3%
        // difference would just make zooming stutter.
        let ratio = Double(s.width) / max(placed, 1)
        guard ratio > 1.15 || ratio < 0.87 else { return }

        busy = true
        defer { busy = false }
        guard let re = try? await SVGRasterizer.rasterize(url, side: target) else { return }
        source = re
        // The rasteriser returns the backing-scale multiple, so derive the new
        // scale from what actually came back rather than from what we asked for.
        placement = Placement(dx: placement.dx, dy: placement.dy,
                              scale: placed / Double(re.width))
        rerender()
    }

    // MARK: - render

    func rerender() {
        guard let s = source else { preview = nil; return }
        let out = renderFull(s)
        preview = out.nsImage()
    }

    private func renderFull(_ s: Raster) -> Raster {
        let framed = compose(s, placement, canvas: canvas)
        guard discOn else { return framed }
        return discTemplate(framed, fill: outerFill) ?? framed
    }

    // MARK: - saving

    func saveAs() {
        guard let s = source else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        // Output is always PNG — the disc / label mask needs an alpha channel.
        panel.nameFieldStringValue = (sourceURL?.deletingPathExtension().lastPathComponent ?? "cover") + ".png"
        panel.message = "Save as PNG"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try renderFull(s).writePNG(to: url); error = nil }
        catch { self.error = error.localizedDescription }
    }

    /// Replace the original PNG in place. Guarded: never anything but a PNG.
    func overwrite() {
        guard let s = source, let url = sourceURL else { return }
        do {
            try guardOverwrite(source: url)
            try renderFull(s).writePNG(to: url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    var canOverwrite: Bool {
        guard let url = sourceURL else { return false }
        return url.pathExtension.lowercased() == "png"
    }
}

extension Raster {
    func nsImage() -> NSImage? {
        guard let cg = try? cgImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}

extension Color {
    var rgb: RGB {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return RGB(UInt8((ns.redComponent * 255).rounded()),
                   UInt8((ns.greenComponent * 255).rounded()),
                   UInt8((ns.blueComponent * 255).rounded()))
    }
}
