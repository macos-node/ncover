import Foundation
import Testing

@testable import NCoverKit

// ndisc's Export list as a scope. Phase C of docs/gtk-parity-plan.md.
//
// The fixtures below are byte-faithful to what ndisc's `coverListText` writes:
// tab-separated, no header, `folder · cover file · artist — title · disk WxH ·
// published WxH · format · kinds · actions`, `-` for an empty field, kinds and
// actions comma-joined.

private func tmpdir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("ncover-list-\(name)")
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func flat(_ w: Int, _ h: Int) -> Raster {
    var r = Raster(empty: w, height: h)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = 180; r.px[i + 1] = 90; r.px[i + 2] = 40; r.px[i + 3] = 255
    }
    return r
}

@Suite("cover list")
struct CoverListTests {
    @Test func itReadsNdiscsColumnsAndItsEmptyFieldMarker() {
        let text = """
            /lib/Autechre/Amber\t/lib/Autechre/Amber/cover.jpg\tAutechre — Amber\t600x538\t600x600\tjpeg\toff-square-10%\tncover:square
            /lib/Boards/Geogaddi\t/lib/Boards/Geogaddi/cover.png\tBoards of Canada — Geogaddi\t1800x1800\t-\tpng\tover-600,png\tncover:cap,ncover:convert
            /lib/Nobody/Nothing\t-\tNobody — Nothing\t-\t-\t-\tno-cover\tresource
            """
        let l = parseCoverList(text)
        #expect(l.lines.count == 3)
        #expect(l.hasActions)
        #expect(l.skipped.isEmpty)
        #expect(l.root?.path == "/lib")

        #expect(l.lines[0].folder.path == "/lib/Autechre/Amber")
        #expect(l.lines[0].cover?.lastPathComponent == "cover.jpg")
        #expect(l.lines[0].name == "Autechre — Amber")
        #expect(l.lines[0].actions == ["ncover:square"])
        // Several actions on one line, in ndisc's order.
        #expect(l.lines[1].actions == ["ncover:cap", "ncover:convert"])
        // `-` is empty, not a filename.
        #expect(l.lines[2].cover == nil)
        #expect(l.lines[2].actions == ["resource"])
    }

    @Test func alineWithNoReleaseFolderIsSkippedAndCounted() {
        // ndisc writes "artist — title" in the first column when a release has
        // no folder at all. There is nothing to walk, so it is skipped — and
        // named, because a list that quietly shrinks is worse than one that
        // complains.
        let text = """
            /lib/A/One\t-\tA — One\t-\t-\t-\tno-cover\tresource
            Some Artist — Some Title\t-\tSome Artist — Some Title\t-\t-\t-\tno-cover\tresource
            relative/path\t-\tB — Two\t-\t-\t-\t-\t-
            """
        let l = parseCoverList(text)
        #expect(l.lines.count == 1)
        #expect(l.skipped == [2, 3], "1-based, so they can be found in the file")
    }

    @Test func ahandMadeListOfFoldersWorksAndPutsEveryLineIn() {
        // Every column after the first is optional, and with no actions column
        // the job cannot filter — so a plain list is simply all of it.
        let l = parseCoverList("""
            # covers to square, pulled out by hand
            /lib/A/One

            /lib/A/Two
            /lib/B/Three\t
            """)
        #expect(l.lines.count == 3, "the comment and the blank line are not releases")
        #expect(!l.hasActions)
        #expect(l.lines.allSatisfy { l.selects($0, job: .cap) })
        #expect(l.lines.allSatisfy { l.selects($0, job: .square) })
        #expect(l.root?.path == "/lib")
    }

