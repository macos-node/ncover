import CoreGraphics
import CoreText
import Foundation

// Type, as an operation.
//
// The reason this exists: a low-resolution raster of lettering cannot be
// improved. Tracing it into paths gets you a careful imitation of a bad scan.
// Setting the words again in a real font gets you the lettering, at any size,
// as vector — which is what the person wanted in the first place.
//
// **One layout, two backends.** `layoutText` is the only place that decides
// where a glyph goes; the raster backend draws those glyphs and the vector
// backend turns the same ones into paths. They agree by construction rather
// than by two pieces of arithmetic happening to match, which is the same rule
// the gradient normalisation and the batch renderer already follow.

/// A line of type on the canvas.
///
/// Sizes and positions are **fractions of the canvas**, not points. Changing
/// the output size then scales the type with it, which is the behaviour the
/// rest of the app already has — changing the canvas rescales the framing
/// rather than re-cropping it, and type that stayed 24pt while the square grew
/// from 200 to 1000 would be a different design.
public struct TextSpec: Equatable, Sendable {
    public var string: String
    /// PostScript name, e.g. "Helvetica-Bold".
    public var font: String
    /// Cap-to-cap size as a fraction of the canvas side.
    public var size: Double
    public var colour: RGB
    /// Centre of the text block, as fractions of the canvas.
    public var x: Double
    public var y: Double
    /// Letter spacing, as a fraction of the font size.
    public var tracking: Double
    /// Line height as a multiple of the font size.
    public var lineSpacing: Double

    public init(string: String, font: String = "Helvetica", size: Double = 0.2,
                colour: RGB = .black, x: Double = 0.5, y: Double = 0.5,
                tracking: Double = 0, lineSpacing: Double = 1.2) {
        self.string = string; self.font = font; self.size = size; self.colour = colour
        self.x = x; self.y = y; self.tracking = tracking; self.lineSpacing = lineSpacing
    }

    /// A short form for the step list.
    public var label: String {
        let flat = string.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let shown = flat.count > 14 ? String(flat.prefix(13)) + "…" : flat
        return shown.isEmpty ? "Text" : "Text “\(shown)”"
    }
}

// MARK: - the size control
//
// Size is a fraction of the canvas, and the useful range of that fraction is
// enormous: a credit line at 3% and a single letterform bleeding off all four
// edges at 200% are both things people set. A hundredfold range on a linear
// slider is unusable at the bottom — the first tenth of the travel covers
// everything from invisible to a caption — so the slider is logarithmic.

/// Smallest and largest type, as fractions of the canvas side.
///
/// The top end is deliberately past 1.0: a letter larger than the square,
/// cropped by it, is a deliberate thing to draw and not a mistake to prevent.
public let TEXT_SIZE_MIN = 0.02
public let TEXT_SIZE_MAX = 2.0

/// Where a size sits on the slider, 0...1. Logarithmic, so equal travel is
/// equal *ratio* — and the 0.2 default lands exactly halfway, which is the
/// sign that the range is centred on the sizes people actually use.
public func textSizeSliderPosition(_ size: Double) -> Double {
    let v = min(max(size, TEXT_SIZE_MIN), TEXT_SIZE_MAX)
    return log(v / TEXT_SIZE_MIN) / log(TEXT_SIZE_MAX / TEXT_SIZE_MIN)
}

/// The inverse.
public func textSizeFromSlider(_ t: Double) -> Double {
    TEXT_SIZE_MIN * pow(TEXT_SIZE_MAX / TEXT_SIZE_MIN, min(max(t, 0), 1))
}

/// Tracking's range. Negative far enough to set display lettering genuinely
/// tight — letters touching is a thing a monogram does on purpose.
public let TEXT_TRACKING_MIN = -0.25
public let TEXT_TRACKING_MAX = 0.75

/// One glyph, placed. `x`/`y` are the glyph's origin on the baseline in
/// **canvas coordinates — y increasing downward**, like `Raster`.
///
/// Core Text works the other way up, so the flip happens once, here, rather
/// than separately in each backend where the two could drift apart.
public struct PlacedGlyph: Equatable, Sendable {
    public var glyph: CGGlyph
    public var x: Double
    public var y: Double
}

public struct TextLayout {
    public var font: CTFont
    public var glyphs: [PlacedGlyph]
    /// The block's bounds in canvas coordinates, for showing where it sits.
    public var bounds: CGRect
}

