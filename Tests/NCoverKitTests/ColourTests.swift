import Foundation
import XCTest

@testable import NCoverKit

// Ported from the GTK app's `gpl_tests`, `svg_tests` and `pin_tests`, keeping
// the original names and expected values. Where a test asserts on something
// this app does differently on purpose, it is deleted rather than weakened —
// a loosened assertion hides a regression, a deleted one records a decision.

final class GPLTests: XCTestCase {
    func testReadsANamedPaletteAndKeepsTheNames() throws {
        let text = """
            GIMP Palette
            Name: fizx.uk
            Columns: 0
            #
            # a comment
              9  13  18\t#090D12\tbg
            122 240 205\t#7AF0CD\taccent

            """
        let p = try readGPL(text)
        XCTAssertEqual(p.name, "fizx.uk")
        XCTAssertEqual(p.colors.count, 2)
        XCTAssertEqual(p.colors[0].rgb, RGB(9, 13, 18))
        XCTAssertEqual(p.colors[0].name, "bg")
        XCTAssertEqual(p.colors[1].name, "accent")
    }

    func testReadsAPlainGimpPaletteWithNoNames() throws {
        // komodo.gpl's shape — the format most tools actually emit.
        let p = try readGPL("GIMP Palette\nName: komodo\nColumns: 0\n#\n 29 153 142\t#1D998E\n")
        XCTAssertEqual(p.colors.count, 1)
        XCTAssertNil(p.colors[0].name)
    }

    func testToleratesNamesWithSpacesAndAMissingHexColumn() throws {
        let p = try readGPL("GIMP Palette\nName: x\n#\n10 20 30 deep sea blue\n")
        XCTAssertEqual(p.colors[0].name, "deep sea blue")
    }

    func testAFileWithNoColoursIsAnErrorNotAnEmptyPalette() {
        XCTAssertThrowsError(try readGPL("GIMP Palette\nName: empty\n#\n"))
    }

