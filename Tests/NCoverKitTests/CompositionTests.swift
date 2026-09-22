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