/// Whether the system can actually produce this font, as opposed to quietly
/// substituting another one.
///
/// Core Text never fails to give you *a* font, so asking is the only way to
/// know. It matters less here than it would elsewhere — the glyphs become
/// paths on the way out, so what you see is what the file gets — but "that is
/// not the font I asked for" is still a question worth being able to answer.
public func fontIsAvailable(_ name: String) -> Bool {
    let f = CTFontCreateWithName(name as CFString, 12, nil)
    let got = CTFontCopyPostScriptName(f) as String
    if got.caseInsensitiveCompare(name) == .orderedSame { return true }
    // A family name ("Helvetica Neue") resolves to a face ("HelveticaNeue"),
    // which is a match, not a substitution.
    let family = CTFontCopyFamilyName(f) as String
    return family.caseInsensitiveCompare(name) == .orderedSame
}

/// Where every glyph goes. `nil` for an empty string or a zero-size canvas —
/// nothing to place, which is not an error.
public func layoutText(_ spec: TextSpec, canvas: Int) -> TextLayout? {
    let side = Double(canvas)
    guard side > 0, !spec.string.isEmpty else { return nil }
    let pts = max(1, spec.size * side)
    let font = CTFontCreateWithName(spec.font as CFString, pts, nil)

    // Split on newlines rather than wrapping. Label art is a line or two set
    // deliberately; a text box that reflows is a different tool.
    let lines = spec.string.components(separatedBy: "\n")
    var attrs: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font]
    if spec.tracking != 0 {
        attrs[kCTKernAttributeName as NSAttributedString.Key] = spec.tracking * pts
    }

    struct Measured { let line: CTLine; let width: Double; let ascent: Double; let descent: Double }
    let measured: [Measured] = lines.map { text in
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attrs))
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &asc, &desc, &lead)
        return Measured(line: line, width: w, ascent: asc, descent: desc)
    }

    let lineHeight = pts * spec.lineSpacing
    // The block runs from the first line's ascent to the last line's descent.
    // Measuring it any other way leaves a single line off-centre by the font's
    // own internal leading, which reads as a mistake because it is one.
    let blockHeight = (measured.first?.ascent ?? 0)
        + lineHeight * Double(measured.count - 1)
        + (measured.last?.descent ?? 0)
    let top = spec.y * side - blockHeight / 2
    let centreX = spec.x * side

    var glyphs: [PlacedGlyph] = []
    var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
    for (i, m) in measured.enumerated() {
        let baseline = top + (measured.first?.ascent ?? 0) + lineHeight * Double(i)
        let originX = centreX - m.width / 2
        minX = min(minX, originX); maxX = max(maxX, originX + m.width)

        for run in (CTLineGetGlyphRuns(m.line) as! [CTRun]) {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var ids = [CGGlyph](repeating: 0, count: count)
            var pos = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &ids)
            CTRunGetPositions(run, CFRangeMake(0, count), &pos)
            for k in 0..<count {
                // Core Text's y is up from the baseline; ours is down from the
                // top of the canvas, so the run's own y offset is subtracted.
                glyphs.append(PlacedGlyph(glyph: ids[k],
                                          x: originX + pos[k].x,
                                          y: baseline - pos[k].y))
            }
        }
    }
    guard !glyphs.isEmpty else { return nil }
    if minX > maxX { minX = centreX; maxX = centreX }
    return TextLayout(font: font, glyphs: glyphs,
                      bounds: CGRect(x: minX, y: top,
                                     width: maxX - minX, height: blockHeight))
}

// MARK: - the raster backend

/// Draw type onto a copy of `base`.
///
/// Glyphs go through Core Graphics rather than being composed by hand, and
/// that is the one deliberate exception to this file's neighbours. Everything
/// else here avoids CG because its antialiasing and premultiplication are not
/// ours to control — but *type must be antialiased*, hinting and subpixel
/// positioning are exactly what a text renderer is for, and hand-rasterising
/// glyph outlines to avoid CG would be reimplementing the thing badly.
///
/// The result is un-premultiplied on the way back, the same as `Raster.load`,
/// and composited over the base in straight alpha — so an edge that passes
/// through the disc mask afterwards does not darken.
public func drawText(_ base: Raster, _ spec: TextSpec, canvas: Int) -> Raster {
    guard let layout = layoutText(spec, canvas: canvas),
          let layer = renderGlyphLayer(layout, colour: spec.colour, canvas: canvas)
    else { return base }
    return over(layer, base)
}

