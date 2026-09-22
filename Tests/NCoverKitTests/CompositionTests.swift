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
        d.ops.append(.mask(.disc, fill: .alpha))
        #expect(d.vectorRefusal == nil)
        let svg = try #require(renderVector(d))
        #expect(svg.contains("<clipPath id=\"mask1\">"))
        #expect(svg.contains("<circle"))
    }

    @Test func aTransparentFillWritesNoOuterLayerAtAll() {
        var d = vectorDoc()
        d.setPlacement(Placement(dx: 0, dy: 0, scale: 4))
        d.ops.append(.mask(.disc, fill: .alpha))
        let svg = renderVector(d) ?? ""
        #expect(!svg.contains("outside1"), "nothing outside the disc means no fill layer")
    }

    /// The fill must be clipped to the INVERSE of the mask. A plain rect behind
    /// the artwork also shows through transparent pixels inside the disc, which
    /// is a different picture.
    @Test func anOuterFillIsClippedToTheInverseOfTheMask() {
        var d = vectorDoc()
        d.setPlacement(Placement(dx: 0, dy: 0, scale: 4))
        d.ops.append(.mask(.disc, fill: .white))
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
        let sdMax = m.maxSignedDistance(size: size)
        let rimT = m.signedDistance(x: size / 2, y: 0.5 + 0, size: size) / sdMax
        // vector: the inner stop offset, expressed as a fraction of the gradient radius
        let innerOffset = m.gradientInnerOffset(size: size)
        let outer = m.gradientOuterRadius(size: size)
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
        #expect(Operation.mask(.disc, fill: .alpha).label == "Disc mask")
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
        #expect(Operation.mask(.disc, fill: .gradient(inner: .black, outer: .white)).hasVectorForm)
        #expect(!Operation.mask(.roundedRect(radius: 0.4),
                                fill: .gradient(inner: .black, outer: .white)).hasVectorForm)
        #expect(!Operation.mask(.chamfer(inset: 0.3),
                                fill: .gradient(inner: .black, outer: .white)).hasVectorForm)
        // Every other fill is fine on every shape.
        #expect(Operation.mask(.chamfer(inset: 0.3), fill: .white).hasVectorForm)
        #expect(Operation.mask(.roundedRect(radius: 0.4), fill: .alpha).hasVectorForm)
    }

    @Test func theRefusalNamesTheStep() {
        var c = Composition(source: Source(raster: Raster(empty: 8, height: 8),
                                           vector: VectorSource(svg: "<svg/>", width: 8, height: 8)),
                            canvas: 400)
        c.setPlacement(Placement(dx: 0, dy: 0, scale: 1))
        c.ops.append(.mask(.chamfer(inset: 0.3), fill: .gradient(inner: .black, outer: .white)))
        #expect(c.vectorRefusal == "step 2, Chamfer mask, has no vector form")
        #expect(renderVector(c) == nil)
    }

    @Test func eachShapeWritesItsOwnClipAndInverse() {
        let shapes: [(Mask, String)] = [
            (.disc, "circle"), (.roundedRect(radius: 0.4), "rect"), (.chamfer(inset: 0.3), "polygon"),
        ]
        for (m, tag) in shapes {
            #expect(m.svgClipShape(size: 400).contains("<\(tag)"), "\(m.label) clip shape")
            let inv = m.svgInverseClipPath(size: 400)
            #expect(inv.contains("clip-rule=\"evenodd\""), "\(m.label) inverse must be even-odd")
            #expect(inv.contains("M0,0 H400 V400 H0 Z"), "\(m.label) inverse starts from the canvas")
        }
    }
}
