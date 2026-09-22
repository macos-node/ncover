import Foundation

// The vector backend. Consumes the same operation list as the raster one, and
// writes SVG instead of pixels.
//
// This exists because rasterising an SVG in order to write an SVG is pure loss:
// a vector source has no native resolution, so every pixel the raster path
// produces is a decision that did not need making. Where the source is vector
// and every operation has a vector form, the output should be too.

extension Mask {
    /// The clip shape itself.
    /// The clip shape, placed in its region rather than assumed to fill the
    /// canvas — that is what lets the mask be fitted to the artwork.
    func svgClipShape(region reg: MaskRegion) -> String {
        let s = reg.side
        let ox = reg.cx - s / 2, oy = reg.cy - s / 2
        switch self {
        case .disc:
            return #"<circle cx="\#(f(reg.cx))" cy="\#(f(reg.cy))" r="\#(f(s / 2))"/>"#
        case .roundedRect(let frac):
            let r = max(0, min(1, frac)) * s / 2
            return #"<rect x="\#(f(ox))" y="\#(f(oy))" width="\#(f(s))" height="\#(f(s))" rx="\#(f(r))" ry="\#(f(r))"/>"#
        case .chamfer(let frac):
            let i = max(0, min(1, frac)) * s / 2
            let pts = [(i, 0.0), (s - i, 0.0), (s, i), (s, s - i),
                       (s - i, s), (i, s), (0.0, s - i), (0.0, i)]
                .map { "\(f(ox + $0.0)),\(f(oy + $0.1))" }.joined(separator: " ")
            return #"<polygon points="\#(pts)"/>"#
        }
    }

    /// The *inverse* of the clip shape, as an even-odd path.
    ///
    /// This is the detail that is easy to miss and wrong in a way that looks
    /// almost right: the outer fill must appear only outside the shape. Putting
    /// a plain filled rect behind the artwork also shows it through every
    /// transparent pixel *inside* the shape, which is a different picture. In
    /// the raster backend the `(1 - coverage)` term says this implicitly; in
    /// vector it has to be said out loud.
    func svgInverseClipPath(canvas c: Double, region reg: MaskRegion) -> String {
        let s = reg.side
        let ox = reg.cx - s / 2, oy = reg.cy - s / 2
        // The outer subpath is always the whole canvas; only the hole moves.
        let outer = #"M0,0 H\#(f(c)) V\#(f(c)) H0 Z "#
        let inner: String
        switch self {
        case .disc:
            let r = s / 2
            inner = #"M\#(f(reg.cx)),\#(f(reg.cy - r)) A\#(f(r)),\#(f(r)) 0 1,0 \#(f(reg.cx)),\#(f(reg.cy + r)) "# +
                    #"A\#(f(r)),\#(f(r)) 0 1,0 \#(f(reg.cx)),\#(f(reg.cy - r)) Z"#
        case .roundedRect(let frac):
            let r = max(0, min(1, frac)) * s / 2
            inner = #"M\#(f(ox + r)),\#(f(oy)) H\#(f(ox + s - r)) A\#(f(r)),\#(f(r)) 0 0,1 \#(f(ox + s)),\#(f(oy + r)) "# +
                    #"V\#(f(oy + s - r)) A\#(f(r)),\#(f(r)) 0 0,1 \#(f(ox + s - r)),\#(f(oy + s)) "# +
                    #"H\#(f(ox + r)) A\#(f(r)),\#(f(r)) 0 0,1 \#(f(ox)),\#(f(oy + s - r)) "# +
                    #"V\#(f(oy + r)) A\#(f(r)),\#(f(r)) 0 0,1 \#(f(ox + r)),\#(f(oy)) Z"#
        case .chamfer(let frac):
            let i = max(0, min(1, frac)) * s / 2
            inner = #"M\#(f(ox + i)),\#(f(oy)) H\#(f(ox + s - i)) L\#(f(ox + s)),\#(f(oy + i)) V\#(f(oy + s - i)) "# +
                    #"L\#(f(ox + s - i)),\#(f(oy + s)) H\#(f(ox + i)) L\#(f(ox)),\#(f(oy + s - i)) V\#(f(oy + i)) Z"#
        }
        return #"<path clip-rule="evenodd" d="\#(outer)\#(inner)"/>"#
    }

    /// Distance from the centre to the furthest drawn pixel centre — the same
    /// quantity the raster backend normalises its gradient by, so both ramps
    /// reach the outer stop at the same place.
    ///
    /// Only meaningful for `.disc`: a radial gradient follows the rim only when
    /// the rim is a circle. `Operation.hasVectorForm` refuses the other
    /// combinations rather than exporting a near-miss.
    /// Distance from the region's centre to the furthest canvas pixel centre,
    /// so both backends reach the outer stop in the same place even when the
    /// region is off-centre.
    func gradientOuterRadius(canvas c: Double, region reg: MaskRegion) -> Double {
        [(0.5, 0.5), (c - 0.5, 0.5), (0.5, c - 0.5), (c - 0.5, c - 0.5)]
            .map { (($0.0 - reg.cx) * ($0.0 - reg.cx) + ($0.1 - reg.cy) * ($0.1 - reg.cy)).squareRoot() }
            .max() ?? (c / 2)
    }

