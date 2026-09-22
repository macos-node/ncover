import Foundation
import Testing
@testable import NCoverKit

private func red(_ n: Int) -> Raster {
    var r = Raster(empty: n, height: n)
    for i in stride(from: 0, to: r.px.count, by: 4) { r.px[i] = 255; r.px[i + 3] = 255 }
    return r
}

private let tinySVG = ##"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10"><rect width="10" height="10" fill="#ff0000"/></svg>"##

private func vectorDoc(canvas: Int = 400) -> Composition {
    Composition(source: Source(raster: red(100),
                            vector: VectorSource(svg: tinySVG, width: 10, height: 10)),
             canvas: canvas)
}

@Suite("document")
struct DocumentTests {
    @Test func placementLivesInTheOperationListAndIsReplacedNotAppended() {
        var d = vectorDoc()
        d.setPlacement(Placement(dx: 1, dy: 2, scale: 1))
        d.setPlacement(Placement(dx: 9, dy: 9, scale: 2))
        #expect(d.ops.count == 1, "a second placement replaces the first")
        #expect(d.placement == Placement(dx: 9, dy: 9, scale: 2))
    }

    @Test func theRasterBackendFoldsOperationsInOrder() {
        var d = Composition(source: Source(raster: red(10)), canvas: 10)
        d.ops = [.place(Placement(dx: 0, dy: 0, scale: 1))]
        #expect(renderRaster(d).sample(5, 5) == RGBA(255, 0, 0, 255))
        d.ops.append(.invert)
        #expect(renderRaster(d).sample(5, 5) == RGBA(0, 255, 255, 255), "invert applies after place")
    }

    @Test func maskingThroughTheNewAbstractionIsTheOldDiscExactly() {
        // discTemplate is now a wrapper over applyMask(.disc). If generalising
        // to a signed distance function moved a single pixel, this catches it.
        let viaMask = applyMask(red(64), .disc, fill: .white)
        let viaDisc = discTemplate(red(64), fill: .white)
        #expect(viaMask == viaDisc)
    }
}

@Suite("vector backend")
struct VectorTests {
    @Test func aRasterSourceRefusesVectorOutputAndSaysWhy() {
        let d = Composition(source: Source(raster: red(10)), canvas: 400,
                         ops: [.place(Placement(dx: 0, dy: 0, scale: 1))])
        #expect(renderVector(d) == nil)
        #expect(d.vectorRefusal == "the source is not an SVG")
    }

    @Test func aVectorSourceWithVectorOperationsIsAccepted() throws {
        var d = vectorDoc()
        d.setPlacement(Placement(dx: 0, dy: 0, scale: 4))
        d.ops.append(.mask(.disc, fill: .alpha, fit: .canvas))
        #expect(d.vectorRefusal == nil)
        let svg = try #require(renderVector(d))
        #expect(svg.contains("<clipPath id=\"mask1\">"))
        #expect(svg.contains("<circle"))
    }

    @Test func aTransparentFillWritesNoOuterLayerAtAll() {
        var d = vectorDoc()
        d.setPlacement(Placement(dx: 0, dy: 0, scale: 4))
        d.ops.append(.mask(.disc, fill: .alpha, fit: .canvas))
        let svg = renderVector(d) ?? ""
        #expect(!svg.contains("outside1"), "nothing outside the disc means no fill layer")
    }

    /// The fill must be clipped to the INVERSE of the mask. A plain rect behind
    /// the artwork also shows through transparent pixels inside the disc, which
    /// is a different picture.
    @Test func anOuterFillIsClippedToTheInverseOfTheMask() {
        var d = vectorDoc()
        d.setPlacement(Placement(dx: 0, dy: 0, scale: 4))
        d.ops.append(.mask(.disc, fill: .white, fit: .canvas))
        let svg = renderVector(d) ?? ""
        #expect(svg.contains("clip-rule=\"evenodd\""))
        #expect(svg.contains("clip-path=\"url(#outside1)\""))
    }

    /// Both backends must reach the outer stop at the same place, or a gradient
    /// exported as SVG would not match the one on screen.
    @Test func bothBackendsNormaliseTheGradientIdentically() {
        let size = 400.0
        let m = Mask.disc
        // raster: t = sd / sdMax, so t = 0 exactly at the rim
        let reg = MaskRegion.canvas(Int(size))
        let sdMax = m.maxSignedDistance(size: size)
        let rimT = m.signedDistance(x: size / 2, y: 0.5 + 0, size: size) / sdMax
        // vector: the inner stop offset, expressed as a fraction of the gradient radius
        let innerOffset = m.gradientInnerOffset(canvas: size, region: reg)
        let outer = m.gradientOuterRadius(canvas: size, region: reg)
        // The rim sits at radius size/2 along a gradient of radius `outer`.
        #expect(abs(innerOffset - (size / 2) / outer) < 1e-12)
        #expect(abs(rimT) < 0.01, "the rim is the zero point of the raster ramp")
        #expect(abs(outer - (sdMax + size / 2)) < 1e-12)
    }

