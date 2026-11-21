import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import NCoverKit

// Ported from the GTK app's `batch_tests`, keeping the original names and
// expectations. The two guard cases it also covers live with the other write
// guards, in PortedRulesTests.

private func tmpdir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("ncover-batch-\(name)")
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A real JPEG fixture. The app never writes one — output is always PNG — but
/// a release holding `cover.jpg` *beside* `cover.png` is the arrangement that
/// used to lose a file, and it cannot be staged with two PNGs.
private func writeJPEGFixture(_ r: Raster, to url: URL) throws {
    let data = CFDataCreate(nil, r.px, r.px.count)!
    let img = CGImage(width: r.width, height: r.height,
                      bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                      provider: CGDataProvider(data: data)!, decode: nil,
                      shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    #expect(CGImageDestinationFinalize(dest), "could not write the JPEG fixture")
}

/// An opaque raster of one colour.
private func flat(_ w: Int, _ h: Int, _ c: RGBA) -> Raster {
    var r = Raster(empty: w, height: h)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = c.r; r.px[i + 1] = c.g; r.px[i + 2] = c.b; r.px[i + 3] = 255
    }
    return r
}

@Suite("batch")
struct BatchTests {
    @Test func theDestinationMirrorsTheSourceTree() {
        // The shape of the library is the only thing that tells 1,600 files
        // named cover.png apart. Flatten it and they all land on each other.
        let out = URL(fileURLWithPath: "/tmp/out")
        #expect(batchDest(rel: "Autechre/Amber/cover.jpg", outRoot: out, disc: true).path
                == "/tmp/out/Autechre/Amber/cover-disc.png")
        // No disc: no suffix. Always PNG — alpha has nowhere to live in a JPEG.
        #expect(batchDest(rel: "Autechre/Amber/cover.jpg", outRoot: out, disc: false).path
                == "/tmp/out/Autechre/Amber/cover.png")
        // A file at the top of the scope keeps its name and gains no folder.
        #expect(batchDest(rel: "cover.png", outRoot: out, disc: false).path
                == "/tmp/out/cover.png")
    }

    @Test func twoCoversInOneReleaseDoNotLandOnEachOther() throws {
        // The bug this exists for: both of these plan `cover.png`, so the
        // second run of the loop replaced the first's output and the results
        // list called both of them written. A dry run could not show it,
        // since each file renders perfectly on its own.
        let out = URL(fileURLWithPath: "/tmp/out")
        let plan = planDests(rels: ["Autechre/Amber/cover.jpg", "Autechre/Amber/cover.png"],
                             outRoot: out, job: .frame(.cover), disc: false)
        #expect(try plan[0].get().path == "/tmp/out/Autechre/Amber/cover-jpg.png")
        #expect(try plan[1].get().path == "/tmp/out/Autechre/Amber/cover-png.png")
    }

    @Test func aNameNothingElseWantsIsLeftExactlyAsItWas() throws {
        // The disambiguation is not a rename of everything: a library with no
        // collisions has to come out byte-for-byte as it did before.
        let out = URL(fileURLWithPath: "/tmp/out")
        let plan = planDests(rels: ["Autechre/Amber/cover.jpg", "Autechre/Tri Repetae/cover.jpg"],
                             outRoot: out, job: .frame(.cover), disc: false)
        #expect(try plan[0].get().path == "/tmp/out/Autechre/Amber/cover.png")
        #expect(try plan[1].get().path == "/tmp/out/Autechre/Tri Repetae/cover.png")
    }

    @Test func theDiscSuffixSurvivesDisambiguation() throws {
        let out = URL(fileURLWithPath: "/tmp/out")
        let plan = planDests(rels: ["a/cover.jpg", "a/cover.png"], outRoot: out, job: .frame(.cover), disc: true)
        #expect(try plan[0].get().path == "/tmp/out/a/cover-jpg-disc.png")
        #expect(try plan[1].get().path == "/tmp/out/a/cover-png-disc.png")
    }

    @Test func aClashThatSurvivesDisambiguationIsRefusedNotOverwritten() throws {
        // `cover-jpg.jpg` is a real filename, and it takes the name the pair
        // above would be given. Whoever gets there first keeps it; the other
        // is refused by name rather than written over in silence.
        let out = URL(fileURLWithPath: "/tmp/out")
        let plan = planDests(rels: ["a/cover-jpg.png", "a/cover.jpg", "a/cover.png"],
                             outRoot: out, job: .frame(.cover), disc: false)
        #expect(try plan[0].get().path == "/tmp/out/a/cover-jpg.png")
        #expect(plan[1] == .failure(.destinationTaken(first: "a/cover-jpg.png",
                                                      dest: "/tmp/out/a/cover-jpg.png")))
        #expect(try plan[2].get().path == "/tmp/out/a/cover-png.png")
    }

    @Test func aRefusalSaysWhichFileHoldsTheName() {
        let e = BatchError.destinationTaken(first: "a/cover-jpg.png", dest: "/tmp/out/a/cover-jpg.png")
        #expect(e.errorDescription
                == "would overwrite the output of a/cover-jpg.png (/tmp/out/a/cover-jpg.png); not written")
    }

    @Test func discoveryRecursesFiltersByNameAndSkipsHidden() throws {
        let root = tmpdir("find")
        let rel = root.appendingPathComponent("Artist/Release")
        try FileManager.default.createDirectory(at: rel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        for f in ["cover.png", "back.png", "notes.txt"] {
            try Data("x".utf8).write(to: rel.appendingPathComponent(f))
        }
        try Data("x".utf8).write(to: root.appendingPathComponent(".git/cover.png"))

        var hits: [URL] = []
        findImages(root: root, needle: "cover", into: &hits)
        #expect(hits.map(\.lastPathComponent) == ["cover.png"], "name filter, and no dot-dirs")

        var all: [URL] = []
        findImages(root: root, needle: "", into: &all)
        #expect(all.map(\.lastPathComponent) == ["back.png", "cover.png"],
                "an empty needle takes every image, and notes.txt is not one")
    }

    @Test func aFileFoundTwiceIsWrittenOnce() throws {
        // Two manifest releases can nest, and a duplicate would be rendered
        // and written twice for no reason.
        let root = tmpdir("dupes")
        let inner = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inner.appendingPathComponent("cover.png"))
        let scope = BatchScope(roots: [root, inner], strip: root, guardRoot: root)
        #expect(findImages(in: scope, needle: "").count == 1)
    }

    @Test func theRelativePathIsWhatTheOutputMirrors() {
        let strip = URL(fileURLWithPath: "/music")
        #expect(relativePath(of: URL(fileURLWithPath: "/music/Autechre/Amber/cover.png"),
                             under: strip) == "Autechre/Amber/cover.png")
        // A hit outside the prefix keeps its own name rather than producing a
        // path full of `..` that would escape the output folder. This is the
        // DISPLAY answer; `placeUnder` is the one a write may use.
        #expect(relativePath(of: URL(fileURLWithPath: "/elsewhere/cover.png"),
                             under: strip) == "cover.png")
    }

    // MARK: - a file's place (phase F6)

    @Test func afileOutsideThePrefixHasNoPlaceAtAll() {
        let strip = URL(fileURLWithPath: "/music")
        #expect(placeUnder(URL(fileURLWithPath: "/music/A/B/cover.png"), strip: strip)
                == "A/B/cover.png")
        // The three refusals, each of which `relativePath`'s fallback would
        // have turned into a plausible name in the output root.
        #expect(placeUnder(URL(fileURLWithPath: "/elsewhere/A/cover.png"), strip: strip) == nil)
        #expect(placeUnder(URL(fileURLWithPath: "/music/../etc/cover.png"), strip: strip) == nil)
        #expect(placeUnder(strip, strip: strip) == nil, "the prefix itself is not a place in it")

        #expect(isPlaceable(root: strip, strip: strip), "a folder scope's root IS its prefix")
        #expect(isPlaceable(root: URL(fileURLWithPath: "/music/A"), strip: strip))
        #expect(!isPlaceable(root: URL(fileURLWithPath: "/elsewhere"), strip: strip))
    }

    @Test func arootOutsideThePrefixContributesNothingAndSaysSo() throws {
        // ndisc's manifest can name a release outside `libraryRoot` — a
        // library half-moved, a release on another volume. Every file under
        // it would mirror to a bare filename and they would land on each
        // other in the output root, so the scope takes none of them.
        let base = tmpdir("outside")
        let lib = base.appendingPathComponent("library/Artist/Release")
        let away = base.appendingPathComponent("elsewhere/Other")
        for d in [lib, away] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: d.appendingPathComponent("cover.png"))
        }
        let strip = base.appendingPathComponent("library")
        let scope = BatchScope(roots: [lib, away], strip: strip, guardRoot: strip)

        #expect(findImages(in: scope, needle: "").map { relativePath(of: $0, under: strip) }
                == ["Artist/Release/cover.png"])
        #expect(scope.rootsWithNoPlace.map(\.lastPathComponent) == ["Other"])
        let survey = surveyBatch(scope, needle: "")
        #expect(survey.total == 1)
        #expect(survey.rootsWithNoPlace == 1)
        #expect(survey.emptyRoots == 0, "it is outside the scope, not empty")
        #expect(survey.total == findImages(in: scope, needle: "").count, "the count is the run")
    }

    @Test func aplaceThatIsNotAPlainPathIsRefusedByThePlanner() {
        // The second lock: whoever computes a place should use `placeUnder`,
        // and if they did not, the planner refuses rather than letting
        // `appendingPathComponent` bury an absolute path under the output or
        // flatten a `..` into a name that looks fine.
        let out = URL(fileURLWithPath: "/out")
        let plan = planDests(rels: ["A/cover.jpg", "/music/A/cover.jpg", "../up/cover.jpg", ""],
                             outRoot: out, job: .cap, disc: false)
        #expect((try? plan[0].get())?.path == "/out/A/cover.jpg")
        for i in 1...3 {
            #expect(throws: BatchError.self) { _ = try plan[i].get() }
        }
        // And a refused place cannot invent a clash for a good one: the two
        // `cover.jpg` here are one claim on `/out/A/cover.jpg`, not two.
        let mixed = planDests(rels: ["A/cover.jpg", "/A/cover.jpg"], outRoot: out,
                              job: .frame(.cover), disc: false)
        #expect((try? mixed[0].get())?.lastPathComponent == "cover.png")
    }

    @Test func aManifestWithoutALibraryRootUsesWhatItsReleasesShare() throws {
        let json = """
            {"releases":[{"dir":"/music/a/one"},{"dir":"/music/b/two"}]}
            """
        let m = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        let scope = try BatchScope.published(m)
        #expect(scope.strip.path == "/music")
        #expect(scope.guardRoot.path == "/music")
        #expect(scope.roots.count == 2)
    }

    @Test func aManifestNamingARootUsesIt() throws {
        let json = """
            {"libraryRoot":"/music","releases":[{"dir":"/music/a","artist":"A","title":"T"}]}
            """
        let m = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        #expect(try BatchScope.published(m).strip.path == "/music")
        #expect(m.releases[0].artist == "A")
    }

    @Test func aManifestWithNoReleasesIsRefused() {
        let m = try! JSONDecoder().decode(Manifest.self, from: Data(#"{"releases":[]}"#.utf8))
        #expect(throws: BatchError.manifestEmpty) { _ = try BatchScope.published(m) }
    }

    @Test func releasesWithNothingInCommonAreRefusedRatherThanRootedAtSlash() {
        // Mirroring against "/" would write the whole absolute path into the
        // output folder, which is not a mirror of anything.
        let json = #"{"releases":[{"dir":"/music/a"},{"dir":"/elsewhere/b"}]}"#
        let m = try! JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        #expect(throws: BatchError.manifestNoRoot) { _ = try BatchScope.published(m) }
    }

    @Test func theRecipeIsTheSameRenderThePreviewShows() throws {
        var src = Raster(empty: 10, height: 10)
        for i in stride(from: 0, to: src.px.count, by: 4) {
            src.px[i] = 255; src.px[i + 3] = 255
        }
        let r = Recipe(canvas: 20, framing: .cover, disc: .alpha)
        // A framing always produces something; only the keep-format jobs
        // answer nil, and this test is about Cover.
        let out = try #require(try batchRender(src, recipe: r))
        #expect(out.width == 20 && out.height == 20)
        #expect(out.sample(10, 10) == RGBA(255, 0, 0, 255), "inside the disc")
        #expect(out.sample(0, 0).a == 0, "the corner is masked away")
    }

    /// The whole loop, on real files: walk, render, mirror, write — and then
    /// read back what landed. The runner above this adds progress reporting
    /// and the WebKit hop for SVG; the part that touches user data is here.
    @Test func awholeRunMirrorsTheTreeAndLeavesTheOriginalsAlone() throws {
        let base = tmpdir("endtoend")
        let src = base.appendingPathComponent("lib")
        let out = base.appendingPathComponent("out")
        let release = src.appendingPathComponent("Autechre/Amber")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)

        var art = Raster(empty: 40, height: 20)       // deliberately not square
        for i in stride(from: 0, to: art.px.count, by: 4) {
            art.px[i] = 255; art.px[i + 3] = 255
        }
        let original = release.appendingPathComponent("cover.png")
        try art.writePNG(to: original)
        let before = try Data(contentsOf: original)

        let scope = BatchScope.folder(src)
        try guardBatch(source: scope.guardRoot, output: out)
        let hits = findImages(in: scope, needle: "cover")
        #expect(hits.count == 1)

        let recipe = Recipe(canvas: 200, framing: .cover, disc: .alpha)
        for hit in hits {
            let rel = relativePath(of: hit, under: scope.strip)
            let dest = batchDest(rel: rel, outRoot: out, disc: true)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let made = try #require(try batchRender(try Raster.load(contentsOf: hit),
                                                    recipe: recipe))
            try made.writePNG(to: dest)
        }

        let written = out.appendingPathComponent("Autechre/Amber/cover-disc.png")
        #expect(FileManager.default.fileExists(atPath: written.path))
        let back = try Raster.load(contentsOf: written)
        #expect(back.width == 200 && back.height == 200, "the canvas we asked for")
        #expect(back.sample(100, 100) == RGBA(255, 0, 0, 255))
        #expect(back.sample(1, 1).a == 0, "alpha survives the file, corners and all")
        #expect(try Data(contentsOf: original) == before, "the original is untouched")
    }

    @Test func awholeRunKeepsBothCoversOfOneRelease() throws {
        // The whole loop, as the runner does it, over the arrangement that
        // used to lose a file: one release holding two covers. Before the
        // plan, both wrote `cover.png` and the second replaced the first.
        let base = tmpdir("pair")
        let src = base.appendingPathComponent("library")
        let out = base.appendingPathComponent("out")
        let release = src.appendingPathComponent("Autechre/Amber")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)

        try flat(40, 40, RGBA(255, 0, 0, 255)).writePNG(to: release.appendingPathComponent("cover.png"))
        try writeJPEGFixture(flat(40, 40, RGBA(0, 160, 0, 255)),
                             to: release.appendingPathComponent("cover.jpg"))

        let scope = BatchScope.folder(src)
        try guardBatch(source: scope.guardRoot, output: out)
        let hits = findImages(in: scope, needle: "cover")
        #expect(hits.count == 2)

        let rels = hits.map { relativePath(of: $0, under: scope.strip) }
        let plan = planDests(rels: rels, outRoot: out, job: .frame(.cover), disc: false)
        let recipe = Recipe(canvas: 100, framing: .cover, disc: nil)
        for (hit, planned) in zip(hits, plan) {
            let dest = try planned.get()
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let made = try #require(try batchRender(try Raster.load(contentsOf: hit),
                                                    recipe: recipe))
            try made.writePNG(to: dest)
        }

        // Two files out for two files in, and each is still its own picture.
        let fromJPEG = try Raster.load(
            contentsOf: out.appendingPathComponent("Autechre/Amber/cover-jpg.png"))
        let fromPNG = try Raster.load(
            contentsOf: out.appendingPathComponent("Autechre/Amber/cover-png.png"))
        let green = fromJPEG.sample(50, 50), red = fromPNG.sample(50, 50)
        #expect(green.g > green.r, "the JPEG's output is the green one")
        #expect(red.r > red.g, "the PNG's output is the red one")
    }

    @Test func theSurveySaysWhatWouldBeTouchedWithoutRenderingAnything() throws {
        let root = tmpdir("survey")
        for (artist, title, files) in [
            ("Mr.Oizo", "Lambs Anger", ["cover.jpg", "back.jpg"]),
            ("Lifted", "Trellis", ["cover.jpg"]),
            ("Nobody", "Nothing", ["notes.txt"]),
        ] {
            let d = root.appendingPathComponent("\(artist)/\(title)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for f in files { try Data("x".utf8).write(to: d.appendingPathComponent(f)) }
        }
        let json = """
            {"libraryRoot":"\(root.path)","releases":[
              {"dir":"\(root.path)/Mr.Oizo/Lambs Anger","artist":"Mr.Oizo","title":"Lambs Anger"},
              {"dir":"\(root.path)/Lifted/Trellis","artist":"Lifted","title":"Trellis"},
              {"dir":"\(root.path)/Nobody/Nothing","artist":"Nobody","title":"Nothing"}]}
            """
        let scope = try BatchScope.published(try JSONDecoder().decode(
            Manifest.self, from: Data(json.utf8)))

        let all = surveyBatch(scope, needle: "")
        #expect(all.total == 3)
        #expect(all.groups.count == 2, "the release with only a .txt is not a group")
        #expect(all.emptyRoots == 1, "but it is counted, because 'nothing matched' is news")
        // Named from the manifest, and in name order — a list of paths is a
        // much worse answer to "what will this touch" than a list of records.
        #expect(all.groups.map(\.name) == ["Lifted — Trellis", "Mr.Oizo — Lambs Anger"])
        #expect(all.groups[0].files == ["Lifted/Trellis/cover.jpg"])

        let covers = surveyBatch(scope, needle: "cover")
        #expect(covers.total == 2)
        #expect(covers.groups.allSatisfy { $0.files.allSatisfy { $0.hasSuffix("cover.jpg") } })

        // The survey and the run must agree, or the count on the button is a lie.
        #expect(covers.total == findImages(in: scope, needle: "cover").count)
        #expect(all.total == findImages(in: scope, needle: "").count)
    }

    @Test func aFolderScopeIsNamedByItsOwnShapeSinceNoManifestNamesIt() throws {
        let root = tmpdir("survey-folder")
        let d = root.appendingPathComponent("Artist/Release")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: d.appendingPathComponent("cover.png"))
        let s = surveyBatch(.folder(root), needle: "")
        #expect(s.total == 1)
        #expect(s.groups.count == 1)
        #expect(s.groups[0].files == ["Artist/Release/cover.png"])
    }

    @Test func aFileUnderTwoRootsIsCountedOnce() throws {
        let root = tmpdir("survey-dupes")
        let inner = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inner.appendingPathComponent("cover.png"))
        let scope = BatchScope(roots: [root, inner], strip: root, guardRoot: root)
        let s = surveyBatch(scope, needle: "")
        #expect(s.total == 1, "the count must match what a run writes")
        #expect(s.total == findImages(in: scope, needle: "").count)
    }

    @Test func anEmptyImageIsAnErrorRatherThanABlankFile() {
        #expect(throws: BatchError.emptyImage) {
            _ = try batchRender(Raster(empty: 0, height: 0),
                                recipe: Recipe(canvas: 20, framing: .cover, disc: nil))
        }
    }
}