    func gradientInnerOffset(canvas c: Double, region reg: MaskRegion) -> Double {
        (reg.side / 2) / gradientOuterRadius(canvas: c, region: reg)
    }
}

private func hex(_ c: RGB) -> String {
    String(format: "#%02x%02x%02x", c.r, c.g, c.b)
}

/// Render the document as SVG, or `nil` when it cannot be — ask
/// `Composition.vectorRefusal` for the reason to show someone.
public func renderVector(_ doc: Composition) -> String? {
    guard doc.vectorRefusal == nil, let vec = doc.source.vector else { return nil }

    let c = Double(doc.canvas)
    var defs: [String] = []
    // Built inside-out: each mask wraps everything placed before it, exactly as
    // the raster fold applies each operation to the canvas so far.
    var body = ""

    for (i, op) in doc.ops.enumerated() {
        switch op {
        case .place(let p):
            let w = p.w(doc.source.raster.width)
            let h = p.h(doc.source.raster.height)
            body += vec.nested(x: p.dx, y: p.dy, width: w, height: h)

        case .mask(let m, let fill, let fit):
            // Fitting to the artwork needs to know what is drawn, which only
            // the raster fold can answer — so ask it, for the operations up to
            // this one. Export is not a hot path and correctness beats guessing
            // the bounds from the placement.
            let reg: MaskRegion
            if fit == .artwork {
                var prefix = doc
                prefix.ops = Array(doc.ops.prefix(i))
                reg = renderRaster(prefix).drawnRegion() ?? .canvas(doc.canvas)
            } else {
                reg = .canvas(doc.canvas)
            }
            let clipID = "mask\(i)", outID = "outside\(i)"
            defs.append("<clipPath id=\"\(clipID)\">\(m.svgClipShape(region: reg))</clipPath>")

            var layer = ""
            switch fill {
            case .alpha:
                layer = ""                       // nothing outside; that is the point
            case .white, .solid:
                let col = { if case .solid(let s) = fill { return hex(s) }; return "#ffffff" }()
                defs.append("<clipPath id=\"\(outID)\">\(m.svgInverseClipPath(canvas: c, region: reg))</clipPath>")
                layer = #"<g clip-path="url(#\#(outID))"><rect width="\#(f(c))" height="\#(f(c))" fill="\#(col)"/></g>"#
            case .gradient(let inner, let outer):
                let gID = "grad\(i)"
                defs.append("<clipPath id=\"\(outID)\">\(m.svgInverseClipPath(canvas: c, region: reg))</clipPath>")
                defs.append(
                    #"<radialGradient id="\#(gID)" gradientUnits="userSpaceOnUse" "# +
                    #"cx="\#(f(reg.cx))" cy="\#(f(reg.cy))" r="\#(f(m.gradientOuterRadius(canvas: c, region: reg)))">"# +
                    #"<stop offset="\#(f(m.gradientInnerOffset(canvas: c, region: reg)))" stop-color="\#(hex(inner))"/>"# +
                    #"<stop offset="1" stop-color="\#(hex(outer))"/></radialGradient>"#)
                layer = #"<g clip-path="url(#\#(outID))"><rect width="\#(f(c))" height="\#(f(c))" fill="url(#\#(gID))"/></g>"#
            }
            body = layer + #"<g clip-path="url(#\#(clipID))">"# + body + "</g>"

        case .invert:
            let fID = "invert\(i)"
            // RGB inverted, alpha untouched — the same rule as invertRGB.
            let matrix = "-1 0 0 0 1  0 -1 0 0 1  0 0 -1 0 1  0 0 0 1 0"
            let fm = "<feColorMatrix type=" + "\"matrix\"" + " values=" + "\"\(matrix)\"" + "/>"
            defs.append(#"<filter id="\#(fID)" color-interpolation-filters="sRGB">"# + fm + "</filter>")
            body = #"<g filter="url(#\#(fID))">"# + body + "</g>"
        }
    }

    let defsBlock = defs.isEmpty ? "" : "\n  <defs>\(defs.joined())</defs>"
    return #"""
    <svg xmlns="http://www.w3.org/2000/svg" width="\#(f(c))" height="\#(f(c))" viewBox="0 0 \#(f(c)) \#(f(c))">\#(defsBlock)
      \#(body)
    </svg>
    """#
}
