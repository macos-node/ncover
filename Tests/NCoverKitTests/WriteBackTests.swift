import Foundation
import Testing

@testable import NCoverKit

// Writing a run back into the library: phase F1 of docs/gtk-parity-plan.md.
//
// The names are the GTK sibling's test names, as the repo asks — wherever
// both still claim to do the same thing, both must agree.

private func tmpdir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("ncover-writeback-\(name)")
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func jpeg(_ url: URL, _ w: Int, _ h: Int, _ c: RGBA = RGBA(51, 102, 153, 255)) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    var r = Raster(empty: w, height: h)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = c.r; r.px[i + 1] = c.g; r.px[i + 2] = c.b; r.px[i + 3] = 255
    }
    try r.writeJPEG(to: url)
}

private func png(_ url: URL, _ w: Int, _ h: Int, _ c: RGBA = RGBA(51, 102, 153, 255),
                 transparentCorner: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    var r = Raster(empty: w, height: h)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = c.r; r.px[i + 1] = c.g; r.px[i + 2] = c.b; r.px[i + 3] = 255
    }
    if transparentCorner { r.set(0, 0, RGBA(0, 0, 0, 0)) }
    try r.writePNG(to: url)
}

private func square() -> Recipe { Recipe(canvas: 600, job: .square, disc: nil) }

private func place(_ f: URL, under lib: URL) throws -> String {
    try #require(placeUnder(f, strip: lib))
}

private func names(in dir: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
}

@Suite("write-back")
struct WriteBackTests {

