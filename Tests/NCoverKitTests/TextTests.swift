import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import NCoverKit

// Type. New here — the GTK app has no text operation, so there is no oracle
// and these assert what this app does.
//
// The one that matters most is `bothBackendsAgreeOnWhereTheGlyphsAre`: raster
// and vector share `layoutText` precisely so they cannot drift, and a test
// that ties them together numerically is what keeps that true.

private let face = "Helvetica"

private func spec(_ s: String = "EG", size: Double = 0.4) -> TextSpec {
    TextSpec(string: s, font: face, size: size, colour: .black)
}

@Suite("type")
struct TextTests {
    @Test func layoutCentresTheBlockOnTheGivenPoint() throws {
        let l = try #require(layoutText(spec(), canvas: 400))
        #expect(l.bounds.midX == 200, "x centres on 0.5")
        #expect(abs(l.bounds.midY - 200) < 0.001, "y centres on 0.5")
        #expect(l.glyphs.count == 2)
        // Glyph origins sit on the baseline, which is below the block's top.
        #expect(l.glyphs.allSatisfy { $0.y > l.bounds.minY })
    }

    @Test func sizeIsAFractionOfTheCanvasSoTypeScalesWithIt() throws {
        let small = try #require(layoutText(spec(size: 0.4), canvas: 200))
        let large = try #require(layoutText(spec(size: 0.4), canvas: 400))
        // Twice the canvas, twice the type. Points would have left the same
        // lettering stranded in the corner of a 1000px square.
        #expect(abs(large.bounds.width / small.bounds.width - 2) < 0.01)
    }

    @Test func trackingWidensTheLine() throws {
        let tight = try #require(layoutText(spec(), canvas: 400))
        var wide = spec(); wide.tracking = 0.3
        let loose = try #require(layoutText(wide, canvas: 400))
        #expect(loose.bounds.width > tight.bounds.width)
        #expect(loose.bounds.midX == tight.bounds.midX, "it widens about the centre")
    }

    @Test func aSecondLineStacksBelowTheFirst() throws {
        let one = try #require(layoutText(spec("E"), canvas: 400))
        let two = try #require(layoutText(spec("E\nG"), canvas: 400))
        #expect(two.bounds.height > one.bounds.height)
        #expect(abs(two.bounds.midY - 200) < 0.001, "the block, not the first line, is centred")
        // Two lines, and the second's baseline is below the first's.
        let ys = Set(two.glyphs.map(\.y))
        #expect(ys.count == 2)
    }

    @Test func nothingToSetIsNotAnError() {
        #expect(layoutText(spec(""), canvas: 400) == nil)
        #expect(layoutText(spec(), canvas: 0) == nil)
        // And drawing it leaves the canvas exactly as it was.
        let base = blankCanvas(10)
        #expect(drawText(base, spec(""), canvas: 10) == base)
    }

    @Test func typeActuallyMarksTheCanvas() {
        // Big enough that the centre of a 200 canvas is certainly inside a
        // glyph, whatever Helvetica does with the metrics.
        var s = spec("████", size: 0.5)
        s.colour = RGB(255, 0, 0)
        let out = drawText(blankCanvas(200), s, canvas: 200)
        #expect(out.sample(100, 100) != RGBA(255, 255, 255, 255), "something was drawn")
        #expect(out.sample(2, 2) == RGBA(255, 255, 255, 255), "the corner is untouched")
    }

    @Test func typeOverTransparencyKeepsItsAlphaRatherThanGoingOpaque() {
        var s = spec("████", size: 0.5)
        s.colour = RGB(0, 0, 0)
        let out = drawText(Raster(empty: 200, height: 200), s, canvas: 200)
        #expect(out.sample(2, 2).a == 0, "outside the type is still nothing")
        #expect(out.sample(100, 100).a > 0, "inside it is not")
    }

    @Test func theColourIsTheColourAsked() {
        var s = spec("████", size: 0.5)
        s.colour = RGB(10, 200, 30)
        let out = drawText(blankCanvas(200), s, canvas: 200)
        let px = out.sample(100, 100)
        // Fully covered pixels carry the colour exactly; an antialiased edge
        // would not, which is why this samples the middle of a solid block.
        #expect(px == RGBA(10, 200, 30, 255))
    }

