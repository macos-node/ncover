import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import NCoverKit

// The write layer: JPEG, the alpha rule, the in-place replace, and the
// header-only size read. Phase A of docs/gtk-parity-plan.md.

private func tmpdir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("ncover-write-\(name)")
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// An opaque raster of one colour.
private func flat(_ w: Int, _ h: Int, _ c: RGBA) -> Raster {
    var r = Raster(empty: w, height: h)
    for i in stride(from: 0, to: r.px.count, by: 4) {
        r.px[i] = c.r; r.px[i + 1] = c.g; r.px[i + 2] = c.b; r.px[i + 3] = c.a
    }
    return r
}

@Suite("write formats")
struct WriteFormatTests {
    @Test func opacityIsAboutEveryPixel() {
        #expect(flat(4, 4, RGBA(10, 20, 30, 255)).isOpaque)
        var one = flat(4, 4, RGBA(10, 20, 30, 255))
        one.px[7] = 254    // a single pixel, one step off opaque
        #expect(!one.isOpaque, "one pixel is enough — a disc's rim is exactly this")
        #expect(!Raster(empty: 4, height: 4).isOpaque, "a blank canvas is transparent")
    }

    @Test func aJPEGIsRefusedRatherThanWrittenAsBlack() throws {
        // The reason this rule exists: ImageIO drops the alpha channel and
        // keeps the RGB bytes, and Raster zeroes RGB where alpha is 0 — so a
        // masked render would come back with BLACK corners and no error.
        let dir = tmpdir("alpha")
        var masked = flat(8, 8, RGBA(200, 40, 40, 255))
        masked.px[3] = 0; masked.px[0] = 0; masked.px[1] = 0; masked.px[2] = 0
        let out = dir.appendingPathComponent("cover.jpg")

        #expect(throws: ImageError.jpegHasAlpha) {
            try masked.writeJPEG(to: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path),
                "a refusal writes nothing at all")
    }

    @Test func discardWritesTheRGBAndForgetsTheChannel() throws {
        // What batch's keep-format jobs ask for: a JPEG source has no alpha to
        // lose, and the colour under a transparent pixel is carried through
        // rather than composited onto anything.
        let dir = tmpdir("discard")
        var r = flat(8, 8, RGBA(0, 160, 0, 255))
        r.px[3] = 0    // first pixel transparent, but its RGB is still green
        let out = dir.appendingPathComponent("cover.jpg")
        try r.writeJPEG(to: out, alpha: .discard)

        let back = try Raster.load(contentsOf: out)
        #expect(back.isOpaque, "a JPEG has no alpha channel to read back")
        let px = back.sample(0, 0)
        #expect(px.g > px.r && px.g > px.b, "the colour came through, not black")
    }

    @Test func aJPEGRoundTripsAtTheSharedQuality() throws {
        #expect(ImageFormat.jpegQuality == 0.92,
                "the GTK sibling's cap_format passes 92; a cover tidied on either should match")
        let dir = tmpdir("quality")
        let out = dir.appendingPathComponent("cover.jpg")
        try flat(64, 64, RGBA(30, 90, 200, 255)).writeJPEG(to: out)

        let back = try Raster.load(contentsOf: out)
        #expect(back.width == 64 && back.height == 64)
        let px = back.sample(32, 32)
        // Lossy, so near rather than equal — but near on a flat field.
        #expect(abs(Int(px.b) - 200) <= 4 && abs(Int(px.r) - 30) <= 4)
    }

    @Test func theFormatComesFromTheNameAndUnknownOnesAreNotGuessed() {
        #expect(ImageFormat.of(URL(fileURLWithPath: "/a/cover.PNG")) == .png)
        #expect(ImageFormat.of(URL(fileURLWithPath: "/a/cover.jpg")) == .jpeg)
        #expect(ImageFormat.of(URL(fileURLWithPath: "/a/cover.jpeg")) == .jpeg)
        // Refused with the reason, never converted behind the user's back.
        #expect(ImageFormat.of(URL(fileURLWithPath: "/a/cover.webp")) == nil)
        #expect(ImageFormat.of(URL(fileURLWithPath: "/a/cover.gif")) == nil)
        #expect(ImageFormat.of(URL(fileURLWithPath: "/a/cover.svg")) == nil)
        #expect(ImageFormat.of(URL(fileURLWithPath: "/a/cover")) == nil)
    }

    @Test func replacingAFileLeavesNoLeftoversBehind() throws {
        let dir = tmpdir("replace")
        let target = dir.appendingPathComponent("cover.png")
        try flat(8, 8, RGBA(255, 0, 0, 255)).writePNG(to: target)

        try flat(8, 8, RGBA(0, 0, 255, 255)).replaceFile(at: target, as: .png)
        #expect(try Raster.load(contentsOf: target).sample(4, 4) == RGBA(0, 0, 255, 255))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["cover.png"],
                "the sibling temp file is gone")
    }

    @Test func afailedReplaceLeavesTheOriginalWhole() throws {
        // The case this exists for: the target is usually a cover inside
        // someone's music library, and a half-written file there is worse than
        // no write. A refused JPEG is the failure that is easy to stage.
        let dir = tmpdir("failed")
        let target = dir.appendingPathComponent("cover.jpg")
        try flat(8, 8, RGBA(200, 40, 40, 255)).writeJPEG(to: target)
        let before = try Data(contentsOf: target)

        var masked = flat(8, 8, RGBA(0, 0, 0, 255))
        masked.px[3] = 0
        #expect(throws: ImageError.jpegHasAlpha) {
            try masked.replaceFile(at: target, as: .jpeg)
        }
        #expect(try Data(contentsOf: target) == before, "byte-for-byte as it was")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["cover.jpg"],
                "and no temp file left behind")
    }

    // Against a real library, because a synthetic corpus says nothing about
    // the thing this replaces — gdk-pixbuf reads far into a JPEG, and the
    // claim being made is that ImageIO does not. Off by default, like the GTK
    // side's real-catalogue tests:
    //   NCOVER_LIBRARY=~/Music/ndisc make test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NCOVER_LIBRARY"] != nil))
    func theHeaderReadIsFasterThanDecodingARealLibrary() throws {
        let root = URL(fileURLWithPath:
            (ProcessInfo.processInfo.environment["NCOVER_LIBRARY"]! as NSString)
                .expandingTildeInPath)
        var files: [URL] = []
        findImages(root: root, needle: "", into: &files)
        files = files.filter { ImageFormat.of($0) != nil }
        try #require(!files.isEmpty, "no PNG or JPEG under \(root.path)")

        var t = Date()
        let sizes = files.map { imageSize(of: $0) }
        let header = Date().timeIntervalSince(t)
        #expect(sizes.allSatisfy { $0 != nil }, "every cover answered from its header")

        t = Date()
        for f in files { _ = try? Raster.load(contentsOf: f) }
        let decode = Date().timeIntervalSince(t)

        print(String(format: "%d covers · header %.3fs (%.2f ms each) · decode %.3fs — %.0f×",
                     files.count, header, header / Double(files.count) * 1000,
                     decode, decode / max(header, 0.000001)))
        // The sizes must also be right, not merely quick.
        for (f, s) in zip(files, sizes) {
            let full = try Raster.load(contentsOf: f)
            #expect(s?.width == full.width && s?.height == full.height,
                    "header disagrees with the decode for \(f.lastPathComponent)")
        }
        #expect(header < decode, "the header read is the point")
    }

    @Test func theSizeComesFromTheHeaderForBothFormats() throws {
        let dir = tmpdir("dims")
        let png = dir.appendingPathComponent("a.png")
        let jpg = dir.appendingPathComponent("b.jpg")
        try flat(40, 25, RGBA(1, 2, 3, 255)).writePNG(to: png)
        try flat(600, 538, RGBA(1, 2, 3, 255)).writeJPEG(to: jpg)

        #expect(imageSize(of: png).map { [$0.width, $0.height] } == [40, 25])
        // The shape the review list is full of: a CD front insert, not square.
        #expect(imageSize(of: jpg).map { [$0.width, $0.height] } == [600, 538])
        // Nothing with a pixel size: answered as nil, not guessed at.
        let txt = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: txt)
        #expect(imageSize(of: txt) == nil)
        #expect(imageSize(of: dir.appendingPathComponent("absent.png")) == nil)
    }
}
