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
    func svgClipShape(size s: Double) -> String {
        switch self {
        case .disc:
            return #"<circle cx="\#(f(s / 2))" cy="\#(f(s / 2))" r="\#(f(s / 2))"/>"#
        case .roundedRect(let frac):
            let r = max(0, min(1, frac)) * s / 2
            return #"<rect width="\#(f(s))" height="\#(f(s))" rx="\#(f(r))" ry="\#(f(r))"/>"#
        case .chamfer(let frac):
            let i = max(0, min(1, frac)) * s / 2
            let pts = [(i, 0.0), (s - i, 0.0), (s, i), (s, s - i),
                       (s - i, s), (i, s), (0.0, s - i), (0.0, i)]
                .map { "\(f($0.0)),\(f($0.1))" }.joined(separator: " ")
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
    func svgInverseClipPath(size s: Double) -> String {
        let outer = #"M0,0 H\#(f(s)) V\#(f(s)) H0 Z "#
        let inner: String
        switch self {
        case .disc:
            let r = s / 2, c = s / 2
            inner = #"M\#(f(c)),\#(f(c - r)) A\#(f(r)),\#(f(r)) 0 1,0 \#(f(c)),\#(f(c + r)) "# +
                    #"A\#(f(r)),\#(f(r)) 0 1,0 \#(f(c)),\#(f(c - r)) Z"#
        case .roundedRect(let frac):
            let r = max(0, min(1, frac)) * s / 2
            inner = #"M\#(f(r)),0 H\#(f(s - r)) A\#(f(r)),\#(f(r)) 0 0,1 \#(f(s)),\#(f(r)) "# +
                    #"V\#(f(s - r)) A\#(f(r)),\#(f(r)) 0 0,1 \#(f(s - r)),\#(f(s)) "# +
                    #"H\#(f(r)) A\#(f(r)),\#(f(r)) 0 0,1 0,\#(f(s - r)) "# +
                    #"V\#(f(r)) A\#(f(r)),\#(f(r)) 0 0,1 \#(f(r)),0 Z"#
        case .chamfer(let frac):
            let i = max(0, min(1, frac)) * s / 2
            inner = #"M\#(f(i)),0 H\#(f(s - i)) L\#(f(s)),\#(f(i)) V\#(f(s - i)) "# +
                    #"L\#(f(s - i)),\#(f(s)) H\#(f(i)) L0,\#(f(s - i)) V\#(f(i)) Z"#
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
    func gradientOuterRadius(size: Double) -> Double {
        maxSignedDistance(size: size) + size / 2
    }

    func gradientInnerOffset(size: Double) -> Double {
        (size / 2) / gradientOuterRadius(size: size)
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

        case .mask(let m, let fill):
            let clipID = "mask\(i)", outID = "outside\(i)"
            defs.append("<clipPath id=\"\(clipID)\">\(m.svgClipShape(size: c))</clipPath>")

            var layer = ""
            switch fill {
            case .alpha:
                layer = ""                       // nothing outside; that is the point
            case .white, .solid:
                let col = { if case .solid(let s) = fill { return hex(s) }; return "#ffffff" }()
                defs.append("<clipPath id=\"\(outID)\">\(m.svgInverseClipPath(size: c))</clipPath>")
                layer = #"<g clip-path="url(#\#(outID))"><rect width="\#(f(c))" height="\#(f(c))" fill="\#(col)"/></g>"#
            case .gradient(let inner, let outer):
                let gID = "grad\(i)"
                defs.append("<clipPath id=\"\(outID)\">\(m.svgInverseClipPath(size: c))</clipPath>")
                defs.append(
                    #"<radialGradient id="\#(gID)" gradientUnits="userSpaceOnUse" "# +
                    #"cx="\#(f(c / 2))" cy="\#(f(c / 2))" r="\#(f(m.gradientOuterRadius(size: c)))">"# +
                    #"<stop offset="\#(f(m.gradientInnerOffset(size: c)))" stop-color="\#(hex(inner))"/>"# +
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
