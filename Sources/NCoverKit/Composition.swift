import Foundation

// The shape of the app, rather than a pipeline.
//
// A document is a SOURCE plus an ordered list of OPERATIONS. Nothing here knows
// how it will be rendered — two backends consume the same list: raster (always
// available, drives the preview) and vector (available when the source is
// vector and every operation in the list has a vector form).
//
// This is what keeps the scope open. Adding an operation means adding a case
// and saying whether it can be expressed as vector; it does not mean touching a
// pipeline. And because the document is a value, undo is a stack of documents
// rather than a set of inverse operations that have to be written and kept
// correct one by one.

// MARK: - source

/// What was opened. The raster is always present — it is what the preview and
/// any raster export are built from. `vector` is present only when the file was
/// an SVG, and its presence is exactly the condition for vector output.
public struct Source: Equatable, Sendable {
    public var raster: Raster
    public var vector: VectorSource?

    public init(raster: Raster, vector: VectorSource? = nil) {
        self.raster = raster
        self.vector = vector
    }

    public var isVector: Bool { vector != nil }
}

/// An SVG kept as itself rather than as pixels.
public struct VectorSource: Equatable, Sendable {
    /// The document text, verbatim.
    public var svg: String
    /// Intrinsic size, from `viewBox` where there is one.
    public var width: Double
    public var height: Double

    public init(svg: String, width: Double, height: Double) {
        self.svg = svg; self.width = width; self.height = height
    }

    /// The source element, re-headed so it can be nested inside another `<svg>`.
    /// Nested `<svg>` is valid SVG and avoids rewriting the artwork's own
    /// coordinates — the alternative, editing its paths, would be a rewrite of
    /// someone else's drawing.
    public func nested(x: Double, y: Double, width w: Double, height h: Double) -> String {
        let text = svg.replacingOccurrences(
            of: #"<\?xml[^>]*\?>"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let open = text.range(of: #"<svg[^>]*>"#, options: .regularExpression) else {
            return text
        }
        var attrs = String(text[open])
        attrs = attrs.replacingOccurrences(
            of: #"\s(width|height|x|y)="[^"]*""#, with: "", options: .regularExpression)
        attrs = String(attrs.dropLast())                      // drop '>'
        attrs = attrs.replacingOccurrences(of: "<svg", with: "")
        let head = #"<svg x="\#(f(x))" y="\#(f(y))" width="\#(f(w))" height="\#(f(h))"\#(attrs)>"#
        return head + text[open.upperBound...]
    }
}

// MARK: - masks

/// A mask is a signed distance function, not a shape special case.
///
/// Negative inside, positive outside, in pixels. Coverage and the corner
/// gradient are both derived from it, so a new shape is a new distance
/// function and nothing else — the antialiased rim, the corner fill and the
/// vector form all follow.
public enum Mask: Equatable, Sendable {
    case disc
    /// Corner radius as a fraction of half the canvas. At 1.0 this *is* the
    /// disc — which is a useful property, not a coincidence: it means the
    /// slider runs continuously from square to circle.
    case roundedRect(radius: Double)
    /// Corner cut as a fraction of half the canvas. At 1.0 the octagon has
    /// closed up into a diamond.
    case chamfer(inset: Double)

    public func signedDistance(x: Double, y: Double, size: Double) -> Double {
        let c = size / 2
        let px = x - c, py = y - c
        switch self {
        case .disc:
            return (px * px + py * py).squareRoot() - c

        case .roundedRect(let f):
            // Standard rounded-box distance: shrink the box by the radius,
            // measure to that, then subtract the radius back.
            let r = max(0, min(1, f)) * c
            let qx = abs(px) - (c - r), qy = abs(py) - (c - r)
            let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
            return outside + min(max(qx, qy), 0) - r

        case .chamfer(let f):
            // A box intersected with the two diagonal half-planes that cut its
            // corners. The cut passes through (c - i, c) and (c, c - i).
            let i = max(0, min(1, f)) * c
            let box = max(abs(px) - c, abs(py) - c)
            let diagonal = (abs(px) + abs(py) - (2 * c - i)) / 2.0.squareRoot()
            return max(box, diagonal)
        }
    }

    /// The largest signed distance any drawn pixel reaches — the corner pixel's
    /// centre, not the abstract corner. Normalising the gradient to the abstract
    /// corner leaves the corner pixel short of the outer stop.
    public func maxSignedDistance(size: Double) -> Double {
        signedDistance(x: 0.5, y: 0.5, size: size)
    }

    public var label: String {
        switch self {
        case .disc:         return "Disc"
        case .roundedRect:  return "Rounded"
        case .chamfer:      return "Chamfer"
        }
    }
}

/// What the mask is sized and centred on.
public enum MaskFit: String, Equatable, Sendable, CaseIterable {
    /// Inscribed in the canvas. A source that does not reach the canvas edges
    /// is then only clipped at its corners — correct, and not what most people
    /// expect the first time.
    case canvas
    /// Inscribed in the square that bounds whatever is actually drawn. A disc
    /// over an inset icon becomes a disc *of the icon*.
    case artwork

