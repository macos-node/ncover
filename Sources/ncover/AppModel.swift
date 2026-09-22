import AppKit
import NCoverKit
import SwiftUI
import UniformTypeIdentifiers

/// The window's state. The document is the source of truth — everything the UI
/// shows is read out of its operation list, and every edit goes through
/// `mutate`, which is what makes undo a stack of documents rather than a set of
/// hand-written inverse operations.
///
/// The UI currently edits a fixed shape of that list (one placement, one
/// optional mask). The *model* does not care: arbitrary stacking is a UI job
/// that can be done later without touching the backends.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var doc: Composition?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceName = "no image"
    @Published private(set) var preview: NSImage?
    @Published private(set) var busy = false
    @Published var error: String?

    /// Framing is an intent, not an operation — it says how to *compute* a
    /// placement, and the placement is what gets recorded.
    @Published var framing: Framing = .cover { didSet { resetFraming() } }

    // Colours are remembered even while the fill is transparent, so switching
    // back does not lose what you picked.
    @Published var solid: Color = .white       { didSet { rebuild() } }
    @Published var gradInner: Color = .black   { didSet { rebuild() } }
    @Published var gradOuter: Color = .white   { didSet { rebuild() } }
    @Published var fillKind: FillKind = .alpha { didSet { rebuild() } }
    @Published var discOn = false              { didSet { rebuild() } }
    @Published var maskShape: MaskKind = .disc { didSet { rebuild() } }
    /// Corner radius / chamfer inset, as a fraction of half the canvas. One
    /// control for both because they mean the same thing: how much corner goes.
    @Published var maskAmount: Double = 0.35   { didSet { rebuild() } }
    /// Whether the mask is inscribed in the canvas or in the artwork's own
    /// bounds. Canvas is the inherited behaviour and the surprising one.
    @Published var maskFit: MaskFit = .canvas  { didSet { rebuild() } }

    enum MaskKind: String, CaseIterable, Identifiable {
        case disc, rounded, chamfer
        var id: String { rawValue }
        var label: String {
            switch self {
            case .disc:    return "Disc"
            case .rounded: return "Rounded"
            case .chamfer: return "Chamfer"
            }
        }
    }

    var mask: Mask {
        switch maskShape {
        case .disc:    return .disc
        case .rounded: return .roundedRect(radius: maskAmount)
        case .chamfer: return .chamfer(inset: maskAmount)
        }
    }

    /// The disc has nothing to adjust — it is the whole half-canvas by
    /// definition — so the slider only appears where it means something.
    var maskHasAmount: Bool { maskShape != .disc }

    /// Preview backdrop. Never reaches the renderers — see `Backdrop`.
    @Published var backdrop: Backdrop = Backdrop.load() { didSet { backdrop.save() } }
    /// Armed by the eyedropper button; the next canvas click samples instead of drags.
    @Published var samplingBackdrop = false
    /// The last rendered canvas, kept so a click can be answered with the exact
    /// pixel that is on screen rather than a re-derived guess.
    private(set) var lastRender: Raster?

    private var undoStack: [Composition] = []
    private var redoStack: [Composition] = []
    private var dragAnchor: Placement?

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

    // MARK: - derived

    var canvas: Int {
        get { doc?.canvas ?? CANVAS_DEFAULT }
        set {
            guard let d = doc, newValue != d.canvas else { return }
            mutate { doc in
                let old = doc.canvas
                doc.canvas = newValue
                // Changing the output size must not re-crop what you framed.
                if let p = doc.placement { doc.setPlacement(p.rescaled(from: old, to: newValue)) }
            }
            Task { await refreshSVGRaster() }
        }
    }

    var sourceDims: String {
        guard let d = doc else { return "" }
        return "\(d.source.raster.width)×\(d.source.raster.height)"
    }
    var isVector: Bool { doc?.source.isVector ?? false }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canOverwrite: Bool { sourceURL?.pathExtension.lowercased() == "png" }

    /// Why SVG export is unavailable, in words meant for a person.
    var vectorRefusal: String? { doc?.vectorRefusal ?? "nothing is open" }
    var canSaveVector: Bool { doc?.vectorRefusal == nil }

    var saveHelp: String {
        canSaveVector
            ? "Save as PNG, or as SVG to keep it vector at any size."
            : "Save as PNG. SVG is unavailable because " + (vectorRefusal ?? "") + "."
    }

    /// One row of the operation list, for showing. This is the app's actual
    /// shape, surfaced rather than implied.
    struct Step: Identifiable {
        let id: Int
        let label: String
        let hasVectorForm: Bool
    }

    var steps: [Step] {
        let ops = doc?.ops ?? []
        return ops.enumerated().map {
            Step(id: $0.offset, label: $0.element.label, hasVectorForm: $0.element.hasVectorForm)
        }
    }

    private var outerFill: OuterFill {
        switch fillKind {
        case .alpha:    return .alpha
        case .white:    return .white
        case .solid:    return .solid(solid.rgb)
        case .gradient: return .gradient(inner: gradInner.rgb, outer: gradOuter.rgb)
        }
    }

    // MARK: - editing

    /// Every change to the document goes through here, so undo needs no
    /// per-operation inverse — it is just the previous value.
    private func mutate(record: Bool = true, _ change: (inout Composition) -> Void) {
        guard var d = doc else { return }
        if record { undoStack.append(d); redoStack.removeAll() }
        change(&d)
        doc = d
        rerender()
    }

    func undo() {
        guard let current = doc, let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        doc = previous
        syncControlsFromDocument()
        rerender()
    }

    func redo() {
        guard let current = doc, let next = redoStack.popLast() else { return }
        undoStack.append(current)
        doc = next
        syncControlsFromDocument()
        rerender()
    }

    /// After undo the controls must follow the document, not the other way
    /// round — otherwise the next edit would write the stale control back.
    private func syncControlsFromDocument() {
        guard let d = doc else { return }
        var found: OuterFill?
        var foundShape: Mask?
        var foundFit: MaskFit?
        for case .mask(let m, let fill, let fit) in d.ops {
            found = fill; foundShape = m; foundFit = fit
        }
        withControlsSilenced {
            discOn = found != nil
            if let f = foundFit { maskFit = f }
            switch foundShape {
            case .disc?:                   maskShape = .disc
            case .roundedRect(let r)?:     maskShape = .rounded; maskAmount = r
            case .chamfer(let i)?:         maskShape = .chamfer; maskAmount = i
            case nil:                      break
            }
            switch found {
            case .alpha?:            fillKind = .alpha
            case .white?:            fillKind = .white
            case .solid(let c)?:     fillKind = .solid;    solid = Color(c)
            case .gradient(let i, let o)?:
                fillKind = .gradient; gradInner = Color(i); gradOuter = Color(o)
            case nil:                break
            }
        }
    }

    private var silenced = false
    private func withControlsSilenced(_ body: () -> Void) {
        silenced = true; body(); silenced = false
    }

    /// Write the controls into the operation list.
    private func rebuild() {
        guard !silenced, doc != nil else { return }
        let fill = outerFill
        let on = discOn
        let shape = mask
        let fit = maskFit
        mutate { doc in
            doc.ops.removeAll { if case .mask = $0 { return true }; return false }
            if on { doc.ops.append(.mask(shape, fill: fill, fit: fit)) }
        }
    }

    // MARK: - opening

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg, .webP]
        panel.message = "Open artwork"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    func load(_ url: URL) async {
        busy = true
        defer { busy = false }
        do {
            let isSVG = url.pathExtension.lowercased() == "svg"
            let raster: Raster
            var vector: VectorSource?
            if isSVG {
                raster = try await SVGRasterizer.rasterize(url, side: 1024)
                let text = try String(contentsOf: url, encoding: .utf8)
                vector = VectorSource(svg: text,
                                      width: Double(raster.width), height: Double(raster.height))
            } else {
                raster = try Raster.load(contentsOf: url)
            }
            let keepCanvas = doc?.canvas ?? CANVAS_DEFAULT
            doc = Composition(source: Source(raster: raster, vector: vector), canvas: keepCanvas)
            sourceURL = url
            sourceName = url.lastPathComponent
            undoStack.removeAll(); redoStack.removeAll()
            error = nil
            resetFraming()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - framing and gestures

    func resetFraming() {
        guard let d = doc else { preview = nil; return }
        let s = d.source.raster
        let p = framing == .cover
            ? Placement.cover(sw: s.width, sh: s.height, canvas: d.canvas)
            : Placement.fit(sw: s.width, sh: s.height, canvas: d.canvas)
        snappedX = false; snappedY = false; dragAnchor = nil
        mutate { $0.setPlacement(p) }
        Task { await refreshSVGRaster() }
    }

    @Published private(set) var snappedX = false
    @Published private(set) var snappedY = false

    func beginDrag() { if dragAnchor == nil { dragAnchor = doc?.placement } }

    func dragTo(_ translation: CGSize, viewScale: Double) {
        guard let d = doc, let anchor = dragAnchor else { return }
        let r = resolveDrag(anchor: anchor,
                            translationX: translation.width, translationY: translation.height,
                            viewScale: viewScale,
                            sw: d.source.raster.width, sh: d.source.raster.height,
                            canvas: d.canvas)
        snappedX = r.snappedX; snappedY = r.snappedY
        // One undo entry per drag, not per frame: record on the first move only.
        mutate(record: undoStack.last?.placement != anchor) { $0.setPlacement(r.placement) }
    }

    func endDrag() { dragAnchor = nil; snappedX = false; snappedY = false }

    func zoom(by factor: Double) {
        guard let d = doc, var p = d.placement, factor > 0 else { return }
        let c = Double(d.canvas) / 2
        p.dx = c + (p.dx - c) * factor
        p.dy = c + (p.dy - c) * factor
        p.scale = max(0.01, p.scale * factor)
        dragAnchor = nil
        mutate(record: false) { $0.setPlacement(p) }
    }

    func endZoom() { Task { await refreshSVGRaster() } }

    // MARK: - SVG resolution

    /// Re-render the SVG at the size it is actually drawn at. Cheap because
    /// dragging cannot change the scale — only zoom, framing and canvas size can.
    func refreshSVGRaster() async {
        guard let d = doc, d.source.isVector, let url = sourceURL, let p = d.placement else { return }
        let placed = p.w(d.source.raster.width)
        let target = Int(placed.rounded())
        guard target > 0 else { return }
        let ratio = Double(d.source.raster.width) / max(placed, 1)
        guard ratio > 1.15 || ratio < 0.87 else { return }

        busy = true
        defer { busy = false }
        guard let re = try? await SVGRasterizer.rasterize(url, side: target) else { return }
        mutate(record: false) { doc in
            doc.source.raster = re
            doc.setPlacement(Placement(dx: p.dx, dy: p.dy, scale: placed / Double(re.width)))
        }
    }

    // MARK: - render

    func rerender() {
        guard let d = doc else { preview = nil; lastRender = nil; return }
        let r = renderRaster(d)
        lastRender = r
        preview = r.nsImage()
    }

    // MARK: - backdrop picking

    /// Sample the pixel actually on screen at this canvas coordinate.
    /// A fully transparent pixel is refused — the backdrop is what you would be
    /// seeing *through* it, so sampling one would just pick the backdrop again.
    func sampleBackdrop(canvasX x: Double, canvasY y: Double) {
        defer { samplingBackdrop = false }
        guard let r = lastRender else { return }
        let px = r.sample(Int(x.rounded(.down)), Int(y.rounded(.down)))
        guard px.a > 0 else {
            error = "That pixel is transparent — there is no colour there to match."
            return
        }
        backdrop = .custom(Color(RGB(px.r, px.g, px.b)))
    }

    /// The system eyedropper: pick from anywhere on screen, not just this window.
    /// Free on macOS, and the one thing the GTK app needs a separate X11 binary for.
    func pickBackdropFromScreen() {
        NSColorSampler().show { picked in
            guard let ns = picked?.usingColorSpace(.sRGB) else { return }
            Task { @MainActor in
                self.backdrop = .custom(Color(RGB(UInt8((ns.redComponent * 255).rounded()),
                                                  UInt8((ns.greenComponent * 255).rounded()),
                                                  UInt8((ns.blueComponent * 255).rounded()))))
            }
        }
    }

    // MARK: - saving

    func saveAs() {
        guard let d = doc else { return }
        let panel = NSSavePanel()
        // SVG is offered only when the document can actually produce it.
        panel.allowedContentTypes = canSaveVector ? [.png, .svg] : [.png]
        panel.nameFieldStringValue =
            (sourceURL?.deletingPathExtension().lastPathComponent ?? "artwork") + ".png"
        panel.message = canSaveVector
            ? "PNG rasterises. SVG keeps the artwork as vector at any size."
            : "Saving as PNG — SVG unavailable because \(vectorRefusal ?? "")."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "svg" {
                guard let svg = renderVector(d) else {
                    throw NSError(domain: "ncover", code: 1, userInfo: [
                        NSLocalizedDescriptionKey:
                            "Cannot write SVG: \(vectorRefusal ?? "unknown reason")."])
                }
                try svg.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try renderRaster(d).writePNG(to: url)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Replace the original PNG in place. Guarded: never anything but a PNG.
    func overwrite() {
        guard let d = doc, let url = sourceURL else { return }
        do {
            try guardOverwrite(source: url)
            try renderRaster(d).writePNG(to: url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
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
    init(_ c: RGB) {
        self.init(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255,
                  blue: Double(c.b) / 255, opacity: 1)
    }
}