    @Test func thesecondColumnIsACoverOnlyWhenItIsOne() {
        let l = parseCoverList("""
            /lib/A/One\tjust a note about this one\tA — One\t-\t-\t-\t-\t-
            /lib/A/Two\t/lib/A/Two/notes.txt\tA — Two\t-\t-\t-\t-\t-
            /lib/A/Three\t/somewhere/else/cover.jpg\tA — Three\t-\t-\t-\t-\t-
            /lib/A/Four\t/lib/A/Four/front.png\tA — Four\t-\t-\t-\t-\t-
            """)
        #expect(l.lines[0].cover == nil, "a note is not a path")
        #expect(l.lines[1].cover == nil, "not an image")
        #expect(l.lines[2].cover == nil, "outside the folder — never touch that")
        #expect(l.lines[3].cover?.lastPathComponent == "front.png")
    }

    @Test func carriageReturnsSurviveTheTrip() {
        // A list that has been through a Windows editor, or an export opened
        // and resaved. The trailing \\r must not end up inside the actions.
        let l = parseCoverList("/lib/A/One\t-\tA — One\t-\t-\t-\toff-square-9%\tncover:square\r\n")
        #expect(l.lines.count == 1)
        #expect(l.lines[0].actions == ["ncover:square"])
    }

    // MARK: - the job picks the lines

    @Test func thejobTakesItsOwnLinesAndCountsTheRest() {
        let text = """
            /lib/A/Sq1\t-\tA — Sq1\t600x538\t-\tjpeg\toff-square-10%\tncover:square
            /lib/A/Sq2\t-\tA — Sq2\t600x500\t-\tjpeg\toff-square-17%\tncover:square
            /lib/A/Big\t-\tA — Big\t1800x1800\t-\tjpeg\tover-600\tncover:cap
            /lib/A/Res\t-\tA — Res\t200x200\t-\tjpeg\tlow-res<400\tresource
            /lib/A/Rev\t-\tA — Rev\t600x600\t-\tjpeg\tdifferent-picture\treview
            /lib/A/Up\t-\tA — Up\t600x600\t-\tjpeg\tshrunk\tndisc:upload
            /lib/A/Idle\t-\tA — Idle\t600x600\t-\tjpeg\t-\t-
            """
        let l = parseCoverList(text)

        #expect(l.lines.filter { l.selects($0, job: .square) }.count == 2)
        #expect(l.lines.filter { l.selects($0, job: .pad(.edge)) }.count == 2,
                "Pad answers the same line as Square — cropping or padding is per run")
        #expect(l.lines.filter { l.selects($0, job: .cap) }.count == 1)
        // A framing has no action of its own, so a list is just a list of
        // folders to it.
        #expect(l.lines.filter { l.selects($0, job: .frame(.cover)) }.count == 7)

