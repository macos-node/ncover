import Foundation
import Testing

@testable import NCoverKit

// The build operations that are neither placement nor masking. New here rather
// than ported — the GTK app has `blank_canvas`, `invert_rgb` and `stamp_square`
// but no tests over them, so these assert what *this* app does and the GTK side
// is free to be checked against them rather than the other way round.

private func transparent(_ n: Int) -> Raster { Raster(empty: n, height: n) }

@Suite("build operations")
struct BuildOperationTests {
    @Test func aBlankCanvasIsOpaqueWhiteThroughout() {
        let r = blankCanvas(8)
        #expect(r.sample(0, 0) == RGBA(255, 255, 255, 255))
        #expect(r.sample(7, 7) == RGBA(255, 255, 255, 255))
    }

    @Test func invertLeavesAlphaAlone() {
        var r = transparent(2)
        r.set(0, 0, RGBA(10, 20, 30, 128))
        let out = invertRGB(r)
        #expect(out.sample(0, 0) == RGBA(245, 235, 225, 128))
        // A transparent pixel inverts its colour and stays transparent. If
        // alpha were inverted, every empty corner would become opaque black.
        #expect(out.sample(1, 1).a == 0)
    }

    @Test func aStampedSquareIsCentredAndOpaque() {
        // Half of a 100 canvas: a 50px square from 25 to 74 inclusive.
        let out = stampSquare(transparent(100), frac: 0.5, colour: RGB(1, 2, 3))
        #expect(out.sample(50, 50) == RGBA(1, 2, 3, 255))
        #expect(out.sample(25, 25) == RGBA(1, 2, 3, 255), "the first pixel inside")
        #expect(out.sample(74, 74) == RGBA(1, 2, 3, 255), "the last pixel inside")
        #expect(out.sample(24, 50).a == 0, "one pixel outside is untouched")
        #expect(out.sample(50, 75).a == 0)
    }

    @Test func theSquareStampsOverTransparentGround() {
        // Opaque on purpose: a label mark is solid, not a tint, and on a
        // transparent canvas a blended stamp would come out as nothing at all.
        let out = stampSquare(transparent(10), frac: 1, colour: RGB(9, 9, 9))
        #expect(out.sample(0, 0) == RGBA(9, 9, 9, 255))
    }

    @Test func anEmptySquareIsANoOpNotAnError() {
        let base = blankCanvas(10)
        #expect(stampSquare(base, frac: 0, colour: .black) == base)
        // And out-of-range is clamped rather than crashing on a bad slider.
        #expect(stampSquare(base, frac: 4, colour: .black).sample(0, 0) == RGBA(0, 0, 0, 255))
    }

    @Test func theSquareHasAVectorFormAndIsDrawnOnTopOfWhatCameBefore() {
        var d = Composition(
            source: Source(raster: blankCanvas(10),
                           vector: VectorSource(svg: "<svg width=\"10\" height=\"10\"></svg>",
                                                width: 10, height: 10)),
            canvas: 100)
        d.setPlacement(Placement(dx: 0, dy: 0, scale: 10))
        d.ops.append(.square(frac: 0.5, colour: RGB(255, 0, 0)))
        #expect(d.vectorRefusal == nil, "a filled rect is expressible")
        let svg = renderVector(d)
        #expect(svg != nil)
        // 50px square inset 25 on a 100 canvas, and *after* the nested source
        // in document order, which is what "drawn on top" means in SVG.
        #expect(svg!.contains(##"<rect x="25" y="25" width="50" height="50" fill="#ff0000"/>"##))
        let rectAt = svg!.range(of: ##"fill="#ff0000""##)!.lowerBound
        let nestedAt = svg!.range(of: "<svg", options: .backwards)!.lowerBound
        #expect(nestedAt < rectAt, "the square must come after the artwork")
    }

    @Test func invertAndSquareBothSurviveIntoTheStepList() {
        var d = Composition(source: Source(raster: blankCanvas(10)), canvas: 10)
        d.ops = [.invert, .square(frac: 0.6, colour: .black)]
        #expect(d.ops.map(\.label) == ["Invert", "Square (60%)"])
    }
}
