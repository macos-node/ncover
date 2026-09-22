import Foundation
import Testing
@testable import NCoverKit

// These are ported from the GTK app's own suite, deliberately keeping the
// original test names. They are the contract between the two apps: where both
// still claim to do the same thing, these must agree. When the macOS app
// diverges on purpose, delete the test rather than weaken it.

// MARK: - disc

/// A solid red square, n×n, fully opaque.
private func red(_ n: Int) -> Raster {
    var r = Raster(empty: n, height: n)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = 255; r.px[i + 3] = 255
    }
    return r
}

@Suite("disc")
struct DiscTests {
    @Test func alphaFillLeavesTheCornersActuallyTransparent() throws {
        let out = try #require(discTemplate(red(64), fill: .alpha))
        #expect(out.sample(0, 0).a == 0, "corner must be fully transparent")
        #expect(out.sample(32, 32) == RGBA(255, 0, 0, 255), "centre is the artwork")
    }

    @Test func whiteFillPutsWhiteInTheCornersNotTransparency() throws {
        let out = try #require(discTemplate(red(64), fill: .white))
        #expect(out.sample(0, 0) == RGBA(255, 255, 255, 255))
        #expect(out.sample(32, 32) == RGBA(255, 0, 0, 255))
    }

    @Test func solidFillUsesTheColourGiven() throws {
        let out = try #require(discTemplate(red(64), fill: .solid(RGB(0, 0, 255))))
        #expect(out.sample(0, 0) == RGBA(0, 0, 255, 255))
    }

    @Test func gradientRunsFromTheRimOutward() throws {
        let out = try #require(discTemplate(red(64), fill: .gradient(inner: .black, outer: .white)))
        #expect(out.sample(0, 0) == RGBA(255, 255, 255, 255), "corner is the OUTER stop")
        // An INSCRIBED disc touches the canvas edges, so there is no "outside"
        // at the mid-edge — pixel (63,32) IS the rim. The fill only exists in
        // the four corners. Sample along the diagonal, just outside the rim.
        #expect(out.sample(6, 6).r < 128, "just past the rim should be near the inner stop")
    }

    @Test func aNonSquareSourceIsCoveredNotLetterboxed() throws {
        // A disc with bars through it is not a disc. A 128x64 source must fill
        // the square canvas, cropping the long axis rather than padding.
        var wide = Raster(empty: 128, height: 64)
        for i in stride(from: 0, to: wide.px.count, by: 4) {
            wide.px[i + 1] = 255; wide.px[i + 3] = 255
        }
        let out = try #require(discTemplate(wide, fill: .alpha))
        #expect(out.width == 128 && out.height == 128)
        #expect(out.sample(64, 4) == RGBA(0, 255, 0, 255), "top-centre is inside the disc")
    }
}

// MARK: - placement

@Suite("placement")
struct PlacementTests {
    @Test func coverCentresAndFillsTheCanvas() {
        // A wide source scaled so the SHORT axis reaches across, centred, with
        // the overhang split evenly.
        let p = Placement.cover(sw: 200, sh: 100, canvas: 400)
        #expect(p.scale == 4.0)
        #expect(p.dy == 0)
        #expect(p.dx == -200)
    }

    @Test func fitPutsTheWholeImageInside() {
        let p = Placement.fit(sw: 200, sh: 100, canvas: 400)
        #expect(p.scale == 2.0)
        #expect(p.dx == 0)
        #expect(p.dy == 100)
    }

    @Test func snapsToCentre() {
        let p = Placement(dx: 96, dy: 96, scale: 1)
        let r = snap(p, sw: 200, sh: 200, canvas: 400)
        #expect(r.placement.dx == 100 && r.placement.dy == 100)
        #expect(r.snappedX && r.snappedY)
    }

    @Test func doesNotSnapBeyondTheThreshold() {
        let p = Placement(dx: 80, dy: 80, scale: 1)
        let r = snap(p, sw: 200, sh: 200, canvas: 400)
        #expect(r.placement == p)
        #expect(!r.snappedX && !r.snappedY)
    }

    @Test func snapsEachAxisIndependently() {
        // Snapped horizontally, free vertically — a guide, not a magnet.
        let p = Placement(dx: 2, dy: 80, scale: 1)
        let r = snap(p, sw: 200, sh: 200, canvas: 400)
        #expect(r.placement.dx == 0)
        #expect(r.placement.dy == 80)
        #expect(r.snappedX && !r.snappedY)
    }