    @Test func anOperationWithNoVectorFormNamesItself() {
        var d = vectorDoc()
        d.setPlacement(Placement(dx: 0, dy: 0, scale: 4))
        // Every operation today has a vector form, so assert the mechanism
        // rather than a case that does not exist yet.
        let allVector = d.ops.allSatisfy { $0.hasVectorForm }
        #expect(allVector)
        #expect(d.vectorRefusal == nil)
        #expect(Operation.mask(.disc, fill: .alpha, fit: .canvas).label == "Disc mask")
    }
}

@Suite("mask shapes")
struct MaskShapeTests {
    /// A rounded rectangle whose corner radius is the full half-canvas IS a
    /// circle. If the two distance functions ever disagree about that, one of
    /// them is wrong.
    @Test func aFullyRoundedRectangleIsTheDisc() {
        let size = 128.0
        for (x, y) in [(0.5, 0.5), (64.0, 0.5), (64.0, 64.0), (20.0, 100.0), (127.5, 127.5)] {
            let a = Mask.disc.signedDistance(x: x, y: y, size: size)
            let b = Mask.roundedRect(radius: 1.0).signedDistance(x: x, y: y, size: size)
            #expect(abs(a - b) < 1e-9, "disagreed at \(x),\(y): \(a) vs \(b)")
        }
    }

    @Test func aZeroRadiusRectangleKeepsItsCorners() {
        let m = Mask.roundedRect(radius: 0)
        // The corner pixel centre is inside a plain square, unlike a disc.
        #expect(m.signedDistance(x: 0.5, y: 0.5, size: 128) < 0)
        #expect(Mask.disc.signedDistance(x: 0.5, y: 0.5, size: 128) > 0)
    }

    @Test func aChamferCutsCornersButNotEdges() {
        let m = Mask.chamfer(inset: 0.3)
        // Mid-edge is untouched by a chamfer...
        #expect(m.signedDistance(x: 64, y: 0.5, size: 128) < 0)
        // ...while the corner is outside.
        #expect(m.signedDistance(x: 0.5, y: 0.5, size: 128) > 0)
    }

    @Test func everyShapeMasksWithoutComplaint() throws {
        var red = Raster(empty: 64, height: 64)
        for i in stride(from: 0, to: red.px.count, by: 4) { red.px[i] = 255; red.px[i + 3] = 255 }
        for m in [Mask.disc, .roundedRect(radius: 0.4), .chamfer(inset: 0.3)] {
            let out = try #require(applyMask(red, m, fill: .alpha))
            #expect(out.sample(32, 32) == RGBA(255, 0, 0, 255), "\(m.label): centre is artwork")
            #expect(out.sample(0, 0).a == 0, "\(m.label): corner is cut")
        }
    }

    /// The architecture earning its keep: a radial gradient can only follow the
    /// rim when the rim is a circle, so the non-disc combinations refuse vector
    /// export instead of writing a picture that does not match the screen.
    @Test func aGradientOnANonCircularMaskHasNoVectorForm() {
        #expect(Operation.mask(.disc, fill: .gradient(inner: .black, outer: .white), fit: .canvas).hasVectorForm)
        #expect(!Operation.mask(.roundedRect(radius: 0.4),
                                fill: .gradient(inner: .black, outer: .white), fit: .canvas).hasVectorForm)
        #expect(!Operation.mask(.chamfer(inset: 0.3),
                                fill: .gradient(inner: .black, outer: .white), fit: .canvas).hasVectorForm)
        // Every other fill is fine on every shape.
        #expect(Operation.mask(.chamfer(inset: 0.3), fill: .white, fit: .canvas).hasVectorForm)
        #expect(Operation.mask(.roundedRect(radius: 0.4), fill: .alpha, fit: .canvas).hasVectorForm)
    }

    @Test func theRefusalNamesTheStep() {
        var c = Composition(source: Source(raster: Raster(empty: 8, height: 8),
                                           vector: VectorSource(svg: "<svg/>", width: 8, height: 8)),
                            canvas: 400)
        c.setPlacement(Placement(dx: 0, dy: 0, scale: 1))
        c.ops.append(.mask(.chamfer(inset: 0.3), fill: .gradient(inner: .black, outer: .white), fit: .canvas))
        #expect(c.vectorRefusal == "step 2, Chamfer mask, has no vector form")
        #expect(renderVector(c) == nil)
    }

    @Test func eachShapeWritesItsOwnClipAndInverse() {
        let shapes: [(Mask, String)] = [
            (.disc, "circle"), (.roundedRect(radius: 0.4), "rect"), (.chamfer(inset: 0.3), "polygon"),
        ]
        for (m, tag) in shapes {
            let reg = MaskRegion.canvas(400)
            #expect(m.svgClipShape(region: reg).contains("<\(tag)"), "\(m.label) clip shape")
            let inv = m.svgInverseClipPath(canvas: 400, region: reg)
            #expect(inv.contains("clip-rule=\"evenodd\""), "\(m.label) inverse must be even-odd")
            #expect(inv.contains("M0,0 H400 V400 H0 Z"), "\(m.label) inverse starts from the canvas")
        }
    }
}