        // Counted in ndisc's own order, so the most upstream work reads first.
        #expect(l.leftOut(job: .square)
                == "1 need a new source · 1 to review · 1 to cap · 1 for ndisc to upload · 1 with nothing to do")
        #expect(l.leftOut(job: .frame(.cover)) == "", "a framing leaves nothing out")
    }

    // MARK: - as a scope

    @Test func thescopeMirrorsUnderTheFoldersCommonParent() throws {
        let l = parseCoverList("""
            /lib/Autechre/Amber\t/lib/Autechre/Amber/cover.jpg\tAutechre — Amber\t600x538\t-\tjpeg\toff-square-10%\tncover:square
            /lib/Boards/Geogaddi\t-\tBoards of Canada — Geogaddi\t700x600\t-\tjpeg\toff-square-14%\tncover:square
            /lib/Boards/Campfire\t-\tBoards of Canada — Campfire\t1800x1800\t-\tjpeg\tover-600\tncover:cap
            """)
        let scope = try BatchScope.list(l, job: .square)
        #expect(scope.roots.map(\.lastPathComponent) == ["Amber", "Geogaddi"])
        // The deepest folder holding every line folder's PARENT: here the
        // releases sit under two artists, so it is the library itself.
        #expect(scope.strip.path == "/lib")
        #expect(scope.guardRoot.path == "/lib", "the guard protects the whole library")
        #expect(scope.names["/lib/Autechre/Amber"] == "Autechre — Amber")
        #expect(scope.only["/lib/Autechre/Amber"]?.map(\.lastPathComponent) == ["cover.jpg"])
        #expect(scope.only["/lib/Boards/Geogaddi"] == nil, "no named cover: walk it")
        #expect(scope.fileNames["/lib/Autechre/Amber/cover.jpg"] == "Autechre — Amber")

        // A framing has no action of its own, so it takes the list whole —
        // which is the right answer, not an oversight: "run Cover over these
        // three releases" is a sensible thing to ask of a list.
        #expect(try BatchScope.list(l, job: .frame(.cover)).roots.count == 3)

        // A job that no line is for is refused with the reason, rather than
        // running over nothing and reporting success.
        let forSomeoneElse = parseCoverList(
            "/lib/A/One\t-\tA — One\t200x200\t-\tjpeg\tlow-res<400\tresource")
        #expect(throws: BatchError.listEmpty) {
            _ = try BatchScope.list(forSomeoneElse, job: .cap) as BatchScope
        }
    }

    @Test func anamedCoverIsTheOnlyFileThatRootContributes() throws {
        // The whole point of the cover column: a release folder usually holds
        // back and inlay art, and a run must not touch them.
        let base = tmpdir("only")
        let release = base.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        try flat(900, 900).writeJPEG(to: release.appendingPathComponent("cover.jpg"))
        try flat(900, 900).writeJPEG(to: release.appendingPathComponent("back.jpg"))
        try flat(900, 900).writeJPEG(to: release.appendingPathComponent("inlay.jpg"))

        let named = parseCoverList(
            "\(release.path)\t\(release.appendingPathComponent("cover.jpg").path)\tArtist — Album\t900x900\t-\tjpeg\tover-600\tncover:cap")
        let scope = try BatchScope.list(named, job: .cap)
        #expect(findImages(in: scope, needle: "").map(\.lastPathComponent) == ["cover.jpg"])

        // And the survey agrees, because both come through `images(under:)`.
        let survey = surveyBatch(scope, needle: "")
        #expect(survey.total == 1)
        #expect(survey.groups.first?.name == "Artist — Album")

        // Without the cover column the folder is walked like any other root.
        let plain = parseCoverList(release.path)
        let walked = try BatchScope.list(plain, job: .cap)
        #expect(findImages(in: walked, needle: "").count == 3)
        // The name filter still applies on top.
        #expect(findImages(in: walked, needle: "cover").map(\.lastPathComponent) == ["cover.jpg"])
    }

    @Test func anamedCoverThatIsNotThereIsCountedAsThat() throws {
        // The list was exported before someone moved the file. Nothing to do
        // and nothing to fail — but it is not a release that "matched
        // nothing" either, and once a folder holds several named files one
        // missing from it cannot be read off an empty-root count at all.
        let base = tmpdir("gone")
        let release = base.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let l = parseCoverList(
            "\(release.path)\t\(release.appendingPathComponent("cover.jpg").path)\tArtist — Album\t900x900\t-\tjpeg\tover-600\tncover:cap")
        let scope = try BatchScope.list(l, job: .cap)
        #expect(findImages(in: scope, needle: "").isEmpty)
        let survey = surveyBatch(scope, needle: "")
        #expect(survey.missingNamed == 1)
        #expect(survey.emptyRoots == 0, "it named a file; it did not match nothing")
    }

    // MARK: - several lines in one folder (phase F7)

    @Test func manyLinesNamingFilesInOneFolderTakeEveryOneOfThem() throws {
        // ndisc's label export: one line per label, every one of them pointing
        // into the same folder of logos. Keyed by folder to a single URL, the
        // scope kept whichever line came last — so a 76-line export ran over
        // one image and called the other 75 folders empty.
        let base = tmpdir("shared")
        let logos = base.appendingPathComponent("labels")
        try FileManager.default.createDirectory(at: logos, withIntermediateDirectories: true)
        for f in ["Ultra.Records.label.jpg", "Mute.label.jpg", "unlisted.jpg"] {
            try flat(400, 300).writeJPEG(to: logos.appendingPathComponent(f))
        }
        try flat(400, 300).writePNG(to: logos.appendingPathComponent("Warp.label.png"))

        let line = { (f: String, n: String) in
            [logos.path, logos.appendingPathComponent(f).path, n, "-", "-", "-", "-",
             "ncover:square"].joined(separator: "\t")
        }
        let l = parseCoverList([line("Ultra.Records.label.jpg", "Ultra Records"),
                                line("Warp.label.png", "Warp"),
                                line("Mute.label.jpg", "Mute"),
                                line("Gone.label.jpg", "Gone")].joined(separator: "\n"))
        let scope = try BatchScope.list(l, job: .square)
        #expect(scope.roots.map(\.path) == [logos.path], "one folder is one root")
        // Every line names the same folder, so the prefix is its PARENT and a
        // place keeps the folder's own name — `labels/Warp.label.png`, not a
        // bare filename in the top of the output. The sibling mirrors it the
        // same way, and they share an originals folder.
        #expect(scope.strip.path == base.standardizedFileURL.path)
        #expect(findImages(in: scope, needle: "").map { placeUnder($0, strip: scope.strip) }
                == ["labels/Mute.label.jpg", "labels/Ultra.Records.label.jpg",
                    "labels/Warp.label.png"])
        #expect(scope.names.isEmpty, "a shared folder carries no one line's name")
        #expect(scope.only[logos.standardizedFileURL.path]?.count == 4)

        // The name filter does not reach a named file: the default "cover"
        // would otherwise take every label out of the run.
        for needle in ["", "cover"] {
            let got = findImages(in: scope, needle: needle).map(\.lastPathComponent).sorted()
            #expect(got == ["Mute.label.jpg", "Ultra.Records.label.jpg", "Warp.label.png"],
                    "every named file that is there, and nothing else, with “\(needle)”")
        }

        let survey = surveyBatch(scope, needle: "cover")
        #expect(survey.total == 3)
        #expect((survey.emptyRoots, survey.missingNamed) == (0, 1), "Gone is counted, by itself")
        #expect(survey.total == findImages(in: scope, needle: "cover").count,
                "the count is the run")

        // Each file is captioned by its own line, since the folder cannot be.
        let plan = planItems(files: findImages(in: scope, needle: ""), scope: scope,
                             recipe: Recipe(canvas: 400, job: .square, disc: nil))
        #expect(Set(plan.map(\.name)) == ["Ultra Records", "Warp", "Mute"])

        // A line with no cover file asks for the whole folder, which takes in
        // anything another line named there.
        let whole = parseCoverList(l.lines.map { line in
            [line.folder.path, line.cover?.path ?? "-", line.name ?? "-", "-", "-", "-", "-",
             "ncover:square"].joined(separator: "\t")
        }.joined(separator: "\n") + "\n\(logos.path)\t-\t-\t-\t-\t-\t-\tncover:square")
        let all = try BatchScope.list(whole, job: .square)
        #expect(all.only.isEmpty, "the fileless line re-opens the folder")
        #expect(findImages(in: all, needle: "").count == 4, "including the unlisted logo")
    }

    @Test func acapRunFromAListTouchesOnlyTheLinesItIsFor() throws {
        // End to end: two releases flagged for Cap, one for Square, one for a
        // person. A Cap run writes the two, and the output mirrors under the
        // library root rather than under each release.
        let base = tmpdir("endtoend")
        let lib = base.appendingPathComponent("library")
        let out = base.appendingPathComponent("out")
        var rows: [String] = []
        for (artist, album, size, action) in [
            ("Autechre", "Amber", 900, "ncover:cap"),
            ("Boards", "Geogaddi", 1200, "ncover:cap"),
            ("Plaid", "Rest Proof", 900, "ncover:square"),
            ("Nobody", "Nothing", 900, "resource"),
        ] as [(String, String, Int, String)] {
            let d = lib.appendingPathComponent("\(artist)/\(album)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let cover = d.appendingPathComponent("cover.jpg")
            try flat(size, size).writeJPEG(to: cover)
            try flat(size, size).writeJPEG(to: d.appendingPathComponent("back.jpg"))
            rows.append([d.path, cover.path, "\(artist) — \(album)", "\(size)x\(size)",
                         "-", "jpeg", "over-600", action].joined(separator: "\t"))
        }

        let list = parseCoverList(rows.joined(separator: "\n"))
        let scope = try BatchScope.list(list, job: .cap)
        try guardBatch(source: scope.guardRoot, output: out)

        let recipe = Recipe(canvas: 400, job: .cap, disc: nil)
        let hits = findImages(in: scope, needle: "")
        let rels = hits.map { relativePath(of: $0, under: scope.strip) }
        #expect(rels == ["Autechre/Amber/cover.jpg", "Boards/Geogaddi/cover.jpg"],
                "the Square and resource lines are not in a Cap run, and no back.jpg is")

        let plan = planDests(rels: rels, outRoot: out, job: recipe.job, disc: false)
        for ((hit, _), planned) in zip(zip(hits, rels), plan) {
            let dest = try planned.get()
            let format = try batchWriteFormat(dest: dest, job: recipe.job)
            let made = try #require(try batchRender(try Raster.load(contentsOf: hit),
                                                    recipe: recipe))
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try made.write(to: dest, as: format, alpha: .discard)
        }

        let written = out.appendingPathComponent("Autechre/Amber/cover.jpg")
        #expect(imageSize(of: written).map { [$0.width, $0.height] } == [400, 400])
        #expect(ImageFormat.of(written) == .jpeg)
        #expect(!FileManager.default.fileExists(
            atPath: out.appendingPathComponent("Plaid/Rest Proof/cover.jpg").path))
        // And the list says what it left for everyone else.
        #expect(list.leftOut(job: .cap) == "1 need a new source · 1 to square")
    }

    // Against a list ndisc actually exported, when there is one to hand:
    //   NCOVER_LIST=<an exported cover list> make test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NCOVER_LIST"] != nil))
    func arealExportParsesAndEveryFolderItNamesExists() throws {
        let url = URL(fileURLWithPath:
            (ProcessInfo.processInfo.environment["NCOVER_LIST"]! as NSString).expandingTildeInPath)
        let l = try readCoverList(at: url)
        print("""
            \(l.lines.count) releases · \(l.skipped.count) skipped · \
            actions: \(l.hasActions) · root \(l.root?.path ?? "—")
            square: \(l.lines.filter { l.selects($0, job: .square) }.count) · \
            cap: \(l.lines.filter { l.selects($0, job: .cap) }.count) · \
            convert: \(l.lines.filter { l.selects($0, job: .convert) }.count)
            not in a Square run: \(l.leftOut(job: .square))
            """)
        try #require(!l.lines.isEmpty)

        // The whole chain the Batch pane walks: list → scope → files → plan.
        // Each number is one the app shows somewhere, so a disagreement here
        // is a disagreement on screen.
        for job in [BatchJob.frame(.cover), .cap, .square, .convert] {
            guard let scope = try? BatchScope.list(l, job: job) else {
                print("  \(job.name): no scope — no line is for this job"); continue
            }
            let files = findImages(in: scope, needle: "")
            let survey = surveyBatch(scope, needle: "")
            let plan = planItems(files: files, scope: scope,
                                 recipe: Recipe(canvas: 400, job: job, disc: nil))
            print("  \(job.name): \(scope.roots.count) roots · \(files.count) files · "
                  + "survey \(survey.total) in \(survey.groups.count), \(survey.emptyRoots) empty · "
                  + "plan \(plan.count)")
            if plan.isEmpty, !files.isEmpty {
                print("  !! files but no plan — first: \(files[0].path), "
                      + "size \(String(describing: imageSize(of: files[0])))")
            }
        }
        // Every folder it names is a folder, and every cover it names is in it.
        for line in l.lines {
            #expect(FileManager.default.fileExists(atPath: line.folder.path),
                    "missing folder \(line.folder.path)")
            if let c = line.cover {
                #expect(c.path.hasPrefix(line.folder.path + "/"))
            }
        }
    }
}
