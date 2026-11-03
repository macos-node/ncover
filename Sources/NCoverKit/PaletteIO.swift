import Foundation

// Reading and writing palettes.
//
// Four formats, and the reason each is here:
//
//   .gpl   GIMP's, and the one every other colour tool speaks. Interchange.
//   .json  what this app writes, so a palette round-trips without loss. The
//          shape is the GTK app's, so the two apps' exports are the same file.
//   .css   custom properties, write-only. The destination is a stylesheet.
//   .clr   NSColorList — macOS's own. In PaletteIO+ColorList.swift, because it
//          needs AppKit and none of the rest of this does.

public enum PaletteError: LocalizedError, Equatable {
    case noColours
    case notAPalette(String)

    public var errorDescription: String? {
        switch self {
        case .noColours:
            return "No colours found — is this a GIMP palette (.gpl)?"
        case .notAPalette(let why):
            return "Not a palette file: \(why)"
        }
    }
}

/// Parse a GIMP palette.
///
/// Deliberately tolerant: the format is old and every tool emits a slightly
/// different dialect. We need three integers; a hex column and a name are both
/// optional, and anything after the hex is the name — GIMP's own convention,
/// and what `writeGPL` emits. A line that is not a colour is skipped rather
/// than failing the import, because one odd line in a file of ninety is not a
/// reason to hand back nothing.
public func readGPL(_ text: String) throws -> Palette {
    var name = ""
    var colors: [Swatch] = []

    for rawLine in text.components(separatedBy: .newlines) {
        let t = rawLine.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { continue }
        if t.lowercased() == "gimp palette" { continue }
        if let rest = t.dropPrefixIfPresent("Name:") {
            name = rest.trimmingCharacters(in: .whitespaces)
            continue
        }
        if t.hasPrefix("Columns:") { continue }

        var fields = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 3,
              let r = UInt8(fields[0]), let g = UInt8(fields[1]), let b = UInt8(fields[2])
        else { continue }
        fields.removeFirst(3)
        // Whatever remains is a hex column and/or a name. Drop a leading hex
        // token; keep the rest verbatim, because names contain spaces.
        if let first = fields.first, first.hasPrefix("#") { fields.removeFirst() }
        let label = fields.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        colors.append(Swatch(RGB(r, g, b), name: label.isEmpty ? nil : label))
    }

    guard !colors.isEmpty else { throw PaletteError.noColours }
    return Palette(name: name.isEmpty ? "Imported" : name, colors: colors)
}

public func writeGPL(_ pal: Palette, to url: URL) throws {
    var out = "GIMP Palette\n"
    out += "Name: \(pal.name.isEmpty ? "Unnamed" : pal.name)\nColumns: 0\n#\n"
    for s in pal.colors {
        let c = s.rgb
        let triple = String(format: "%3d %3d %3d", Int(c.r), Int(c.g), Int(c.b))
        // GIMP treats everything after the hex as the swatch name, so a named
        // swatch round-trips through .gpl without a custom format.
        if let n = s.name {
            out += "\(triple)\t\(c.hex)\t\(n)\n"
        } else {
            out += "\(triple)\t\(c.hex)\n"
        }
    }
    try out.write(to: url, atomically: true, encoding: .utf8)
}

public func writeCSS(_ pal: Palette, to url: URL) throws {
    var out = ":root {\n"
    let stem = sanitize(pal.name.isEmpty ? "palette" : pal.name)
    for (i, sw) in pal.colors.enumerated() {
        // A named swatch exports as its own name — the whole point of keeping
        // it. Unnamed ones fall back to the positional index.
        let key = sw.name.map(sanitize) ?? String(i + 1)
        out += "  --\(stem)-\(key): \(sw.rgb.hex.lowercased());\n"
    }
    out += "}\n"
    try out.write(to: url, atomically: true, encoding: .utf8)
}

public func writeJSON(_ pal: Palette, to url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(pal).write(to: url, options: .atomic)
}

/// Import a palette, picking the reader by extension.
public func readPalette(at url: URL) throws -> Palette {
    switch url.pathExtension.lowercased() {
    case "json":
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Palette.self, from: data)
        } catch {
            throw PaletteError.notAPalette(error.localizedDescription)
        }
    case "clr":
        return try readColorList(at: url)
    default:
        return try readGPL(String(contentsOf: url, encoding: .utf8))
    }
}

/// What a palette can be read from and written to. `.clr` is here for both:
/// macOS has had a colour-list format since before the GIMP one, and an app
/// that cannot read the lists the user already has in Colours is not speaking
/// the platform's language.
public let PALETTE_READ_EXTS = ["gpl", "json", "clr"]
public let PALETTE_WRITE_EXTS = ["gpl", "json", "css", "clr"]

/// Filename-safe, and the stem of a CSS custom property.
public func sanitize(_ s: String) -> String {
    let mapped = String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    return mapped.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

extension String {
    fileprivate func dropPrefixIfPresent(_ p: String) -> String? {
        hasPrefix(p) ? String(dropFirst(p.count)) : nil
    }
}
