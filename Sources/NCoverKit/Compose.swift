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
///
/// **Which resampler runs depends on direction, and that distinction is the
/// whole point.** Shrinking an image point-samples away most of it: at the
/// scale a 2048px raster reaches a 400px canvas, twenty-five pixels in every
/// twenty-six were simply discarded, which is why thin rules thickened
/// unevenly and curves went hard. Enlarging has the opposite need — there,
/// nearest-neighbour is correct, because a colour tool must not invent a
/// colour that is in neither neighbour.
///
/// So: **downscale area-averages, upscale stays nearest.** The inherited rule
/// survives where it was right and is dropped where it was doing harm.
public func compose(_ src: Raster, _ p: Placement, canvas: Int) -> Raster {
    guard src.width > 0, src.height > 0, p.scale > 0, canvas > 0 else {
        return Raster(empty: canvas, height: canvas)
    }
    return p.scale < 1
        ? composeAreaAveraged(src, p, canvas: canvas)
        : composeNearest(src, p, canvas: canvas)
}

/// Enlarging, or 1:1. Nearest-neighbour, deliberately.
func composeNearest(_ src: Raster, _ p: Placement, canvas: Int) -> Raster {
    var dst = Raster(empty: canvas, height: canvas)
    for y in 0..<canvas {
        for x in 0..<canvas {
            let sx = Int(((Double(x) + 0.5 - p.dx) / p.scale).rounded(.down))
            let sy = Int(((Double(y) + 0.5 - p.dy) / p.scale).rounded(.down))
            if sx < 0 || sy < 0 || sx >= src.width || sy >= src.height { continue }
            dst.set(x, y, src.sample(sx, sy))
        }
    }
    return dst
}

/// Shrinking. Every destination pixel averages the whole source rectangle it
/// covers, with fractional weights at the edges of that rectangle.
///
/// Two details that are easy to get wrong and expensive to debug:
///
///  - **The average is taken in premultiplied space.** Averaging straight RGBA
///    lets a fully transparent pixel drag its meaningless colour into the
///    result, which shows up as dark or coloured fringing around anything with
///    an alpha edge — and this app's output is alpha-edged by definition.
///  - **The divisor is the whole box, not just the part that landed on the
///    source.** That makes source area off the edge count as transparent, so
///    the placed image gets a correctly antialiased boundary instead of the
///    hard one nearest-neighbour leaves.
/// One axis of the box filter, precomputed.
///
/// The weights depend only on the destination index, never on the other axis,
/// so computing them per sample — as the first version did — repeated the same
/// arithmetic millions of times. `extent` is the *unclamped* width of the box:
/// normalising by it rather than by the weights that landed on the source is
/// what makes off-the-edge area count as transparent.
private struct Span {
    let start: Int
    let weights: [Double]
    let extent: Double
}

private func spans(count: Int, offset: Double, inv: Double, limit: Int) -> [Span] {
    (0..<count).map { i in
        let s0 = (Double(i) - offset) * inv
        let s1 = (Double(i) + 1 - offset) * inv
        let lo = max(Int(s0.rounded(.down)), 0)
        let hi = min(Int(s1.rounded(.up)), limit)
        guard hi > lo else { return Span(start: 0, weights: [], extent: s1 - s0) }
        var w = [Double]()
        w.reserveCapacity(hi - lo)
        for k in lo..<hi {
            w.append(max(0, min(s1, Double(k) + 1) - max(s0, Double(k))))
        }
        return Span(start: lo, weights: w, extent: s1 - s0)
    }
}