    @Test func bothBackendsAgreeOnWhereTheGlyphsAre() throws {
        // The whole reason `layoutText` exists. The vector backend turns the
        // same PlacedGlyphs into paths, so the SVG's first move-to must land
        // on the first glyph's own origin, within the glyph's bounding box.
        let s = spec("E", size: 0.4)
        let l = try #require(layoutText(s, canvas: 400))
        let svg = try #require(textAsSVGPaths(s, canvas: 400))

        let g = l.glyphs[0]
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: g.x, ty: g.y)
        let path = try #require(CTFontCreatePathForGlyph(l.font, g.glyph, &t))
        let box = path.boundingBox
        // The glyph's drawn box must sit on the baseline the layout chose:
        // an upper-case E rises above it and does not descend below it.
        #expect(box.maxY <= g.y + 1)
        #expect(box.minY < g.y)
        #expect(abs(box.minX - g.x) < g.y, "the path starts near the glyph origin")

        // And the SVG carries that same geometry, flipped the same way.
        #expect(svg.contains("fill-rule=\"nonzero\""))
        #expect(svg.contains("fill=\"#000000\""))
        let firstY = Double(svg.split(separator: "M")[1]
            .split(separator: ",")[1]
            .prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })) ?? -1
        #expect(abs(firstY - box.maxY) < box.height + 1,
                "the first point is inside the glyph's own box, not mirrored off it")
    }

    @Test func theVectorFormIsPathsNotAFontReference() throws {
        let svg = try #require(textAsSVGPaths(spec(), canvas: 400))
        // <text font-family="…"> would render as a different picture, or not
        // at all, on a machine without the font. Outlines always match.
        #expect(!svg.contains("<text"))
        #expect(!svg.contains("font-family"))
        #expect(svg.contains("<path"))
    }

    @Test func typeHasAVectorFormAndIsDrawnOverWhatCameBefore() throws {
        var d = Composition(source: blankSource(200), canvas: 200)
        d.setPlacement(Placement(dx: 0, dy: 0, scale: 1))
        d.ops.append(.text(spec()))
        #expect(d.vectorRefusal == nil, "outlines are expressible")
        let svg = try #require(renderVector(d))
        let pathAt = try #require(svg.range(of: "<path"))
        let nestedAt = try #require(svg.range(of: "<svg", options: .backwards))
        #expect(nestedAt.lowerBound < pathAt.lowerBound, "type comes after the artwork")
    }

    @Test func aBlankCanvasCanBeSavedAsSVG() {
        // This is what makes type worth having: a composition built from
        // nothing used to be refused for "the source is not an SVG", even
        // though every step in it had a perfectly good vector form.
        var d = Composition(source: blankSource(400), canvas: 400)
        d.setPlacement(Placement(dx: 0, dy: 0, scale: 1))
        d.ops.append(.text(spec()))
        d.ops.append(.mask(.disc, fill: .alpha, fit: .canvas))
        #expect(d.vectorRefusal == nil)
        #expect(renderVector(d) != nil)
    }

    @Test func aBlankSourceIsWhiteInBothForms() {
        let s = blankSource(50)
        #expect(s.raster.sample(25, 25) == RGBA(255, 255, 255, 255))
        #expect(s.isVector)
        #expect(s.vector!.svg.contains("#ffffff"))
    }

    @Test func theStepListNamesTheWords() {
        #expect(Operation.text(spec("EG")).label == "Text “EG”")
        #expect(Operation.text(spec("two\nlines")).label == "Text “two lines”")
        // A long line is cut rather than filling the inspector.
        #expect(Operation.text(spec("an extremely long title indeed")).label.count <= 22)
    }

    @Test func aMissingFontIsReportedRatherThanSubstitutedSilently() {
        #expect(fontIsAvailable("Helvetica"))
        #expect(!fontIsAvailable("NoSuchFontExistsHere"))
    }

    @Test func sourceOverLeavesTheBottomWhereTheTopIsTransparent() {
        var top = Raster(empty: 2, height: 1)
        top.set(0, 0, RGBA(255, 0, 0, 255))
        var bottom = Raster(empty: 2, height: 1)
        bottom.set(0, 0, RGBA(0, 0, 255, 255))
        bottom.set(1, 0, RGBA(0, 255, 0, 255))
        let out = over(top, bottom)
        #expect(out.sample(0, 0) == RGBA(255, 0, 0, 255), "opaque top wins")
        #expect(out.sample(1, 0) == RGBA(0, 255, 0, 255), "transparent top changes nothing")
    }
}