    @Test func asquareRunReplacesTheCoverKeepsTheOriginalAndLogsIt() throws {
        let base = tmpdir("swap")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let cover = lib.appendingPathComponent("Autechre/Amber/cover.jpg")
        try jpeg(cover, 600, 538)
        let before = try Data(contentsOf: cover)

        let wb = try WriteBack.start(keptRoot: kept)
        let got = try wb.one(source: cover, place: try place(cover, under: lib), recipe: square())

        let k = kept.appendingPathComponent("Autechre/Amber/cover.jpg")
        #expect(got?.path == k.path)
        #expect(try Data(contentsOf: k) == before, "the original is kept byte for byte")
        #expect(imageSize(of: cover).map { [$0.width, $0.height] } == [538, 538],
                "the library file is the result")
        #expect(cover.pathExtension == "jpg" && ImageFormat.of(cover) == .jpeg,
                "its own name and its own format")

        let log = try String(contentsOf: kept.appendingPathComponent(WRITEBACK_LOG), encoding: .utf8)
        #expect(log.components(separatedBy: .newlines).filter { $0.hasPrefix("swap\t") }.count == 1)
        #expect(log.contains("\tsquare\t") && log.contains("600x538\t538x538"))
        #expect(try lastRun(in: kept)?.swaps == 1)
        // No temp file left in either place.
        for d in [cover.deletingLastPathComponent(), k.deletingLastPathComponent()] {
            #expect(!names(in: d).contains { $0.hasSuffix("ncover-tmp") })
        }
    }

    @Test func thesameTitleUnderTwoArtistsKeepsTwoOriginalsInTwoPlaces() throws {
        // Same release name, same file name, different artist: each library
        // file is written where it is, and each original has its own slot.
        let base = tmpdir("twins")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let a = lib.appendingPathComponent("Autechre/Amber/cover.jpg")
        let b = lib.appendingPathComponent("Boards of Canada/Amber/cover.jpg")
        try jpeg(a, 600, 538, RGBA(255, 0, 0, 255))
        try jpeg(b, 700, 600, RGBA(0, 0, 255, 255))
        let (ra, rb) = (try Data(contentsOf: a), try Data(contentsOf: b))

        let wb = try WriteBack.start(keptRoot: kept)
        for f in [a, b] {
            #expect(try wb.one(source: f, place: try place(f, under: lib), recipe: square()) != nil)
        }
        #expect(imageSize(of: a).map { [$0.width, $0.height] } == [538, 538])
        #expect(imageSize(of: b).map { [$0.width, $0.height] } == [600, 600],
                "each written where it lives, at its own size")
        #expect(try Data(contentsOf: kept.appendingPathComponent("Autechre/Amber/cover.jpg")) == ra)
        #expect(try Data(contentsOf: kept.appendingPathComponent("Boards of Canada/Amber/cover.jpg")) == rb)

        let report = try #require(try undoLastRun(in: kept))
        #expect((report.restored, report.skipped.count) == (2, 0))
        #expect(try Data(contentsOf: a) == ra, "each original back in its own folder")
        #expect(try Data(contentsOf: b) == rb)
    }

    @Test func afileOutsideTheRootOrWithDotsHasNoPlaceAndIsRefused() throws {
        let base = tmpdir("noplace")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let away = base.appendingPathComponent("elsewhere/cover.jpg")
        try jpeg(away, 600, 538)
        let wb = try WriteBack.start(keptRoot: kept)

        // There is no place to ask for in the first place.
        #expect(placeUnder(away, strip: lib) == nil)
        // And a place made another way cannot climb out of the originals folder.
        for bad in ["../up/cover.jpg", "/absolute/cover.jpg", "", "A/../../cover.jpg"] {
            #expect(throws: WriteBackError.noPlace(bad)) { _ = try wb.slot(for: bad) }
            #expect(throws: WriteBackError.noPlace(bad)) {
                _ = try wb.one(source: away, place: bad, recipe: square())
            }
        }
        #expect(!FileManager.default.fileExists(
            atPath: kept.appendingPathComponent(WRITEBACK_LOG).path), "nothing was logged")
    }

    @Test func atakenSlotIsRefusedAndTheLibraryFileIsUntouched() throws {
        // A second run must never overwrite the first original.
        let base = tmpdir("slot")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let cover = lib.appendingPathComponent("A/One/cover.jpg")
        try jpeg(cover, 600, 538)
        let first = try WriteBack.start(keptRoot: kept)
        let p = try place(cover, under: lib)
        _ = try first.one(source: cover, place: p, recipe: square())
        let kptOriginal = try Data(contentsOf: kept.appendingPathComponent(p))

        // The cover is off-square again — a new scan, a replaced file.
        try jpeg(cover, 400, 300, RGBA(9, 9, 9, 255))
        let now = try Data(contentsOf: cover)
        let second = try WriteBack.start(keptRoot: kept)
        #expect(throws: WriteBackError.slotTaken(kept.appendingPathComponent(p).path)) {
            _ = try second.one(source: cover, place: p, recipe: square())
        }
        #expect(try Data(contentsOf: cover) == now, "the library file is untouched")
        #expect(try Data(contentsOf: kept.appendingPathComponent(p)) == kptOriginal,
                "and the first original is still the one kept")
    }

    @Test func asquareFileIsLeftAloneAndADryRunWritesNothing() throws {
        let base = tmpdir("leave")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let already = lib.appendingPathComponent("A/Square/cover.jpg")
        let off = lib.appendingPathComponent("A/Off/cover.jpg")
        try jpeg(already, 600, 600)
        try jpeg(off, 600, 538)
        let wb = try WriteBack.start(keptRoot: kept)

        // Already square: nothing copied, nothing written, nothing logged.
        #expect(try wb.one(source: already, place: try place(already, under: lib),
                           recipe: square()) == nil)
        #expect(names(in: kept) == [], "not even a log")

        // A dry run says where the original would go and touches neither file.
        let was = try Data(contentsOf: off)
        let slot = try wb.one(source: off, place: try place(off, under: lib),
                              recipe: square(), dry: true)
        #expect(slot?.lastPathComponent == "cover.jpg")
        #expect(try Data(contentsOf: off) == was)
        #expect(names(in: kept) == [])
        #expect(try lastRun(in: kept) == nil)
    }

    @Test func coverAndFitAreRefusedForTheLibrary() throws {
        // They write a PNG, usually under another name, and ndisc's cover
        // would still point at the old file.
        let base = tmpdir("framings")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let cover = lib.appendingPathComponent("A/One/cover.jpg")
        try jpeg(cover, 600, 538)
        let wb = try WriteBack.start(keptRoot: kept)
        let p = try place(cover, under: lib)
        let was = try Data(contentsOf: cover)
        for framing in [Framing.cover, .fit] {
            #expect(throws: WriteBackError.notAKeepFormatJob(framing == .cover ? "Cover" : "Fit")) {
                _ = try wb.one(source: cover, place: p,
                               recipe: Recipe(canvas: 600, framing: framing, disc: nil))
            }
        }
        #expect(try Data(contentsOf: cover) == was)
    }

    @Test func undoSkipsAFileChangedSinceTheRunAndMarksTheRunDone() throws {
        let base = tmpdir("undo")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let a = lib.appendingPathComponent("A/One/cover.jpg")
        let b = lib.appendingPathComponent("A/Two/cover.jpg")
        try jpeg(a, 600, 538, RGBA(255, 0, 0, 255))
        try jpeg(b, 600, 538, RGBA(0, 255, 0, 255))
        let wb = try WriteBack.start(keptRoot: kept)
        for f in [a, b] {
            _ = try wb.one(source: f, place: try place(f, under: lib), recipe: square())
        }
        // Edited by hand after the run.
        try jpeg(b, 300, 300, RGBA(0, 0, 255, 255))
        let edited = try Data(contentsOf: b)

        let report = try #require(try undoLastRun(in: kept))
        #expect(report.restored == 1)
        #expect(report.skipped.map(\.file.path) == [b.path])
        #expect(imageSize(of: a).map { [$0.width, $0.height] } == [600, 538], "put back")
        #expect(try Data(contentsOf: b) == edited, "the later edit is not thrown away")
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("A/Two/cover.jpg").path),
                "its original stays kept")
        #expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("A/One").path),
                "a restored original leaves no empty folder")
        #expect(try lastRun(in: kept) == nil, "the run is marked undone")
        #expect(try undoLastRun(in: kept) == nil)
    }

    @Test func asecondRunIsUndoneBeforeTheFirst() throws {
        let base = tmpdir("two-runs")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let a = lib.appendingPathComponent("A/One/cover.jpg")
        let b = lib.appendingPathComponent("A/Two/cover.jpg")
        try jpeg(a, 600, 538, RGBA(255, 0, 0, 255))
        try jpeg(b, 600, 538, RGBA(0, 255, 0, 255))
        let now = Date()
        let first = try WriteBack.start(keptRoot: kept, now: now)
        _ = try first.one(source: a, place: try place(a, under: lib), recipe: square())
        let second = try WriteBack.start(keptRoot: kept, now: now)
        #expect(first.run != second.run, "two runs in one second still get two names")
        _ = try second.one(source: b, place: try place(b, under: lib), recipe: square())

        #expect(try undoLastRun(in: kept)?.run == second.run)
        #expect(imageSize(of: b).map { [$0.width, $0.height] } == [600, 538])
        #expect(imageSize(of: a).map { [$0.width, $0.height] } == [538, 538],
                "the first run is still in place")
        #expect(try undoLastRun(in: kept)?.run == first.run)
        #expect(imageSize(of: a).map { [$0.width, $0.height] } == [600, 538])
    }

    // MARK: - Convert into the library (the shared 11th column)

    @Test func convertIntoTheLibraryKeepsThePngLogsElevenColumnsAndPutsBack() throws {
        // GTK's own test name. `cover.png` becomes `cover.jpg`, the PNG is
        // kept under its own name and leaves the library, and the swap line
        // carries an 11th column naming what it removed.
        let base = tmpdir("convert")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let logo = lib.appendingPathComponent("_labels/Peak Oil.png")
        try png(logo, 500, 300)
        let before = try Data(contentsOf: logo)

        let wb = try WriteBack.start(keptRoot: kept)
        let place = try place(logo, under: lib)
        let recipe = Recipe(canvas: 600, job: .convert, disc: nil)

        #expect(try wb.one(source: logo, place: place, recipe: recipe, dry: true) != nil,
                "a dry run says it would")
        #expect(FileManager.default.fileExists(atPath: logo.path))
        #expect(!FileManager.default.fileExists(
            atPath: lib.appendingPathComponent("_labels/Peak Oil.jpg").path), "and writes nothing")

        let got = try wb.one(source: logo, place: place, recipe: recipe)
        let k = kept.appendingPathComponent("_labels/Peak Oil.png")
        let jpg = lib.appendingPathComponent("_labels/Peak Oil.jpg")
        #expect(got?.path == k.path)
        #expect(!FileManager.default.fileExists(atPath: logo.path), "the PNG has left the library")
        #expect(try Data(contentsOf: k) == before, "kept byte for byte, under its own name")
        #expect(imageSize(of: jpg).map { [$0.width, $0.height] } == [500, 300])
        #expect(ImageFormat.of(jpg) == .jpeg)

        let line = try #require(try String(contentsOf: kept.appendingPathComponent(WRITEBACK_LOG),
                                           encoding: .utf8)
            .components(separatedBy: .newlines).first { $0.hasPrefix("swap\t") })
        let f = line.components(separatedBy: "\t")
        #expect(f.count == 11, "Convert's swap line carries the removed file")
        #expect([f[3], f[4], f[5], f[10]] == ["convert", jpg.path, k.path, logo.path])

        let report = try #require(try undoLastRun(in: kept))
        #expect((report.restored, report.skipped.count) == (1, 0))
        #expect(try Data(contentsOf: logo) == before, "Put back returns the PNG to its own name")
        #expect(!FileManager.default.fileExists(atPath: jpg.path), "and removes the JPEG")
        #expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("_labels").path),
                "the kept copy and its folder are gone")
        #expect(try lastRun(in: kept) == nil)
    }

    @Test func convertRefusesAJpegAlreadyBesideItAndATransparentPng() throws {
        let base = tmpdir("convert-refused")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let a = lib.appendingPathComponent("A/cover.png")
        let b = lib.appendingPathComponent("B/cover.png")
        try png(a, 400, 400, RGBA(255, 0, 0, 255))
        try jpeg(lib.appendingPathComponent("A/cover.jpg"), 400, 400, RGBA(0, 255, 0, 255))
        try png(b, 400, 400, RGBA(255, 0, 0, 255), transparentCorner: true)

        let wb = try WriteBack.start(keptRoot: kept)
        let recipe = Recipe(canvas: 600, job: .convert, disc: nil)
        // Both refusals hold for a dry run as well: a dry run that passes
        // where the real one fails is a dry run that tells you nothing.
        for dry in [true, false] {
            #expect(throws: WriteBackError.convertWouldOverwrite("cover.jpg")) {
                _ = try wb.one(source: a, place: "A/cover.png", recipe: recipe, dry: dry)
            }
            #expect(throws: WriteGuardError.overwriteJPEGHasAlpha) {
                _ = try wb.one(source: b, place: "B/cover.png", recipe: recipe, dry: dry)
            }
        }
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(imageSize(of: lib.appendingPathComponent("A/cover.jpg")).map(\.width) == 400,
                "the JPEG already there is untouched")
        #expect(!FileManager.default.fileExists(atPath: lib.appendingPathComponent("B/cover.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("A").path))
        #expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("B").path),
                "nothing kept for a refusal")
    }

    @Test func atenColumnLineStillReadsAndAnUndoOfOneLeavesTheOtherAlone() throws {
        // The format is shared with GTK, so both shapes have to read: ten
        // columns for Cap, Square and Pad, eleven for Convert, in one log.
        let base = tmpdir("mixed")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let logo = lib.appendingPathComponent("A/cover.png")
        let jpg = lib.appendingPathComponent("B/cover.jpg")
        try png(logo, 500, 500, RGBA(9, 9, 9, 255))
        try jpeg(jpg, 900, 538)

        let wb = try WriteBack.start(keptRoot: kept)
        _ = try wb.one(source: logo, place: "A/cover.png",
                       recipe: Recipe(canvas: 600, job: .convert, disc: nil))
        _ = try wb.one(source: jpg, place: "B/cover.jpg",
                       recipe: Recipe(canvas: 600, job: .square, disc: nil))

        let rows = try readLog(in: kept).filter { !$0.undo }
        #expect(rows.count == 2)
        #expect(rows.map { $0.removed?.lastPathComponent } == ["cover.png", nil],
                "only Convert's line names a removed file")

        let report = try #require(try undoLastRun(in: kept))
        #expect((report.restored, report.skipped.count) == (2, 0))
        #expect(FileManager.default.fileExists(atPath: logo.path), "the PNG is back")
        #expect(!FileManager.default.fileExists(atPath: lib.appendingPathComponent("A/cover.jpg").path))
        #expect(imageSize(of: jpg).map { [$0.width, $0.height] } == [900, 538], "and the JPEG is as it was")
    }

    @Test func putBackLeavesAConvertedFileAloneIfItsNameIsTakenAgain() throws {
        // Someone has put a cover.png back by hand since the run. Its bytes
        // are not ours to replace, so the JPEG stays and the line is named.
        let base = tmpdir("name-taken")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let logo = lib.appendingPathComponent("A/cover.png")
        try png(logo, 500, 500, RGBA(9, 9, 9, 255))
        let wb = try WriteBack.start(keptRoot: kept)
        _ = try wb.one(source: logo, place: "A/cover.png",
                       recipe: Recipe(canvas: 600, job: .convert, disc: nil))

        try png(logo, 120, 120, RGBA(1, 2, 3, 255))   // back by hand
        let mine = try Data(contentsOf: logo)

        let report = try #require(try undoLastRun(in: kept))
        #expect(report.restored == 0)
        #expect(report.skipped.count == 1)
        #expect(report.skipped[0].why.contains("in the library again"))
        #expect(try Data(contentsOf: logo) == mine, "the hand-made file is untouched")
        #expect(FileManager.default.fileExists(atPath: lib.appendingPathComponent("A/cover.jpg").path),
                "and the JPEG stays rather than leaving nothing")
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("A/cover.png").path),
                "its original stays kept")
    }

    @Test func theoriginalsFolderMayNotBeTheLibraryInsideItOrAboveIt() throws {
        let base = tmpdir("guard")
        let lib = base.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("kept"),
                                                withIntermediateDirectories: true)
        #expect(throws: WriteBackError.originalsIsLibrary) { try guardOriginals(library: lib, kept: lib) }
        #expect(throws: WriteBackError.originalsInsideLibrary) {
            try guardOriginals(library: lib, kept: lib.appendingPathComponent("kept"))
        }
        #expect(throws: WriteBackError.libraryInsideOriginals) {
            try guardOriginals(library: lib, kept: base)
        }
        let beside = base.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        #expect(throws: Never.self) { try guardOriginals(library: lib, kept: beside) }
    }

    @Test func alogLineIsTheSameShapeTheGtkSiblingWrites() throws {
        // One library, one originals folder, and either app may have written
        // the run you are putting back — so the columns are not ours to move.
        let base = tmpdir("log")
        let lib = base.appendingPathComponent("library")
        let kept = base.appendingPathComponent("originals")
        let cover = lib.appendingPathComponent("A/One/cover.jpg")
        try jpeg(cover, 900, 600)
        let wb = try WriteBack.start(keptRoot: kept)
        _ = try wb.one(source: cover, place: try place(cover, under: lib), recipe: square())
        _ = try undoLastRun(in: kept)

        let lines = try String(contentsOf: kept.appendingPathComponent(WRITEBACK_LOG), encoding: .utf8)
            .components(separatedBy: .newlines)
        #expect(lines[0].hasPrefix("# n.cover write-back log."))
        let swap = try #require(lines.first { $0.hasPrefix("swap\t") }).components(separatedBy: "\t")
        #expect(swap.count == 10)
        #expect([swap[0], swap[3], swap[4], swap[5], swap[6], swap[7]]
                == ["swap", "square", cover.path,
                    kept.appendingPathComponent("A/One/cover.jpg").path, "900x600", "600x600"])
        #expect(swap[1] == wb.run && swap[2] == wb.time)
        #expect(Int64(swap[8]) != nil && Int64(swap[9]) != nil, "bytes and mtime in ns")
        let undo = try #require(lines.first { $0.hasPrefix("undo\t") }).components(separatedBy: "\t")
        #expect([undo[0], undo[1], undo[3], undo[4]] == ["undo", wb.run, "1", "0"])

        // And we read our own log back: one run, already undone.
        #expect(try readLog(in: kept).count == 2)
        #expect(try lastRun(in: kept) == nil)
    }
}
