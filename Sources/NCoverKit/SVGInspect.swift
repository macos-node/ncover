import Foundation

// Reading an SVG rather than looking at it.
//
// An SVG *states* its colours; a PNG only implies them. So for an SVG we do
// not sample pixels and guess — we read the declared fills, strokes and
// gradient stops out of the file. That is the difference between "roughly
// these tones" and "these exact values, and here is where each one is used".
//
// Also surfaced: the fonts it asks for, the text it contains, and what it is
// made of. For label art that is most of what you want to know before you
// touch anything.

public struct SVGInfo: Equatable, Sendable {
    public var viewBox: String?
    public var width: String?
    public var height: String?
    /// Element tag -> count, most common first.
    public var elements: [(tag: String, count: Int)] = []
    /// `font-family` values, in first-seen order.
    public var fonts: [String] = []
    /// The actual text content — for label art, this is the copy.
    public var texts: [String] = []
    public var gradients = 0
    /// Declared colours, most-used first, with a use count.
    public var colors: [(rgb: RGB, count: Int)] = []

    public init() {}

    public static func == (a: SVGInfo, b: SVGInfo) -> Bool {
        a.viewBox == b.viewBox && a.width == b.width && a.height == b.height
            && a.elements.elementsEqual(b.elements, by: ==)
            && a.fonts == b.fonts && a.texts == b.texts && a.gradients == b.gradients
            && a.colors.elementsEqual(b.colors, by: ==)
    }

    /// The declared colours as a palette, ready to keep.
    public func palette(named name: String) -> Palette {
        Palette(name: name, colors: colors.map { Swatch($0.rgb) })
    }
}

/// The CSS named colours worth bothering with. A full table is 148 entries and
/// mostly noise; these are the ones that actually show up in exported SVG.
func namedColor(_ s: String) -> RGB? {
    switch s {
    case "black":              return RGB(0, 0, 0)
    case "white":              return RGB(255, 255, 255)
    case "red":                return RGB(255, 0, 0)
    case "lime", "green":      return RGB(0, 128, 0)
    case "blue":               return RGB(0, 0, 255)
    case "yellow":             return RGB(255, 255, 0)
    case "cyan", "aqua":       return RGB(0, 255, 255)
    case "magenta", "fuchsia": return RGB(255, 0, 255)
    case "gray", "grey":       return RGB(128, 128, 128)
    case "silver":             return RGB(192, 192, 192)
    case "orange":             return RGB(255, 165, 0)
    default:                   return nil
    }
}

/// Parse one colour token: `#rgb`, `#rrggbb`, `rgb(r,g,b)`, or a named colour.
///
/// `none`, `currentColor` and `url(#grad)` are **not** colours — they are
/// absences or references, and inventing a value for them would put a colour
/// in the palette that the file never declares.
public func parseSVGColor(_ raw: String) -> RGB? {
    let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if v.isEmpty || v.lowercased() == "none" || v.hasPrefix("url(") { return nil }

    if v.hasPrefix("#") {
        let hex = String(v.dropFirst())
        if hex.count == 3 {
            let digits = hex.map { $0.hexDigitValue }
            guard digits.count == 3, let r = digits[0], let g = digits[1], let b = digits[2]
            else { return nil }
            // #abc means #aabbcc, which is multiplying each digit by 17.
            return RGB(UInt8(r * 17), UInt8(g * 17), UInt8(b * 17))
        }
        return RGB(hex: v)
    }
    if v.hasPrefix("rgb("), v.hasSuffix(")") {
        let inner = v.dropFirst(4).dropLast()
        let parts = inner.split(separator: ",").compactMap {
            UInt8($0.trimmingCharacters(in: .whitespaces))
        }
        if parts.count == 3 { return RGB(parts[0], parts[1], parts[2]) }
        return nil
    }
    return namedColor(v.lowercased())
}

/// The colour-bearing presentation attributes. Also the keys we look for inside
/// a `style=""`, because the two are the same set spelled two ways.
let COLOR_ATTRS = ["fill", "stroke", "stop-color", "flood-color"]

/// Pull colour tokens out of a `style="fill:#abc;stroke:red"` attribute.
func colorsInStyle(_ style: String, into out: inout [RGB]) {
    for decl in style.split(separator: ";") {
        guard let colon = decl.firstIndex(of: ":") else { continue }
        let k = decl[decl.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        guard COLOR_ATTRS.contains(k) else { continue }
        if let c = parseSVGColor(String(decl[decl.index(after: colon)...])) { out.append(c) }
    }
}

public func inspectSVG(_ text: String) throws -> SVGInfo {
    guard let data = text.data(using: .utf8) else {
        throw PaletteError.notAPalette("not valid text")
    }
    // External entities are refused: this parses a file the user opened, and
    // an SVG that can fetch a URL or read /etc/passwd while being inspected is
    // a vulnerability, not a feature.
    let doc: XMLDocument
    do {
        doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    } catch {
        throw ImageError.cannotDecode("not valid XML/SVG")
    }
    guard let root = doc.rootElement() else {
        throw ImageError.cannotDecode("the SVG has no root element")
    }

    var info = SVGInfo()
    info.viewBox = root.attribute(forName: "viewBox")?.stringValue
    info.width = root.attribute(forName: "width")?.stringValue
    info.height = root.attribute(forName: "height")?.stringValue

    var tags: [String: Int] = [:]
    var counts: [RGB: Int] = [:]

    // The root counts as an element too — it carries attributes like any other,
    // and a `fill` on the `<svg>` is a declared colour.
    for el in elementsIncludingSelf(root) {
        let tag = el.localName ?? el.name ?? ""
        tags[tag, default: 0] += 1
        if tag.hasSuffix("Gradient") { info.gradients += 1 }

        var found: [RGB] = []
        for a in COLOR_ATTRS {
            if let v = el.attribute(forName: a)?.stringValue, let c = parseSVGColor(v) {
                found.append(c)
            }
        }
        if let st = el.attribute(forName: "style")?.stringValue {
            colorsInStyle(st, into: &found)
        }
        for c in found { counts[c, default: 0] += 1 }

        if let f = el.attribute(forName: "font-family")?.stringValue {
            let name = f.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if !name.isEmpty, !info.fonts.contains(name) { info.fonts.append(name) }
        }

        if tag == "text" || tag == "tspan" {
            let t = textContent(el).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !t.isEmpty, !info.texts.contains(t) { info.texts.append(t) }
        }
    }

    // Ties broken by name / hex, so the order is the same on every run. The
    // GTK app's HashMap left ties arbitrary; this is the one place the two
    // deliberately differ, and only where it had no answer.
    info.elements = tags.map { (tag: $0.key, count: $0.value) }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    info.colors = counts.map { (rgb: $0.key, count: $0.value) }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.rgb.hex < $1.rgb.hex }
    return info
}

/// Depth-first, the element and everything under it.
private func elementsIncludingSelf(_ el: XMLElement) -> [XMLElement] {
    var out: [XMLElement] = [el]
    for child in el.children ?? [] {
        if let e = child as? XMLElement { out.append(contentsOf: elementsIncludingSelf(e)) }
    }
    return out
}

/// Every text node under an element, concatenated.
///
/// Only *text* nodes: asking an element for its own string value returns its
/// first text child, so mixing the two collects the same string twice.
private func textContent(_ node: XMLNode) -> String {
    if node.kind == .text { return node.stringValue ?? "" }
    return (node.children ?? []).map(textContent).joined()
}

extension RGB: Hashable {
    public func hash(into h: inout Hasher) { h.combine(r); h.combine(g); h.combine(b) }
}
