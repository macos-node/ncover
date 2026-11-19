import Foundation
import Testing

@testable import NCoverKit

// The keep-format jobs. Phase B of docs/gtk-parity-plan.md.
//
// The property every one of these is really about: a job that keeps the file
// must write NOTHING for a file it would not change, and the counter and the
// run must decide that from the same arithmetic. Everything else follows.

private func tmpdir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("ncover-jobs-\(name)")
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A raster of one colour, opaque unless told otherwise.
private func flat(_ w: Int, _ h: Int, _ c: RGBA = RGBA(120, 60, 30, 255)) -> Raster {
    var r = Raster(empty: w, height: h)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = c.r; r.px[i + 1] = c.g; r.px[i + 2] = c.b; r.px[i + 3] = c.a
    }
    return r
}

@Suite("keep-format jobs")
struct JobTests {
    // MARK: - what each job would change

    @Test func capShrinksOnlyWhatIsOverTheCapAndKeepsItsShape() {
        // The longer side becomes exactly the cap; the other follows.
        #expect(capSize(2048, 2048, cap: 400).map { [$0.width, $0.height] } == [400, 400])
        #expect(capSize(1000, 500, cap: 400).map { [$0.width, $0.height] } == [400, 200])
        #expect(capSize(500, 1000, cap: 400).map { [$0.width, $0.height] } == [200, 400])
        // Already within it: nothing, which is how "writes nothing" is said.
        #expect(capSize(400, 400, cap: 400) == nil)
        #expect(capSize(300, 120, cap: 400) == nil)
        // A rounding floor, so a very wide image keeps at least one pixel.
        #expect(capSize(4000, 3, cap: 400).map { [$0.width, $0.height] } == [400, 1])
    }