    func testRoundTripsThroughWriteGPL() throws {
        let pal = Palette(name: "rt", colors: [
            Swatch(RGB(1, 2, 3), name: "one"),
            Swatch(RGB(4, 5, 6)),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ncover-gpl-rt.gpl")
        try writeGPL(pal, to: url)
        let back = try readGPL(String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(back.name, pal.name)
        XCTAssertEqual(back.colors, pal.colors)
    }

    /// Not in the GTK app: `.clr` is macOS's own format and has no counterpart
    /// there. It goes through NSColorList, so the round trip is also a check
    /// that AppKit kept our colours in sRGB and in order.
    func testRoundTripsThroughAColorList() throws {
        let pal = Palette(name: "clr-rt", colors: [
            Swatch(RGB(9, 13, 18), name: "bg"),
            Swatch(RGB(122, 240, 205), name: "accent"),
            Swatch(RGB(255, 0, 0)),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ncover-rt.clr")
        try writeColorList(pal, to: url)
        let back = try readColorList(at: url)
        XCTAssertEqual(back.colors, pal.colors)
        // An unnamed swatch is keyed by its own hex, which carries no
        // information and must not come back as a name.
        XCTAssertNil(back.colors[2].name)
    }

    func testCSSUsesSwatchNamesAndFallsBackToTheIndex() throws {
        let pal = Palette(name: "fizx.uk", colors: [
            Swatch(RGB(9, 13, 18), name: "bg"),
            Swatch(RGB(255, 255, 255)),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ncover-rt.css")
        try writeCSS(pal, to: url)
        let css = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(css.contains("--fizx_uk-bg: #090d12;"), css)
        XCTAssertTrue(css.contains("--fizx_uk-2: #ffffff;"), css)
    }

    /// The JSON is the GTK app's, so a palette exported there imports here.
    func testJSONIsTheSharedShape() throws {
        let json = #"{"name":"shared","colors":[{"r":1,"g":2,"b":3,"name":"one"},{"r":4,"g":5,"b":6}]}"#
        let pal = try JSONDecoder().decode(Palette.self, from: Data(json.utf8))
        XCTAssertEqual(pal.colors, [Swatch(RGB(1, 2, 3), name: "one"), Swatch(RGB(4, 5, 6))])
        // And back out: a nameless swatch writes no `name` key at all.
        let out = String(decoding: try JSONEncoder().encode(pal), as: UTF8.self)
        XCTAssertFalse(out.contains("null"), out)
    }
}

final class ColourFormatTests: XCTestCase {
    func testHexIsUppercaseAndRoundTrips() {
        XCTAssertEqual(RGB(9, 13, 18).hex, "#090D12")
        XCTAssertEqual(RGB(hex: "#7af0cd"), RGB(122, 240, 205))
        XCTAssertEqual(RGB(hex: "7AF0CD"), RGB(122, 240, 205))
        XCTAssertNil(RGB(hex: "#abc"), "three-digit is SVG's lenient form, not ours")
    }

    func testTheThreeWrittenForms() {
        let c = RGB(122, 240, 205)
        XCTAssertEqual(c.text(.hex), "#7AF0CD")
        XCTAssertEqual(c.text(.rgb), "rgb(122, 240, 205)")
        XCTAssertEqual(c.text(.hsl), "hsl(162, 80%, 71%)")
    }

    func testGreyHasNoHue() {
        let (h, s, l) = RGB(128, 128, 128).hsl
        XCTAssertEqual(h, 0)
        XCTAssertEqual(s, 0)
        XCTAssertEqual(l, 128.0 / 255.0, accuracy: 1e-9)
    }
}

final class SVGInspectTests: XCTestCase {
    static let sample = """
        <svg viewBox="0 0 100 50" width="100" height="50">
          <defs><linearGradient id="g">
            <stop offset="0" stop-color="#ff0000"/>
            <stop offset="1" stop-color="rgb(0, 0, 255)"/>
          </linearGradient></defs>
          <rect fill="#abc" stroke="black" x="0" y="0"/>
          <rect fill="url(#g)"/>
          <path fill="none" stroke="#ff0000"/>
          <text font-family="Helvetica" fill="white">Label Art</text>
        </svg>
        """

    func testReadsTheDeclaredColoursNotThePixels() throws {
        let i = try inspectSVG(Self.sample)
        let hexes = i.colors.map(\.rgb.hex)
        XCTAssertTrue(hexes.contains("#FF0000"))  // stop-color + stroke
        XCTAssertTrue(hexes.contains("#0000FF"))  // rgb(...) form
        XCTAssertTrue(hexes.contains("#AABBCC"))  // #abc shorthand expands
        XCTAssertTrue(hexes.contains("#000000"))  // named "black"
        XCTAssertTrue(hexes.contains("#FFFFFF"))  // named "white"
        // #ff0000 is used twice (a stop and a stroke) and must rank first.
        XCTAssertEqual(i.colors[0].rgb.hex, "#FF0000")
        XCTAssertEqual(i.colors[0].count, 2)
    }

    func testNoneAndURLRefsAreNotColours() {
        XCTAssertNil(parseSVGColor("none"))
        XCTAssertNil(parseSVGColor("url(#g)"))
        XCTAssertNil(parseSVGColor("currentColor"))
    }

    func testReadsFontsTextAndStructure() throws {
        let i = try inspectSVG(Self.sample)
        XCTAssertEqual(i.fonts, ["Helvetica"])
        XCTAssertEqual(i.texts, ["Label Art"])
        XCTAssertEqual(i.gradients, 1)
        XCTAssertEqual(i.viewBox, "0 0 100 50")
        XCTAssertEqual(i.elements.first(where: { $0.tag == "rect" })?.count, 2)
    }

    func testAStyleAttributeIsReadToo() throws {
        let i = try inspectSVG(#"<svg><rect style="fill:#123456;stroke:none"/></svg>"#)
        XCTAssertEqual(i.colors.count, 1)
        XCTAssertEqual(i.colors[0].rgb.hex, "#123456")
    }

    func testAMalformedFileIsAnErrorNotAnEmptyResult() {
        XCTAssertThrowsError(try inspectSVG("<svg><rect"))
    }
}

final class PinTests: XCTestCase {
    func testPinToFrontIsRecencyDedupedAndCapped() {
        var d = ColorData()
        for n in ["a", "b", "c"] { pinToFront(&d, n) }
        XCTAssertEqual(d.pinned, ["c", "b", "a"], "newest first")
        // Re-using an existing one moves it to the front, does not duplicate.
        pinToFront(&d, "a")
        XCTAssertEqual(d.pinned, ["a", "c", "b"])
        // A fourth drops the oldest — the picker holds a few, not a library.
        pinToFront(&d, "d")
        XCTAssertEqual(d.pinned, ["d", "a", "c"])
        XCTAssertLessThanOrEqual(d.pinned.count, PINNED_MAX)
    }

    func testTogglePinAddsThenRemoves() {
        var d = ColorData()
        XCTAssertTrue(togglePin(&d, "x"), "first toggle pins")
        XCTAssertTrue(isPinned(d, "x"))
        XCTAssertFalse(togglePin(&d, "x"), "second toggle unpins")
        XCTAssertFalse(isPinned(d, "x"))
        XCTAssertTrue(d.pinned.isEmpty)
    }
}

final class ColorStoreTests: XCTestCase {
    func testHistoryIsRecencyDedupedAndCapped() {
        var d = ColorData()
        d.remember(RGB(1, 1, 1))
        d.remember(RGB(2, 2, 2))
        d.remember(RGB(1, 1, 1))
        XCTAssertEqual(d.history, [RGB(1, 1, 1), RGB(2, 2, 2)], "a repeat moves, it does not add")

        for i in 0..<64 { d.remember(RGB(UInt8(i % 200), 9, 9)) }
        XCTAssertEqual(d.history.count, HISTORY_LIMIT)
        XCTAssertEqual(d.historyPalette.count, HISTORY_PALETTE)
    }

    func testPaletteNamesAreKeptUnique() {
        var d = ColorData()
        XCTAssertEqual(d.add(Palette(name: "Brand", colors: [Swatch(RGB.black)])), "Brand")
        XCTAssertEqual(d.add(Palette(name: "Brand", colors: [Swatch(RGB.white)])), "Brand 2")
        XCTAssertEqual(d.add(Palette(name: "", colors: [Swatch(RGB.white)])), "Palette")
    }

    func testRenamingFollowsThePinAndRefusesACollision() {
        var d = ColorData()
        d.add(Palette(name: "Brand", colors: [Swatch(RGB.black)]))
        d.add(Palette(name: "Other", colors: [Swatch(RGB.white)]))
        pinToFront(&d, "Brand")

        XCTAssertFalse(d.rename("Brand", to: "Other"), "a taken name is refused, not suffixed")
        XCTAssertTrue(d.rename("Brand", to: "Marque"))
        XCTAssertEqual(d.pinned, ["Marque"], "the pin follows the palette")
        XCTAssertNotNil(d.palette(named: "Marque"))
    }

    func testRemovingAPaletteUnpinsIt() {
        var d = ColorData()
        d.add(Palette(name: "Brand", colors: [Swatch(RGB.black)]))
        pinToFront(&d, "Brand")
        d.remove("Brand")
        XCTAssertTrue(d.palettes.isEmpty)
        XCTAssertTrue(d.pinned.isEmpty, "a pin pointing at nothing would render as a blank strip")
    }

    func testTheStoreSurvivesAFileItHasNeverSeen() throws {
        // Every field optional: the file is shared with the GTK app and with
        // older versions of this one.
        let d = try JSONDecoder().decode(ColorData.self, from: Data(#"{"history":[]}"#.utf8))
        XCTAssertEqual(d.format, .hex)
        XCTAssertEqual(d.canvas, CANVAS_DEFAULT)
        // And a canvas size we do not offer is ignored rather than honoured.
        let odd = try JSONDecoder().decode(ColorData.self, from: Data(#"{"canvas":1234}"#.utf8))
        XCTAssertEqual(odd.canvas, CANVAS_DEFAULT)
    }
}

final class QuantiseTests: XCTestCase {
    /// A raster of two colours in known proportion.
    private func twoTone() -> Raster {
        var r = Raster(empty: 10, height: 10)
        for y in 0..<10 {
            for x in 0..<10 {
                r.set(x, y, y < 7 ? RGBA(200, 30, 40, 255) : RGBA(20, 60, 220, 255))
            }
        }
        return r
    }

    func testDominantColoursComeBackMostUsedFirst() {
        let got = dominantColors(twoTone(), want: 4)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0], RGB(200, 30, 40))
        XCTAssertEqual(got[1], RGB(20, 60, 220))
    }

    func testTransparentPixelsAreNotColours() {
        var r = Raster(empty: 4, height: 4)
        for x in 0..<4 { r.set(x, 0, RGBA(255, 0, 0, 255)) }
        // The other twelve pixels are alpha 0 and must contribute nothing —
        // otherwise every palette from an alpha-edged image is mostly black.
        XCTAssertEqual(dominantColors(r, want: 8), [RGB(255, 0, 0)])
    }

    func testTheRepresentativeIsAColourTheImageContains() {
        // Two near-identical reds land in one bin. The answer is their mean,
        // which is a colour in the picture — not the bin's centre, which is not.
        var r = Raster(empty: 2, height: 1)
        r.set(0, 0, RGBA(240, 16, 16, 255))
        r.set(1, 0, RGBA(242, 18, 18, 255))
        XCTAssertEqual(dominantColors(r, want: 2), [RGB(241, 17, 17)])
    }
}