    @Test func rescalingDoesNotRecrop() {
        // Changing output size must not re-crop what you already framed.
        let p = Placement.cover(sw: 300, sh: 200, canvas: 400)
        let big = p.rescaled(from: 400, to: 1000)
        #expect(abs(big.scale - p.scale * 2.5) < 1e-9)
        #expect(abs(big.dx - p.dx * 2.5) < 1e-9)
    }

    @Test func composePlacesTheImageWhereYouPutIt() {
        let src = red(10)
        let out = compose(src, Placement(dx: 5, dy: 5, scale: 1), canvas: 20)
        #expect(out.sample(0, 0).a == 0, "outside the placed image is transparent")
        #expect(out.sample(7, 7) == RGBA(255, 0, 0, 255))
        #expect(out.sample(19, 19).a == 0)
    }
}

// MARK: - guards

@Suite("write guards")
struct GuardTests {
    @Test func refusesOutputEqualToSource() {
        let d = URL(fileURLWithPath: "/tmp/lib")
        #expect(throws: WriteGuardError.outputIsSource) { try guardBatch(source: d, output: d) }
    }

    @Test func refusesOutputNestedInsideSource() {
        #expect(throws: WriteGuardError.outputInsideSource) {
            try guardBatch(source: URL(fileURLWithPath: "/tmp/lib"),
                           output: URL(fileURLWithPath: "/tmp/lib/out"))
        }
    }

    @Test func allowsASiblingOutput() throws {
        try guardBatch(source: URL(fileURLWithPath: "/tmp/lib"),
                       output: URL(fileURLWithPath: "/tmp/out"))
    }

    @Test func overwriteRefusesAnythingButPNG() {
        #expect(throws: WriteGuardError.overwriteNotPNG("jpg")) {
            try guardOverwrite(source: URL(fileURLWithPath: "/tmp/a/cover.jpg"))
        }
        #expect(throws: Never.self) {
            try guardOverwrite(source: URL(fileURLWithPath: "/tmp/a/cover.PNG"))
        }
    }
}

// MARK: - round trip

@Suite("png round trip")
struct PNGTests {
    @Test func survivesAWriteAndReadWithAlphaIntact() throws {
        let out = try #require(discTemplate(red(64), fill: .alpha))
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ncover-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try out.writePNG(to: tmp)
        let back = try Raster.load(contentsOf: tmp)
        #expect(back.width == 64 && back.height == 64)
        #expect(back.sample(0, 0).a == 0, "a transparent corner must survive the file")
        #expect(back.sample(32, 32) == RGBA(255, 0, 0, 255))
    }
}

// MARK: - drag

@Suite("drag")
struct DragTests {
    /// Regression: the first macOS build accumulated per-frame deltas onto the
    /// *snapped* placement, so a slow drag could never leave a snap zone — each
    /// frame was pulled back and the motion in between discarded. Anchoring
    /// fixes it. This is the test that would have caught it.
    @Test func aSlowDragEscapesTheSnapZone() {
        let anchor = Placement(dx: 100, dy: 100, scale: 1)   // centred on a 400 canvas
        var last = anchor
        // Twenty frames of two points each: forty points total, well past the
        // ten-pixel threshold, but never more than two in a single frame.
        for frame in 1...20 {
            let r = resolveDrag(anchor: anchor,
                                translationX: Double(frame) * 2, translationY: 0,
                                viewScale: 1, sw: 200, sh: 200, canvas: 400)
            last = r.placement
        }
        #expect(last.dx == 140, "a slow drag must accumulate from the anchor, not the snapped value")
    }

    @Test func holdsWhileInsideTheSnapZone() {
        let anchor = Placement(dx: 100, dy: 100, scale: 1)
        let r = resolveDrag(anchor: anchor, translationX: 4, translationY: 0,
                            viewScale: 1, sw: 200, sh: 200, canvas: 400)
        #expect(r.placement.dx == 100, "four points in, the centre guide still holds it")
        #expect(r.snappedX)
    }

    @Test func translationIsDividedByTheViewScale() {
        // A canvas drawn at half size must move the image twice as far per point,
        // or it lags the cursor.
        let anchor = Placement(dx: 0, dy: 0, scale: 1)
        let r = resolveDrag(anchor: anchor, translationX: 50, translationY: 0,
                            viewScale: 0.5, sw: 10, sh: 10, canvas: 400)
        #expect(r.placement.dx == 100)
    }

    @Test func aZeroViewScaleIsRefusedRatherThanDividedBy() {
        let anchor = Placement(dx: 7, dy: 7, scale: 1)
        let r = resolveDrag(anchor: anchor, translationX: 50, translationY: 50,
                            viewScale: 0, sw: 10, sh: 10, canvas: 400)
        #expect(r.placement == anchor)
    }
}