    @Test func squareAndPadLeaveASquareImageAloneHoweverLargeItIs() {
        // Squaring is what they do; capping is Cap's job. A 2048² cover is
        // already square, so a Square run must not rewrite it — and if it did,
        // "Run (247 of 247 to square)" over a library would be meaningless.
        #expect(jobResultSize(width: 2048, height: 2048, job: .square, canvas: 400) == nil)
        #expect(jobResultSize(width: 2048, height: 2048, job: .pad(.edge), canvas: 400) == nil)
        // Off-square: Square takes the shorter side, Pad the longer, and both
        // then shrink to the cap.
        #expect(jobResultSize(width: 600, height: 538, job: .square, canvas: 400)
                .map { [$0.width, $0.height] } == [400, 400])
        #expect(jobResultSize(width: 600, height: 538, job: .pad(.edge), canvas: 400)
                .map { [$0.width, $0.height] } == [400, 400])
        // Off-square and already small: squared, not shrunk.
        #expect(jobResultSize(width: 300, height: 260, job: .square, canvas: 400)
                .map { [$0.width, $0.height] } == [260, 260])
        #expect(jobResultSize(width: 300, height: 260, job: .pad(.white), canvas: 400)
                .map { [$0.width, $0.height] } == [300, 300])
    }

    @Test func aFramingAlwaysWritesAndNeverKeepsTheFile() {
        #expect(!BatchJob.frame(.cover).keepsFile)
        #expect(!BatchJob.frame(.fit).keepsFile)
        #expect(BatchJob.cap.keepsFile)
        #expect(BatchJob.square.keepsFile)
        #expect(BatchJob.pad(.edge).keepsFile)
        // Cover reframes every file onto the canvas, so there is no such thing
        // as a file it would leave alone.
        #expect(jobResultSize(width: 400, height: 400, job: .frame(.cover), canvas: 400)
                .map { [$0.width, $0.height] } == [400, 400])
    }

    @Test func squareAndPadAnswerOneListLineAndCapItsOwn() {
        // ndisc says a cover is off-square; whether to crop or pad is the
        // operator's choice per run, so both jobs take the same lines.
        #expect(BatchJob.square.listAction == "ncover:square")
        #expect(BatchJob.pad(.edge).listAction == "ncover:square")
        #expect(BatchJob.cap.listAction == "ncover:cap")
        #expect(BatchJob.frame(.cover).listAction == nil)
    }

    // MARK: - the pixels

    @Test func squareCropsTheCentreOfTheLongSide() {
        // A 10×6 with a marked middle column: the crop keeps the middle.
        var src = flat(10, 6)
        for y in 0..<6 { src.set(5, y, RGBA(0, 255, 0, 255)) }
        let out = try! #require(jobRender(src, job: .square, canvas: 400))
        #expect(out.width == 6 && out.height == 6)
        // The source x of the kept column: x0 = (10-6)/2 = 2, so source 5 is
        // output 3.
        #expect(out.sample(3, 0) == RGBA(0, 255, 0, 255), "the marked column survived")
        #expect(out.sample(0, 0) == RGBA(120, 60, 30, 255))
    }

    @Test func padAddsBarsAndKeepsEveryPixelOfTheSource() {
        let src = flat(10, 6, RGBA(200, 0, 0, 255))
        let out = try! #require(jobRender(src, job: .pad(.white), canvas: 400))
        #expect(out.width == 10 && out.height == 10, "a square of the LONGER side")
        // y0 = (10-6)/2 = 2: the bars are rows 0–1 and 8–9.
        #expect(out.sample(5, 0) == RGBA(255, 255, 255, 255), "top bar")
        #expect(out.sample(5, 9) == RGBA(255, 255, 255, 255), "bottom bar")
        #expect(out.sample(5, 5) == RGBA(200, 0, 0, 255), "the picture, untouched")
    }

    @Test func padsEdgeFillReadsTheEdgeBesideEachBar() {
        // Each bar is the average of the row it sits against, so a cover with
        // a sky at the top and a floor at the bottom gets both.
        var src = flat(8, 4, RGBA(10, 10, 10, 255))
        for x in 0..<8 { src.set(x, 0, RGBA(0, 0, 200, 255)) }      // top row blue
        for x in 0..<8 { src.set(x, 3, RGBA(0, 200, 0, 255)) }      // bottom row green
        let out = try! #require(jobRender(src, job: .pad(.edge), canvas: 400))
        #expect(out.width == 8 && out.height == 8)
        #expect(out.sample(4, 0) == RGBA(0, 0, 200, 255), "top bar from the top row")
        #expect(out.sample(4, 7) == RGBA(0, 200, 0, 255), "bottom bar from the bottom row")
    }

    @Test func atransparentLogoGetsTransparentBars() {
        // The reason `edge` averages in premultiplied space and keeps the mean
        // alpha: bars that are grey instead of absent would be visible on
        // every background.
        let src = Raster(empty: 10, height: 6)    // wholly transparent
        let out = try! #require(jobRender(src, job: .pad(.edge), canvas: 400))
        #expect(out.sample(5, 0).a == 0, "the bar is as transparent as the edge was")
    }

    @Test func aSquareImageComesBackUntouchedRatherThanReencoded() {
        // jobRender answers nil, which the runner reports as "left alone" and
        // writes nothing for. A re-encode of an unchanged JPEG would lose
        // quality for no reason at all.
        #expect(jobRender(flat(400, 400), job: .square, canvas: 400) == nil)
        #expect(jobRender(flat(400, 400), job: .pad(.edge), canvas: 400) == nil)
        #expect(jobRender(flat(300, 200), job: .cap, canvas: 400) == nil)
    }

    @Test func capShrinksWithTheAreaAveragingResampler() throws {
        // Not the nearest-pixel sampler: shrinking a cover by point-sampling
        // breaks up halftones and thin type. A checkerboard averages to its
        // mean; nearest-neighbour would return one of the two colours.
        var src = Raster(empty: 400, height: 400)
        for y in 0..<400 {
            for x in 0..<400 {
                src.set(x, y, (x + y) % 2 == 0 ? RGBA(0, 0, 0, 255) : RGBA(255, 255, 255, 255))
            }
        }
        let out = try #require(jobRender(src, job: .cap, canvas: 100))
        #expect(out.width == 100 && out.height == 100)
        let px = out.sample(50, 50)
        #expect(abs(Int(px.r) - 128) <= 2, "averaged, not sampled")
    }

    // MARK: - refusals

    @Test func adiscAndAKeepFormatJobAreRefusedTogether() {
        // A JPEG has no alpha, so there is nowhere for a disc's corners to go.
        #expect(jobRefusal(job: .cap, disc: true) != nil)
        #expect(jobRefusal(job: .square, disc: true)?.contains("Square") == true)
        #expect(jobRefusal(job: .pad(.edge), disc: true) != nil)
        // No disc, or a framing: nothing to refuse.
        #expect(jobRefusal(job: .square, disc: false) == nil)
        #expect(jobRefusal(job: .frame(.cover), disc: true) == nil)
    }

    @Test func aformatWeDoNotWriteIsLeftAsItIsAndNamed() throws {
        let out = URL(fileURLWithPath: "/tmp/out")
        // The framings always write a PNG, whatever came in.
        #expect(try batchWriteFormat(dest: batchDest(rel: "a/cover.webp", outRoot: out,
                                                     disc: false),
                                     job: .frame(.cover)) == .png)
        // A keep-format job cannot: refused by name rather than converted.
        #expect(try batchWriteFormat(dest: keepDest(rel: "a/cover.jpg", outRoot: out),
                                     job: .cap) == .jpeg)
        #expect(try batchWriteFormat(dest: keepDest(rel: "a/cover.png", outRoot: out),
                                     job: .square) == .png)
        #expect(throws: BatchError.keepFormatUnsupported("webp")) {
            try batchWriteFormat(dest: keepDest(rel: "a/cover.webp", outRoot: out), job: .cap)
        }
        #expect(throws: BatchError.keepFormatUnsupported("gif")) {
            try batchWriteFormat(dest: keepDest(rel: "a/cover.gif", outRoot: out), job: .pad(.edge))
        }
    }

    // MARK: - destinations

    @Test func akeepFormatJobWritesTheSourcesOwnNameAndExtension() {
        let out = URL(fileURLWithPath: "/tmp/out")
        #expect(keepDest(rel: "Autechre/Amber/cover.jpg", outRoot: out).path
                == "/tmp/out/Autechre/Amber/cover.jpg")
        #expect(keepDest(rel: "cover.PNG", outRoot: out).path == "/tmp/out/cover.PNG")
    }

    @Test func thetwoCoversThatCollideUnderCoverDoNotCollideUnderCap() throws {
        // Under the PNG family these two plan one `cover.png` and have to be
        // told apart. Under a keep-format job they are already apart — they
        // differ by the very extension they keep — so the disambiguation does
        // not fire and the names stay exactly as they were.
        let out = URL(fileURLWithPath: "/tmp/out")
        let rels = ["Autechre/Amber/cover.jpg", "Autechre/Amber/cover.png"]

        let framed = planDests(rels: rels, outRoot: out, job: .frame(.cover), disc: false)
        #expect(try framed[0].get().lastPathComponent == "cover-jpg.png")
        #expect(try framed[1].get().lastPathComponent == "cover-png.png")

        let capped = planDests(rels: rels, outRoot: out, job: .cap, disc: false)
        #expect(try capped[0].get().lastPathComponent == "cover.jpg")
        #expect(try capped[1].get().lastPathComponent == "cover.png")
    }

    // MARK: - the header read and the render agree

    @Test func thecountAndTheRunDecideTheSameThing() throws {
        // "Run (245 of 2,377 to shrink)" is a promise. The counter asks
        // `wouldChange` from a header; the run asks `jobRender` from the
        // decoded pixels. They must never disagree about one file.
        let dir = tmpdir("agree")
        let cases: [(String, Raster, BatchJob, Bool)] = [
            ("big.png",    flat(900, 900), .cap,        true),
            ("small.png",  flat(300, 300), .cap,        false),
            ("wide.jpg",   flat(600, 538), .square,     true),
            ("sq.jpg",     flat(500, 500), .square,     false),
            ("wide2.png",  flat(600, 538), .pad(.edge), true),
            ("sq2.png",    flat(500, 500), .pad(.edge), false),
        ]
        for (name, raster, job, expected) in cases {
            let url = dir.appendingPathComponent(name)
            if ImageFormat.of(url) == .jpeg {
                try raster.writeJPEG(to: url)
            } else {
                try raster.writePNG(to: url)
            }
            let fromHeader = wouldChange(url, job: job, canvas: 400)
            let fromPixels = jobRender(try Raster.load(contentsOf: url),
                                       job: job, canvas: 400) != nil
            #expect(fromHeader == expected, "\(name): the header says the wrong thing")
            #expect(fromHeader == fromPixels, "\(name): header and render disagree")
        }
    }

    @Test func afileWithNoPixelSizeIsLeftAlone() throws {
        // An SVG has no native size and nothing to cap; a text file is not an
        // image at all. Neither is a failure — there is simply nothing to do.
        let dir = tmpdir("nosize")
        let svg = dir.appendingPathComponent("logo.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#.utf8).write(to: svg)
        #expect(!wouldChange(svg, job: .cap, canvas: 400))
        #expect(!wouldChange(dir.appendingPathComponent("gone.png"), job: .square, canvas: 400))
        // A framing, by contrast, reframes anything it can open.
        #expect(wouldChange(svg, job: .frame(.cover), canvas: 400))
    }

    // MARK: - words

    @Test func thesizeChangeReadsAsWhatHappenedToTheFile() {
        #expect(sizeChangeInWords(from: (600, 533), to: (533, 533), job: .square)
                == "600 × 533 → 533 × 533 · 67 px off the sides (11%)")
        #expect(sizeChangeInWords(from: (600, 538), to: (600, 600), job: .pad(.edge))
                == "600 × 538 → 600 × 600 · 62 px added top and bottom")
        #expect(sizeChangeInWords(from: (2048, 2048), to: (400, 400), job: .cap)
                == "2048 × 2048 → 400 × 400")
        // The case that made this take the job: padded to 1000², then capped
        // to 400². It ends up smaller than it started, and from the sizes
        // alone that reads as a crop — which is the opposite of what happened.
        #expect(sizeChangeInWords(from: (1000, 500), to: (400, 400), job: .pad(.edge))
                == "1000 × 500 → 400 × 400 · 500 px added top and bottom")
        #expect(sizeChangeInWords(from: (1000, 500), to: (400, 400), job: .square)
                == "1000 × 500 → 400 × 400 · 500 px off the sides (50%)")
        // A tall image loses its sides to a crop and gains them to a pad.
        #expect(sizeChangeInWords(from: (500, 1000), to: (500, 500), job: .square)
                == "500 × 1000 → 500 × 500 · 500 px off top and bottom (50%)")
        #expect(sizeChangeInWords(from: (500, 1000), to: (1000, 1000), job: .pad(.white))
                == "500 × 1000 → 1000 × 1000 · 500 px added left and right")
    }

    // MARK: - end to end, on real files

    @Test func acapRunKeepsTheFormatAndWritesOnlyWhatItChanges() throws {
        let base = tmpdir("caprun")
        let src = base.appendingPathComponent("library")
        let out = base.appendingPathComponent("out")
        let release = src.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)

        // One over the cap, one under it, and both JPEGs — the shape a real
        // library is mostly made of.
        try flat(900, 900, RGBA(0, 160, 0, 255)).writeJPEG(to: release.appendingPathComponent("cover.jpg"))
        try flat(300, 300, RGBA(0, 0, 200, 255)).writeJPEG(to: release.appendingPathComponent("back.jpg"))

        let scope = BatchScope.folder(src)
        try guardBatch(source: scope.guardRoot, output: out)
        let hits = findImages(in: scope, needle: "")
        let rels = hits.map { relativePath(of: $0, under: scope.strip) }
        let recipe = Recipe(canvas: 400, job: .cap, disc: nil)
        let plan = planDests(rels: rels, outRoot: out, job: recipe.job, disc: false)

        var wrote: [String] = []
        for ((hit, rel), planned) in zip(zip(hits, rels), plan) {
            let dest = try planned.get()
            let format = try batchWriteFormat(dest: dest, job: recipe.job)
            guard let made = try batchRender(try Raster.load(contentsOf: hit),
                                             recipe: recipe) else { continue }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try made.write(to: dest, as: format, alpha: .discard)
            wrote.append(rel)
        }

        #expect(wrote == ["Artist/Album/cover.jpg"], "only the one over the cap")
        let written = out.appendingPathComponent("Artist/Album/cover.jpg")
        #expect(imageSize(of: written).map { [$0.width, $0.height] } == [400, 400])
        #expect(ImageFormat.of(written) == .jpeg, "a JPEG went in and a JPEG came out")
        #expect(!FileManager.default.fileExists(
            atPath: out.appendingPathComponent("Artist/Album/back.jpg").path),
            "the file it would not change was not written at all")
        // And the originals are exactly as they were.
        #expect(imageSize(of: release.appendingPathComponent("cover.jpg"))
                .map { [$0.width, $0.height] } == [900, 900])
    }
}
