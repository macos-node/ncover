import Foundation

public enum Framing: String, CaseIterable, Sendable {
    case cover, fit
}

/// What happens outside the disc.
public enum OuterFill: Equatable, Sendable {
    /// The corners are simply not there. The honest default for artwork that
    /// will sit on an unknown background.
    case alpha
    case white
    case solid(RGB)
    /// Radial, from the disc's edge outward: `inner` at the rim, `outer` at the
    /// corners.
    case gradient(inner: RGB, outer: RGB)
}

public struct Recipe: Equatable, Sendable {
    public var canvas: Int
    public var framing: Framing
    /// `nil` = no disc: just the framed square. The disc is an option, not the
    /// point — resizing a folder of covers is a job on its own.
    public var disc: OuterFill?

    public init(canvas: Int, framing: Framing, disc: OuterFill?) {
        self.canvas = canvas; self.framing = framing; self.disc = disc
    }
}

public let CANVAS_SIZES = [200, 400, 600, 800, 1000]
public let CANVAS_DEFAULT = 400

public func saneCanvas(_ n: Int) -> Int {
    CANVAS_SIZES.contains(n) ? n : CANVAS_DEFAULT
}

/// Render the placed source onto the square canvas. Outside the image is
/// transparent — the disc's corner fill decides what happens there, not this.
public func compose(_ src: Raster, _ p: Placement, canvas: Int) -> Raster {
    var dst = Raster(empty: canvas, height: canvas)
    guard src.width > 0, src.height > 0, p.scale > 0 else { return dst }

    for y in 0..<canvas {
        for x in 0..<canvas {
            // Canvas pixel -> source pixel (nearest: a colour tool must not
            // invent colours that are in neither neighbour).
            let sx = Int(((Double(x) + 0.5 - p.dx) / p.scale).rounded(.down))
            let sy = Int(((Double(y) + 0.5 - p.dy) / p.scale).rounded(.down))
            if sx < 0 || sy < 0 || sx >= src.width || sy >= src.height { continue } // transparent
            dst.set(x, y, src.sample(sx, sy))
        }
    }
    return dst
}

/// A blank opaque-white square, the ground you build a label on. White because a
/// record label is white far more often than not, and Invert reaches black in
/// one click from here.
public func blankCanvas(_ size: Int) -> Raster {
    var r = Raster(empty: size, height: size)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = 255; r.px[i + 1] = 255; r.px[i + 2] = 255; r.px[i + 3] = 255
    }
    return r
}

/// Invert RGB on a copy, leaving alpha alone. A colour tool inverts the COLOUR,
/// not the shape: a transparent pixel stays transparent, it does not become an
/// opaque black one.
public func invertRGB(_ src: Raster) -> Raster {
    var out = src
    for i in stride(from: 0, to: out.px.count, by: 4) {
        out.px[i] = 255 - out.px[i]
        out.px[i + 1] = 255 - out.px[i + 1]
        out.px[i + 2] = 255 - out.px[i + 2]
    }
    return out
}

/// Mask `src` into a disc inscribed in a square canvas, filling the corners
/// per `fill`.
///
/// The source is scaled to COVER the square (never letterboxed — a disc with
/// bars through it is not a disc), and the rim is antialiased over one pixel so
/// the edge does not read as a staircase.
public func discTemplate(_ src: Raster, fill: OuterFill) -> Raster? {
    let sw = src.width, sh = src.height
    guard sw > 0, sh > 0 else { return nil }

    let size = max(sw, sh)
    var dst = Raster(empty: size, height: size)

    let cx = Double(size) / 2, cy = Double(size) / 2
    let radius = Double(size) / 2
    // Cover: the smaller source axis must reach across the square.
    let scale = Double(size) / Double(min(sw, sh))
    // Gradient normalisation: distance to the furthest PIXEL CENTRE, not to the
    // abstract corner. A pixel's centre is half a pixel inside the corner, so
    // normalising to the corner leaves the corner pixel short of the outer stop
    // (94.7% on a 64px canvas — ask for black->white and the corner comes out
    // #F1F1F1). The furthest thing that actually gets drawn should reach the
    // end of the ramp.
    let corner = ((cx - 0.5) * (cx - 0.5) + (cy - 0.5) * (cy - 0.5)).squareRoot()

    for y in 0..<size {
        for x in 0..<size {
            let ddx = Double(x) + 0.5 - cx
            let ddy = Double(y) + 0.5 - cy
            let dist = (ddx * ddx + ddy * ddy).squareRoot()

            // Coverage: 1 inside, 0 outside, ramped across the last pixel.
            let cov = ((radius - dist) + 0.5).clamped(0, 1)

            // Source pixel under this destination pixel (cover-scaled, centred).
            let sx = Int(((Double(x) - cx) / scale + Double(sw) / 2).rounded(.down))
            let sy = Int(((Double(y) - cy) / scale + Double(sh) / 2).rounded(.down))
            let inC = src.sample(sx, sy)

            let outC: RGBA
            switch fill {
            case .alpha:        outC = RGBA(0, 0, 0, 0)
            case .white:        outC = RGBA(255, 255, 255, 255)
            case .solid(let c): outC = RGBA(c.r, c.g, c.b, 255)
            case .gradient(let inner, let outer):
                let t = ((dist - radius) / (corner - radius)).clamped(0, 1)
                outC = RGBA(lerp(inner.r, outer.r, t),
                            lerp(inner.g, outer.g, t),
                            lerp(inner.b, outer.b, t), 255)
            }

            // Composite the disc over the corner fill by coverage.
            let aIn = Double(inC.a) / 255 * cov
            let aOut = Double(outC.a) / 255 * (1 - cov)
            let a = aIn + aOut
            if a <= 0 { dst.set(x, y, RGBA(0, 0, 0, 0)); continue }

            func mix(_ inside: UInt8, _ outside: UInt8) -> UInt8 {
                UInt8(((Double(inside) * aIn + Double(outside) * aOut) / a).rounded().clamped(0, 255))
            }
            dst.set(x, y, RGBA(mix(inC.r, outC.r), mix(inC.g, outC.g), mix(inC.b, outC.b),
                               UInt8((a * 255).rounded().clamped(0, 255))))
        }
    }
    return dst
}

/// The whole v1 pipeline: frame the source, then optionally disc it.
public func render(_ src: Raster, recipe r: Recipe, placement: Placement? = nil) -> Raster {
    let p = placement ?? (r.framing == .cover
        ? Placement.cover(sw: src.width, sh: src.height, canvas: r.canvas)
        : Placement.fit(sw: src.width, sh: src.height, canvas: r.canvas))
    let framed = compose(src, p, canvas: r.canvas)
    guard let fill = r.disc else { return framed }
    return discTemplate(framed, fill: fill) ?? framed
}
