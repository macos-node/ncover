import Foundation
import Testing

@testable import NCoverKit

// The plan: every file a run would touch, numbered and in review order.
// Phase D of docs/gtk-parity-plan.md.

private func tmpdir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("ncover-plan-\(name)")
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func flat(_ w: Int, _ h: Int) -> Raster {
    var r = Raster(empty: w, height: h)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = 150; r.px[i + 1] = 80; r.px[i + 2] = 40; r.px[i + 3] = 255
    }
    return r
}

/// A library of covers at given sizes, as `Artist/Album/cover.jpg`.
private func library(_ dir: URL, _ covers: [(String, Int, Int)]) throws -> URL {
    let lib = dir.appendingPathComponent("library")
    for (album, w, h) in covers {
        let d = lib.appendingPathComponent("Artist/\(album)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try flat(w, h).writeJPEG(to: d.appendingPathComponent("cover.jpg"))
    }
    return lib
}

@Suite("the plan")
struct PlanTests {
    @Test func aframingPlansEveryFileInRunOrder() throws {
        let lib = try library(tmpdir("frame"), [("B", 300, 300), ("A", 900, 900), ("C", 600, 538)])
        let scope = BatchScope.folder(lib)
        let items = planItems(files: findImages(in: scope, needle: ""), scope: scope,
                              recipe: Recipe(canvas: 400, framing: .cover, disc: nil))
        #expect(items.count == 3, "a framing reframes everything, however it started")
        #expect(items.map(\.number) == [1, 2, 3], "1-based and contiguous")
        #expect(items.map { $0.rel } == ["Artist/A/cover.jpg", "Artist/B/cover.jpg",
                                         "Artist/C/cover.jpg"],
                "by path, which is the order the run goes in")
        #expect(items.allSatisfy { $0.to == PixelSize(width: 400, height: 400) })
    }

    @Test func capPlansOnlyWhatIsOverTheCapLargestFirst() throws {
        let lib = try library(tmpdir("cap"),
                             [("Small", 300, 300), ("Big", 1800, 1800),
                              ("Mid", 700, 700), ("Exact", 400, 400)])
        let scope = BatchScope.folder(lib)
        let items = planItems(files: findImages(in: scope, needle: ""), scope: scope,
                              recipe: Recipe(canvas: 400, job: .cap, disc: nil))
        // The files it would leave alone are not in the plan at all — which is
        // what makes the plan's length the Run button's count.
        #expect(items.map { $0.url.deletingLastPathComponent().lastPathComponent }
                == ["Big", "Mid"], "largest first, and nothing within the cap")
        #expect(items[0].from == PixelSize(width: 1800, height: 1800))
        #expect(items[0].to == PixelSize(width: 400, height: 400))
        #expect(items[0].words == "1800 × 1800 → 400 × 400")
    }

    @Test func squarePlansTheLeastSquareFirst() throws {
        let lib = try library(tmpdir("square"),
                             [("Nearly", 600, 590), ("Wide", 1000, 500),
                              ("Square", 600, 600), ("Off", 600, 500)])
        let scope = BatchScope.folder(lib)
        let items = planItems(files: findImages(in: scope, needle: ""), scope: scope,
                              recipe: Recipe(canvas: 400, job: .square, disc: nil))
        #expect(items.map { $0.url.deletingLastPathComponent().lastPathComponent }
                == ["Wide", "Off", "Nearly"],
                "worst first: 50% off, then 17%, then 2% — and never the square one")
        // Pad reviews in the same order: both are about how off-square it is.
        let padded = planItems(files: findImages(in: scope, needle: ""), scope: scope,
                               recipe: Recipe(canvas: 400, job: .pad(.edge), disc: nil))
        #expect(padded.map(\.rel) == items.map(\.rel))
        #expect(padded[0].words.contains("added"), "Pad adds bars where Square takes a crop")
        #expect(items[0].words.contains("off"))
    }

    @Test func theplansLengthIsTheRunButtonsCount() throws {
        // Said twice in the app — the counter asks `wouldChange` over the
        // files, the grid is this list — so a test ties them together. Two
        // numbers that are supposed to be the same number, from two code
        // paths, is how "Run (245 of 2,377)" stops being true.
        let lib = try library(tmpdir("agree"),
                             [("A", 1800, 1800), ("B", 300, 300), ("C", 600, 538),
                              ("D", 400, 400), ("E", 900, 600)])
        let scope = BatchScope.folder(lib)
        let files = findImages(in: scope, needle: "")
        for job in [BatchJob.cap, .square, .pad(.edge), .frame(.cover), .frame(.fit)] {
            let items = planItems(files: files, scope: scope,
                                  recipe: Recipe(canvas: 400, job: job, disc: nil))
            let counted = files.filter { wouldChange($0, job: job, canvas: 400) }.count
            #expect(items.count == counted, "\(job.name): the grid and the count disagree")
        }
    }

    @Test func areleaseIsNamedByTheRecordEvenFromASubfolder() throws {
        // The manifest and the list both know "Artist — Title", and a cover
        // can sit in a disc subfolder below the release root. Falling back to
        // the path would lose the name for exactly those releases.
        let base = tmpdir("names")
        let lib = base.appendingPathComponent("library")
        let release = lib.appendingPathComponent("Autechre/Amber")
        let disc2 = release.appendingPathComponent("Disc 2")
        try FileManager.default.createDirectory(at: disc2, withIntermediateDirectories: true)
        try flat(900, 900).writeJPEG(to: release.appendingPathComponent("cover.jpg"))
        try flat(900, 900).writeJPEG(to: disc2.appendingPathComponent("cover.jpg"))

        let scope = BatchScope(roots: [release], strip: lib, guardRoot: lib,
                               names: [release.standardizedFileURL.path: "Autechre — Amber"])
        let items = planItems(files: findImages(in: scope, needle: ""), scope: scope,
                              recipe: Recipe(canvas: 400, job: .cap, disc: nil))
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.name == "Autechre — Amber" },
                "including the one in Disc 2")

        // With no name on record, the folder within the scope is the answer —
        // not the whole absolute path.
        let plain = BatchScope.folder(lib)
        let bare = planItems(files: [release.appendingPathComponent("cover.jpg")],
                             scope: plain, recipe: Recipe(canvas: 400, job: .cap, disc: nil))
        #expect(bare[0].name == "Autechre/Amber")
    }

    @Test func afileWithNoPixelSizeIsPlannedOnlyByAFraming() throws {
        let dir = tmpdir("vector")
        let svg = dir.appendingPathComponent("logo.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>"#.utf8)
            .write(to: svg)
        let scope = BatchScope.folder(dir)

        // Nothing to cap or square: a vector has no pixel size to compare.
        #expect(planItems(files: [svg], scope: scope,
                          recipe: Recipe(canvas: 400, job: .cap, disc: nil)).isEmpty)
        // A framing renders it onto the canvas like anything else, and says so
        // with no "from" size rather than guessing one.
        let framed = planItems(files: [svg], scope: scope,
                               recipe: Recipe(canvas: 400, framing: .fit, disc: nil))
        #expect(framed.count == 1)
        #expect(framed[0].to == PixelSize(width: 400, height: 400))
        #expect(framed[0].words.isEmpty, "no size to compare, so no sentence about it")
    }

    @Test func offSquareIsAFractionOfTheLongerSide() {
        #expect(PixelSize(width: 600, height: 600).isSquare)
        #expect(PixelSize(width: 600, height: 600).offSquare == 0)
        #expect(abs(PixelSize(width: 1000, height: 500).offSquare - 0.5) < 0.0001)
        #expect(abs(PixelSize(width: 500, height: 1000).offSquare - 0.5) < 0.0001,
                "tall and wide are equally off square")
        #expect(PixelSize(width: 600, height: 538).long == 600)
    }
}