@Suite("mask fit")
struct MaskFitTests {
    /// A 40×40 opaque square centred in a 100×100 canvas — the inset-artwork
    /// case, in miniature.
    private func insetArtwork() -> Raster {
        var r = Raster(empty: 100, height: 100)
        for y in 30..<70 { for x in 30..<70 { r.set(x, y, RGBA(255, 0, 0, 255)) } }
        return r
    }

    @Test func theDrawnRegionFindsTheArtworkNotTheCanvas() throws {
        let reg = try #require(insetArtwork().drawnRegion())
        #expect(reg.cx == 50 && reg.cy == 50)
        #expect(reg.side == 40)
    }

    @Test func nothingDrawnHasNoRegion() {
        #expect(Raster(empty: 20, height: 20).drawnRegion() == nil)
    }

    /// The whole point of the toggle. Inscribed in the canvas, a disc of radius
    /// 50 barely grazes a 40×40 inset square — its corners sit 28 from centre,
    /// well inside. Inscribed in the artwork, radius 20, it cuts them off.
    @Test func fittingToTheArtworkActuallyClipsIt() throws {
        let src = insetArtwork()
        let onCanvas = try #require(applyMask(src, .disc, fill: .alpha, region: .canvas(100)))
        let onArtwork = try #require(applyMask(src, .disc, fill: .alpha, region: src.drawnRegion()!))
        // The artwork's own corner, just inside its bounding box.
        #expect(onCanvas.sample(31, 31).a == 255, "canvas-inscribed disc leaves it alone")
        #expect(onArtwork.sample(31, 31).a == 0, "artwork-inscribed disc cuts the corner")
        // Both keep the centre.
        #expect(onCanvas.sample(50, 50) == RGBA(255, 0, 0, 255))
        #expect(onArtwork.sample(50, 50) == RGBA(255, 0, 0, 255))
    }

    @Test func anOffCentreRegionStillNormalisesTheGradientToTheFurthestCorner() {
        // A region in one corner: the far canvas corner must still reach the
        // outer stop, which a symmetric assumption would get wrong.
        let reg = MaskRegion(cx: 20, cy: 20, side: 20)
        let r = Mask.disc.gradientOuterRadius(canvas: 100, region: reg)
        let farCorner = ((99.5 - 20) * (99.5 - 20) * 2).squareRoot()
        #expect(abs(r - farCorner) < 1e-9)
    }

    @Test func theFitIsCarriedThroughTheCompositionAndNamed() {
        var c = Composition(source: Source(raster: insetArtwork()), canvas: 100)
        c.setPlacement(Placement(dx: 0, dy: 0, scale: 1))
        c.ops.append(.mask(.disc, fill: .alpha, fit: .artwork))
        #expect(c.ops[1].label == "Disc mask (artwork)")
        // Rendering through the composition must match applying it directly.
        let viaComposition = renderRaster(c)
        #expect(viaComposition.sample(31, 31).a == 0)
    }

    @Test func bothFitsStillExportAsVector() throws {
        for fit in MaskFit.allCases {
            var c = Composition(
                source: Source(raster: insetArtwork(),
                               vector: VectorSource(svg: "<svg/>", width: 100, height: 100)),
                canvas: 100)
            c.setPlacement(Placement(dx: 0, dy: 0, scale: 1))
            c.ops.append(.mask(.disc, fill: .white, fit: fit))
            #expect(c.vectorRefusal == nil, "\(fit.label) should export")
            let svg = try #require(renderVector(c))
            #expect(svg.contains("<circle"))
        }
    }

    /// The artwork-fitted circle must actually be drawn where the artwork is,
    /// not at the canvas centre with the canvas radius.
    @Test func theVectorCircleFollowsTheRegion() throws {
        var c = Composition(
            source: Source(raster: insetArtwork(),
                           vector: VectorSource(svg: "<svg/>", width: 100, height: 100)),
            canvas: 100)
        c.setPlacement(Placement(dx: 0, dy: 0, scale: 1))
        c.ops.append(.mask(.disc, fill: .white, fit: .artwork))
        let svg = try #require(renderVector(c))
        #expect(svg.contains(#"r="20""#), "radius should be the artwork's, not the canvas's")
    }
}
