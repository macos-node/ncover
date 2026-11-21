import Foundation
import Testing

@testable import NCoverKit

// Convert: PNG → JPEG under the same stem, for ndisc's `ncover:convert` lines.
//
// Built here before the GTK sibling has it — a deliberate divergence, recorded
// in docs/gtk-parity-plan.md. The rules it adds are the ones the sibling will
// have to answer too, so they are written down as tests rather than as code
// that happens to behave this way.

private func tmpdir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("ncover-convert-\(name)")
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func opaque(_ w: Int, _ h: Int) -> Raster {
    var r = Raster(empty: w, height: h)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = 200; r.px[i + 1] = 40; r.px[i + 2] = 90; r.px[i + 3] = 255
    }
    return r
}

@Suite("convert")
struct ConvertTests {

    @Test func itTakesNdiscsConvertLinesAndNoOthers() {
        #expect(BatchJob.convert.listAction == "ncover:convert")
        #expect(BatchJob.convert.name == "Convert")
        // Not a keep-format job: the file it writes is not the file it read.
        // It does keep the name, which is what puts it in `keepDest`'s family.
        #expect(!BatchJob.convert.keepsFile)
        #expect(BatchJob.convert.keepsName)
        #expect(BatchJob.convert.writes == .jpeg)
    }

    @Test func aPngBecomesAJpgUnderTheSameStemAndAJpegIsLeftAlone() throws {
        let base = tmpdir("names")
        let lib = base.appendingPathComponent("lib/A/One")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let png = lib.appendingPathComponent("cover.png")
        let jpg = lib.appendingPathComponent("back.jpg")
        try opaque(600, 600).writePNG(to: png)
        try opaque(600, 600).writeJPEG(to: jpg)

        #expect(wouldChange(png, job: .convert, canvas: 600))
        #expect(!wouldChange(jpg, job: .convert, canvas: 600), "already a JPEG: nothing to convert")

        let out = base.appendingPathComponent("out")
        let plan = planDests(rels: ["A/One/cover.png"], outRoot: out, job: .convert, disc: false)
        #expect(try plan[0].get().path == out.appendingPathComponent("A/One/cover.jpg").path)
        #expect(try batchWriteFormat(dest: try plan[0].get(), job: .convert) == .jpeg)

        // The whole job, through the same calls the runner makes.
        let made = try #require(try batchRender(try Raster.load(contentsOf: png),
                                                recipe: Recipe(canvas: 600, job: .convert, disc: nil)))
        #expect((made.width, made.height) == (600, 600), "not one pixel changes")
        let dest = try plan[0].get()
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try made.write(to: dest, as: .jpeg, alpha: BatchJob.convert.alphaRule)
        #expect(ImageFormat.of(dest) == .jpeg)
        #expect(imageSize(of: dest).map { [$0.width, $0.height] } == [600, 600])
        #expect(try Data(contentsOf: dest).count < (try Data(contentsOf: png).count),
                "the point of the exercise")
    }

    @Test func atransparentPngIsRefusedRatherThanStoredAsBlack() throws {
        // The defining rule. A label logo on a transparent background is the
        // usual `ncover:convert` line, and ImageIO drops the channel and keeps
        // the RGB — which `Raster.load` has already zeroed. No layer errors.
        #expect(BatchJob.convert.alphaRule == .refuse)
        #expect(BatchJob.cap.alphaRule == .discard, "a JPEG source had no alpha to lose")

        let base = tmpdir("alpha")
        var logo = opaque(64, 64)
        logo.set(0, 0, RGBA(0, 0, 0, 0))
        let dest = base.appendingPathComponent("logo.jpg")
        #expect(throws: (any Error).self) {
            try logo.write(to: dest, as: .jpeg, alpha: BatchJob.convert.alphaRule)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path), "and nothing is written")
    }

    @Test func adiscAndConvertAreRefusedTogether() {
        // A JPEG has no room for a disc's transparent corners, which is the
        // keep-format jobs' rule asked of the format Convert writes.
        #expect(jobRefusal(job: .convert, disc: true) != nil)
        #expect(jobRefusal(job: .convert, disc: false) == nil)
        #expect(jobRefusal(job: .frame(.cover), disc: true) == nil)
    }

    @Test func convertIsRefusedIntoTheLibraryBecauseItRenamesTheFile() throws {
        // `cover.jpg` beside a `cover.png` is two covers in one release and
        // ndisc still pointing at the old one. Replacing in place means
        // removing the PNG, which the shared log cannot record yet — so it is
        // refused here rather than invented on one side.
        let base = tmpdir("library")
        let lib = base.appendingPathComponent("lib/A/One")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let png = lib.appendingPathComponent("cover.png")
        try opaque(600, 600).writePNG(to: png)
        let wb = try WriteBack.start(keptRoot: base.appendingPathComponent("originals"))
        #expect(throws: WriteBackError.notAKeepFormatJob("Convert")) {
            _ = try wb.one(source: png, place: "A/One/cover.png",
                           recipe: Recipe(canvas: 600, job: .convert, disc: nil))
        }
        #expect(try Data(contentsOf: png).count > 0, "and the library file is untouched")
    }

    @Test func thenoOpsClaimNoNameSoTheRealWorkIsNotRefusedAsAClash() throws {
        // `cover.jpg` is left alone and `cover.png` beside it becomes
        // `cover.jpg`. Planning both would refuse the real work as a clash
        // with the no-op, so only the files the run would write claim a name.
        let out = URL(fileURLWithPath: "/out")
        let both = planDests(rels: ["A/cover.jpg", "A/cover.png"], outRoot: out,
                             job: .convert, disc: false)
        #expect(try both[0].get().lastPathComponent == "cover.jpg")
        #expect(throws: BatchError.self) { _ = try both[1].get() }

        // Which is why the runner plans only what it will write — the claim
        // the no-op would have made is the one that has to go.
        let onlyTheWork = planDests(rels: ["A/cover.png"], outRoot: out, job: .convert, disc: false)
        #expect(try onlyTheWork[0].get().path == "/out/A/cover.jpg")
    }

    @Test func theplanSaysWhatItWouldDoToEachFile() throws {
        let base = tmpdir("plan")
        let lib = base.appendingPathComponent("lib/A/One")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let png = lib.appendingPathComponent("cover.png")
        try opaque(600, 538).writePNG(to: png)
        try opaque(600, 538).writeJPEG(to: lib.appendingPathComponent("back.jpg"))

        let scope = BatchScope.folder(base.appendingPathComponent("lib"))
        let files = findImages(in: scope, needle: "")
        let plan = planItems(files: files, scope: scope,
                             recipe: Recipe(canvas: 600, job: .convert, disc: nil))
        #expect(plan.map(\.url.lastPathComponent) == ["cover.png"],
                "the JPEG is not in the plan, so it is not in the Run button's count")
        #expect(plan[0].words == "600 × 538 · PNG → JPEG",
                "two equal sizes and an arrow would say nothing")
    }
}
