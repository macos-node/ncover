import Foundation
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
        // path full of `..` that would escape the output folder.
        #expect(relativePath(of: URL(fileURLWithPath: "/elsewhere/cover.png"),
                             under: strip) == "cover.png")
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
        let out = try batchRender(src, recipe: r)
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
            try batchRender(try Raster.load(contentsOf: hit), recipe: recipe).writePNG(to: dest)
        }

        let written = out.appendingPathComponent("Autechre/Amber/cover-disc.png")
        #expect(FileManager.default.fileExists(atPath: written.path))
        let back = try Raster.load(contentsOf: written)
        #expect(back.width == 200 && back.height == 200, "the canvas we asked for")
        #expect(back.sample(100, 100) == RGBA(255, 0, 0, 255))
        #expect(back.sample(1, 1).a == 0, "alpha survives the file, corners and all")
        #expect(try Data(contentsOf: original) == before, "the original is untouched")
    }

    @Test func anEmptyImageIsAnErrorRatherThanABlankFile() {
        #expect(throws: BatchError.emptyImage) {
            _ = try batchRender(Raster(empty: 0, height: 0),
                                recipe: Recipe(canvas: 20, framing: .cover, disc: nil))
        }
    }
}