    public var label: String { self == .canvas ? "Canvas" : "Artwork" }
}

/// The square a mask is inscribed in: centre, and side.
public struct MaskRegion: Equatable, Sendable {
    public var cx: Double, cy: Double, side: Double
    public init(cx: Double, cy: Double, side: Double) {
        self.cx = cx; self.cy = cy; self.side = side
    }

    public static func canvas(_ size: Int) -> MaskRegion {
        MaskRegion(cx: Double(size) / 2, cy: Double(size) / 2, side: Double(size))
    }
}

extension Raster {
    /// Alpha at or below this counts as nothing drawn. Not zero: an antialiased
    /// edge or a faint glow would otherwise stretch the bounds to the whole
    /// canvas and make "fit to artwork" mean nothing.
    public static let drawnAlphaFloor: UInt8 = 8

    /// The square bounding whatever is drawn, centred on the drawn content.
    ///
    /// A square rather than the raw rectangle because the masks are inscribed
    /// in squares — and the side is the *larger* dimension, so the mask reaches
    /// the artwork's widest extent rather than cutting into it.
    /// `nil` when nothing is drawn at all.
    public func drawnRegion() -> MaskRegion? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where px[row + x * 4 + 3] > Raster.drawnAlphaFloor {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let w = Double(maxX - minX + 1), h = Double(maxY - minY + 1)
        return MaskRegion(cx: Double(minX) + w / 2,
                          cy: Double(minY) + h / 2,
                          side: max(w, h))
    }
}

// MARK: - operations

public enum Operation: Equatable, Sendable {
    /// Draw the source onto the canvas at this placement.
    case place(Placement)
    /// Mask what is on the canvas, filling outside it.
    case mask(Mask, fill: OuterFill, fit: MaskFit)
    /// Invert RGB, leaving alpha alone.
    case invert

    /// Whether this operation can be written as vector rather than pixels.
    /// The honest answer per case, not a guess — it decides whether the app
    /// offers SVG export, and the UI can name the step that refused.
    public var hasVectorForm: Bool {
        switch self {
        case .place:
            return true                            // a transform
        case .mask(let m, let fill, _):
            // A clipPath, plus an inverse-clipped fill. With one honest
            // exception: the corner gradient is a *radial* gradient, which can
            // only follow the shape when the shape is a circle. For a rounded
            // rectangle or a chamfer the raster backend's distance-field ramp
            // has no SVG equivalent, so this says so rather than exporting a
            // picture that does not match the screen.
            if case .gradient = fill, m != .disc { return false }
            return true
        case .invert:
            return true                            // feColorMatrix
        }
    }

    public var label: String {
        switch self {
        case .place:            return "Place"
        case .mask(let m, _, let fit):
            return m.label + " mask" + (fit == .artwork ? " (artwork)" : "")
        case .invert:           return "Invert"
        }
    }
}

// MARK: - composition

public struct Composition: Equatable, Sendable {
    public var source: Source
    public var canvas: Int
    public var ops: [Operation]

    public init(source: Source, canvas: Int = CANVAS_DEFAULT, ops: [Operation] = []) {
        self.source = source
        self.canvas = canvas
        self.ops = ops
    }

    /// The placement, if one has been set — the common case of reaching into
    /// the list for the thing the canvas gestures edit.
    public var placement: Placement? {
        for case .place(let p) in ops { return p }
        return nil
    }

    public mutating func setPlacement(_ p: Placement) {
        if let i = ops.firstIndex(where: { if case .place = $0 { return true }; return false }) {
            ops[i] = .place(p)
        } else {
            ops.insert(.place(p), at: 0)
        }
    }

    /// Why vector export is unavailable, or nil when it is available. Phrased
    /// for showing to someone rather than for logging.
    public var vectorRefusal: String? {
        guard source.isVector else { return "the source is not an SVG" }
        for (i, op) in ops.enumerated() where !op.hasVectorForm {
            return "step \(i + 1), \(op.label), has no vector form"
        }
        return nil
    }
}

// MARK: - the raster backend

/// Fold the operations over a canvas. Always available; drives the preview, so
/// what is on screen is what a raster export would write.
public func renderRaster(_ doc: Composition) -> Raster {
    var canvasRaster = Raster(empty: doc.canvas, height: doc.canvas)
    for op in doc.ops {
        switch op {
        case .place(let p):
            canvasRaster = compose(doc.source.raster, p, canvas: doc.canvas)
        case .mask(let m, let fill, let fit):
            // Fitting to the artwork means asking what is currently drawn, so
            // the region is computed from the canvas as it stands at this point
            // in the list — not from the source, and not from the whole canvas.
            let region: MaskRegion = fit == .artwork
                ? (canvasRaster.drawnRegion() ?? .canvas(doc.canvas))
                : .canvas(doc.canvas)
            canvasRaster = applyMask(canvasRaster, m, fill: fill, region: region) ?? canvasRaster
        case .invert:
            canvasRaster = invertRGB(canvasRaster)
        }
    }
    return canvasRaster
}

func f(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(format: "%.4f", d)
}
