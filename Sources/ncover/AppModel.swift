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
    /// What an SVG source declares — colours, fonts, the text in it. `nil` for
    /// a raster source, which declares nothing.
    @Published private(set) var svgInfo: SVGInfo?
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
    /// Invert RGB, leaving alpha alone.
    @Published var invertOn = false            { didSet { rebuild() } }
    /// A stamped, centred square — the label mark.
    @Published var squareOn = false            { didSet { rebuild() } }
    @Published var squareFrac: Double = 0.6    { didSet { rebuild() } }
    @Published var squareColour: Color = .black { didSet { rebuild() } }
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
    /// The last rendered canvas, kept so a click can be answered with the exact
    /// pixel that is on screen rather than a re-derived guess.
    private(set) var lastRender: Raster?

    /// What the next canvas click does. Armed by one of the two eyedroppers,
    /// and disarmed by the click — an eyedropper that stayed armed would make
    /// the next drag pick a colour instead of moving the artwork.
    ///
    /// One enum rather than two booleans, because the two states are mutually
    /// exclusive and two flags could both be true.
    enum CanvasPick: Equatable {
        case off
        /// Sample into the preview backdrop.
        case backdrop
        /// Sample into the colour history — the in-app eyedropper.
        case colour
    }
    @Published var canvasPick: CanvasPick = .off

    /// The colour under the pointer, while an eyedropper is armed.
    ///
    /// The GTK app draws a crosshair and a magnifier for this. A readout is the
    /// same information with less machinery, and it answers the question the
    /// magnifier is really for: *which* colour am I about to get. Only
    /// published while armed, so hover does no work in the normal case.
    @Published private(set) var hovered: RGB?

    /// Whether a click should sample rather than drag.
    var picking: Bool { canvasPick != .off }

    // MARK: - the colour half
    //
    // The store is the user's data and lives on disk; `current` is this
    // session's working colour. Everything that mutates the store goes through
    // `touch`, which saves — see AppModel+Colour.swift.

    @Published var data: ColorData = loadColorData()
    /// The colour the picker is showing. Not persisted: what is remembered is
    /// the history, and a "current colour" restored from last week is noise.
    @Published var current: RGB?
    /// Which palette the Palettes view has open.
    @Published var selectedPalette: String?
    /// Transient confirmation — "copied", "installed in ~/Library/Colors".
    /// Not an error, so it does not belong in the alert.
    @Published var note: String?
    /// Which palette names are currently attached to the shared Colours panel,
    /// so a renamed or deleted one can be detached rather than lingering.
    var attachedLists: Set<String> = []

    /// A grid over the canvas, for judging a placement against thirds and
    /// centre. Preview only, like the backdrop.
    @Published var showGrid = false
    /// The source-beside-result strip under the canvas.
    @Published var showRail = false
    /// Whether the batch sheet is up.
    @Published var showBatch = false

    // MARK: - the folder the source came from
    //
    // Opening one image of a hundred and then having to go back through the
    // dialog for the next is the kind of friction that stops you looking at
    // the other ninety-nine. Every image beside the one you opened, in name
    // order, is one arrow key away.

    // Written only by AppModel+Browse.swift, which Swift has no way to say.
    @Published var folder: [URL] = []
    @Published var folderIndex = 0
    /// The source as it came in, for the Source / Result rail.
    @Published private(set) var sourceThumb: NSImage?

    var folderCount: Int { folder.count }

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
            touch { $0.canvas = newValue }
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
        var foundSquare: (Double, RGB)?
        for case .square(let frac, let colour) in d.ops { foundSquare = (frac, colour) }
        let foundInvert = d.ops.contains { if case .invert = $0 { return true }; return false }
        withControlsSilenced {
            invertOn = foundInvert
            squareOn = foundSquare != nil
            if let (frac, colour) = foundSquare {
                squareFrac = frac; squareColour = Color(colour)
            }
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
    func withControlsSilenced(_ body: () -> Void) {
        silenced = true; body(); silenced = false
    }

    /// Write the controls into the operation list.
    ///
    /// The placement is kept and everything after it is rewritten, which is
    /// what makes the order of the build steps a property of this one function
    /// rather than of the sequence the user happened to click them in.
    ///
    /// Invert, then the square, then the mask: inverting the artwork should not
    /// invert a mark you stamped on it afterwards, and the mask is a clip on
    /// the finished picture rather than on part of it.
    private func rebuild() {
        guard !silenced, doc != nil else { return }
        let built = buildOps()
        mutate { doc in
            let place = doc.ops.first { if case .place = $0 { return true }; return false }
            doc.ops = (place.map { [$0] } ?? []) + built
        }
    }

    private func buildOps() -> [NCoverKit.Operation] {
        var out: [NCoverKit.Operation] = []
        if invertOn { out.append(.invert) }
        if squareOn { out.append(.square(frac: squareFrac, colour: squareColour.rgb)) }
        if discOn { out.append(.mask(mask, fill: outerFill, fit: maskFit)) }
        return out
    }

    // MARK: - opening

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg, .webP]
        panel.message = "Open artwork"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    func load(_ url: URL, rescan: Bool = true) async {
        busy = true
        defer { busy = false }
        do {
            let isSVG = url.pathExtension.lowercased() == "svg"
            let raster: Raster
            var vector: VectorSource?
            var info: SVGInfo?
            if isSVG {
                raster = try await SVGRasterizer.rasterize(url, side: 1024)
                let text = try String(contentsOf: url, encoding: .utf8)
                vector = VectorSource(svg: text,
                                      width: Double(raster.width), height: Double(raster.height))
                // Reading the file is not the same as rendering it, and a
                // malformed-but-renderable SVG must not stop it opening — so
                // the inspection is allowed to fail on its own.
                info = try? inspectSVG(text)
            } else {
                raster = try Raster.load(contentsOf: url)
            }
            adoptSource(Source(raster: raster, vector: vector),
                        url: url, name: url.lastPathComponent, svg: info)
            if rescan { scanFolder(of: url) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Take a new source, from a file or from nothing, and start a fresh edit
    /// on it. The one place a document begins, so Open, the folder walker and
    /// Blank canvas cannot drift apart over what "a new document" resets.
    ///
    /// The canvas size survives: it is a property of what you are making, not
    /// of which file you happen to have open.
    func adoptSource(_ source: Source, url: URL?, name: String, svg: SVGInfo? = nil) {
        let keepCanvas = doc?.canvas ?? saneCanvas(data.canvas)
        doc = Composition(source: source, canvas: keepCanvas)
        sourceURL = url
        sourceName = name
        svgInfo = svg
        sourceThumb = source.raster.nsImage()
        if url == nil { folder = []; folderIndex = 0 }
        undoStack.removeAll(); redoStack.removeAll()
        error = nil
        // The build controls describe the *previous* source; carrying them
        // over silently would apply a 60% square to a file you just opened.
        withControlsSilenced {
            invertOn = false; squareOn = false; discOn = false
        }
        resetFraming()
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

    // MARK: - picking off the canvas

    /// The colour the pointer is over, for the readout. Cheap — one array
    /// index into the raster the preview was built from.
    func hover(canvasX x: Double, canvasY y: Double) {
        guard picking, let r = lastRender else {
            if hovered != nil { hovered = nil }
            return
        }
        let px = r.sample(Int(x.rounded(.down)), Int(y.rounded(.down)))
        hovered = px.a > 0 ? RGB(px.r, px.g, px.b) : nil
    }

    func endHover() { hovered = nil }

    /// Sample the pixel actually on screen at this canvas coordinate, and give
    /// it to whichever eyedropper armed the click.
    ///
    /// A fully transparent pixel is refused for the *backdrop* — the backdrop
    /// is what you would be seeing through it, so sampling one would pick the
    /// backdrop again. For the colour history it is refused too, and for the
    /// same underlying reason: the colour you would be "picking" is not in the
    /// artwork, it is the thing behind it.
    func samplePixel(canvasX x: Double, canvasY y: Double) {
        let want = canvasPick
        canvasPick = .off
        hovered = nil
        guard want != .off, let r = lastRender else { return }
        let px = r.sample(Int(x.rounded(.down)), Int(y.rounded(.down)))
        guard px.a > 0 else {
            error = "That pixel is transparent — there is no colour there to pick."
            return
        }
        let rgb = RGB(px.r, px.g, px.b)
        switch want {
        case .backdrop: backdrop = .custom(Color(rgb))
        case .colour:   picked(rgb)
        case .off:      break
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