func composeAreaAveraged(_ src: Raster, _ p: Placement, canvas: Int) -> Raster {
    var dst = Raster(empty: canvas, height: canvas)
    let inv = 1.0 / p.scale
    let xs = spans(count: canvas, offset: p.dx, inv: inv, limit: src.width)
    let ys = spans(count: canvas, offset: p.dy, inv: inv, limit: src.height)
    let stride = src.width * 4

    src.px.withUnsafeBufferPointer { sp in
        dst.px.withUnsafeMutableBufferPointer { dp in
            for y in 0..<canvas {
                let ys_ = ys[y]
                if ys_.weights.isEmpty { continue }
                for x in 0..<canvas {
                    let xs_ = xs[x]
                    if xs_.weights.isEmpty { continue }

                    var r = 0.0, g = 0.0, b = 0.0, a = 0.0
                    for (j, wy) in ys_.weights.enumerated() {
                        if wy <= 0 { continue }
                        let rowBase = (ys_.start + j) * stride
                        for (i, wx) in xs_.weights.enumerated() {
                            let w = wx * wy
                            if w <= 0 { continue }
                            let o = rowBase + (xs_.start + i) * 4
                            let af = Double(sp[o + 3]) / 255 * w
                            // premultiplied accumulation: a transparent pixel
                            // must not drag its meaningless colour in
                            r += Double(sp[o]) * af
                            g += Double(sp[o + 1]) * af
                            b += Double(sp[o + 2]) * af
                            a += af
                        }
                    }

                    if a <= 0 { continue }
                    let alpha = a / (xs_.extent * ys_.extent)
                    let k = 1.0 / a
                    let o = (y * canvas + x) * 4
                    dp[o]     = UInt8((r * k).rounded().clamped(0, 255))
                    dp[o + 1] = UInt8((g * k).rounded().clamped(0, 255))
                    dp[o + 2] = UInt8((b * k).rounded().clamped(0, 255))
                    dp[o + 3] = UInt8((alpha * 255).rounded().clamped(0, 255))
                }
            }
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

/// Mask `src` to a shape inscribed in a square canvas, filling outside it.
///
/// The shape arrives as a signed distance function (`Mask`), so this one
/// routine does every shape: the antialiased rim, the corner fill and the
/// gradient normalisation are all derived from that distance rather than
/// written per shape. Adding a rounded rectangle or a chamfer is a new
/// `signedDistance` case and nothing here.
///
/// The source is scaled to COVER the square (never letterboxed — a disc with
/// bars through it is not a disc), and the rim is antialiased over one pixel so
/// the edge does not read as a staircase.
public func applyMask(_ src: Raster, _ mask: Mask, fill: OuterFill,
                      region: MaskRegion? = nil) -> Raster? {
    let sw = src.width, sh = src.height
    guard sw > 0, sh > 0 else { return nil }

    let size = max(sw, sh)
    var dst = Raster(empty: size, height: size)

    let fsize = Double(size)
    let cx = fsize / 2, cy = fsize / 2
    // Cover: the smaller source axis must reach across the square.
    let scale = fsize / Double(min(sw, sh))

    // The square the mask is inscribed in. Defaults to the whole canvas; a
    // region fitted to the drawn content puts the mask on the artwork instead.
    let r = region ?? .canvas(size)
    // Evaluate the shape in its own frame, so the distance functions stay
    // written as "inscribed in a square of side `size`" and know nothing about
    // where that square sits.
    func sd(_ x: Double, _ y: Double) -> Double {
        mask.signedDistance(x: x - r.cx + r.side / 2,
                            y: y - r.cy + r.side / 2,
                            size: r.side)
    }

    // Normalise the gradient to the furthest PIXEL CENTRE, not to the abstract
    // corner. A pixel's centre is half a pixel inside the corner, so
    // normalising to the corner leaves the corner pixel short of the outer stop
    // (94.7% on a 64px canvas — ask for black->white and the corner comes out
    // #F1F1F1). The furthest thing actually drawn should reach the end of the ramp.
    //
    // With an off-centre region the four corners are no longer equivalent, so
    // take the largest rather than assuming symmetry.
    let sdMax = [ (0.5, 0.5), (fsize - 0.5, 0.5), (0.5, fsize - 0.5), (fsize - 0.5, fsize - 0.5) ]
        .map { sd($0.0, $0.1) }.max() ?? 1

    for y in 0..<size {
        for x in 0..<size {
            let d = sd(Double(x) + 0.5, Double(y) + 0.5)

            // Coverage: 1 inside, 0 outside, ramped across the last pixel.
            let cov = (0.5 - d).clamped(0, 1)

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
                let t = (d / sdMax).clamped(0, 1)
                outC = RGBA(lerp(inner.r, outer.r, t),
                            lerp(inner.g, outer.g, t),
                            lerp(inner.b, outer.b, t), 255)
            }

            // Composite the masked artwork over the outer fill by coverage.
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

/// The disc, by its old name. Kept so the tests ported from the GTK app still
/// exercise the path they were written against — if the generalisation above
/// changed the disc by so much as a pixel, those tests say so.
public func discTemplate(_ src: Raster, fill: OuterFill) -> Raster? {
    applyMask(src, .disc, fill: fill)
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