/// The type alone, on transparency.
private func renderGlyphLayer(_ layout: TextLayout, colour: RGB, canvas: Int) -> Raster? {
    let w = canvas, h = canvas
    var premul = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = premul.withUnsafeMutableBytes({ buf -> CGContext? in
        CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                  bytesPerRow: w * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    // Greyscale, not subpixel: subpixel antialiasing bakes the background's
    // colour into the edge pixels, and this layer's background is nothing at
    // all. On transparency it produces coloured fringes.
    ctx.setShouldSmoothFonts(false)
    ctx.setFillColor(red: Double(colour.r) / 255, green: Double(colour.g) / 255,
                     blue: Double(colour.b) / 255, alpha: 1)

    // The context is y-up; the layout is y-down.
    let ids = layout.glyphs.map(\.glyph)
    let points = layout.glyphs.map { CGPoint(x: $0.x, y: Double(h) - $0.y) }
    CTFontDrawGlyphs(layout.font, ids, points, ids.count, ctx)

    // CGBitmapContext cannot produce non-premultiplied output at all, so it is
    // undone here — the same trick, and the same reason, as Raster.load.
    var out = Raster(empty: w, height: h)
    for i in stride(from: 0, to: premul.count, by: 4) {
        let a = premul[i + 3]
        guard a > 0 else { continue }
        let f = 255.0 / Double(a)
        out.px[i] = UInt8(min(255, (Double(premul[i]) * f).rounded()))
        out.px[i + 1] = UInt8(min(255, (Double(premul[i + 1]) * f).rounded()))
        out.px[i + 2] = UInt8(min(255, (Double(premul[i + 2]) * f).rounded()))
        out.px[i + 3] = a
    }
    return out
}

/// Source-over, in straight (non-premultiplied) alpha.
func over(_ top: Raster, _ bottom: Raster) -> Raster {
    guard top.width == bottom.width, top.height == bottom.height else { return bottom }
    var out = bottom
    for i in stride(from: 0, to: out.px.count, by: 4) {
        let ta = Double(top.px[i + 3]) / 255
        guard ta > 0 else { continue }
        if ta >= 1 {
            out.px[i] = top.px[i]; out.px[i + 1] = top.px[i + 1]
            out.px[i + 2] = top.px[i + 2]; out.px[i + 3] = 255
            continue
        }
        let ba = Double(bottom.px[i + 3]) / 255
        let a = ta + ba * (1 - ta)
        for c in 0..<3 {
            let v = (Double(top.px[i + c]) * ta + Double(bottom.px[i + c]) * ba * (1 - ta)) / a
            out.px[i + c] = UInt8(v.rounded().clamped(0, 255))
        }
        out.px[i + 3] = UInt8((a * 255).rounded().clamped(0, 255))
    }
    return out
}

// MARK: - the vector backend

/// The type as SVG **paths**, not as `<text>`.
///
/// `<text font-family="…">` is smaller and stays editable, and it renders as a
/// different picture — or not at all — on a machine that does not have the
/// font. This app already refuses to export a near-miss (a gradient on a
/// non-circular mask says so rather than approximating), and type is the case
/// where a near-miss is most visible. Paths always match what was on screen,
/// need no font installed, and are what a drawing tool exports.
public func textAsSVGPaths(_ spec: TextSpec, canvas: Int) -> String? {
    guard let layout = layoutText(spec, canvas: canvas) else { return nil }
    var d = ""
    for g in layout.glyphs {
        // Glyph outlines are y-up from the baseline; d: -1 flips them, and the
        // translation puts the baseline origin where the layout said.
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: g.x, ty: g.y)
        guard let path = CTFontCreatePathForGlyph(layout.font, g.glyph, &t) else { continue }
        d += svgPathData(path)
    }
    guard !d.isEmpty else { return nil }
    // Non-zero winding, which is what a glyph's counters are drawn for: the
    // hole in an "o" is wound the other way, and even-odd would also punch
    // holes wherever two letters overlap.
    return #"<path fill-rule="nonzero" fill="\#(svgHex(spec.colour))" d="\#(d)"/>"#
}

/// A `CGPath` as SVG path data.
func svgPathData(_ path: CGPath) -> String {
    var out = ""
    path.applyWithBlock { elementPtr in
        let e = elementPtr.pointee
        let p = e.points
        switch e.type {
        case .moveToPoint:
            out += "M\(f(p[0].x)),\(f(p[0].y))"
        case .addLineToPoint:
            out += "L\(f(p[0].x)),\(f(p[0].y))"
        case .addQuadCurveToPoint:
            out += "Q\(f(p[0].x)),\(f(p[0].y)) \(f(p[1].x)),\(f(p[1].y))"
        case .addCurveToPoint:
            out += "C\(f(p[0].x)),\(f(p[0].y)) \(f(p[1].x)),\(f(p[1].y)) \(f(p[2].x)),\(f(p[2].y))"
        case .closeSubpath:
            out += "Z"
        @unknown default:
            break
        }
    }
    return out
}

func svgHex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", c.r, c.g, c.b) }
