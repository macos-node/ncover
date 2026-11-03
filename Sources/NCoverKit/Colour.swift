import Foundation

// The colour half of the app, as values.
//
// `RGB` itself lives in Raster.swift, because the renderers need it. What is
// here is everything a *person* does with a colour: write it down, name it,
// collect it. None of it knows about AppKit, so all of it is testable against
// the GTK app that specified it.

/// How a colour is written when it is copied or shown.
public enum ColorFormat: String, Codable, CaseIterable, Sendable {
    case hex, rgb, hsl

    public var label: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        }
    }
}

extension RGB {
    /// `#RRGGBB` or bare `RRGGBB`. Three-digit shorthand is deliberately not
    /// accepted here — this parses what we *write*. The lenient parser that
    /// takes `#abc` is `parseSVGColor`, where the input is someone else's file.
    public init?(hex s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        self.init(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    /// Uppercase, with the hash. Uppercase because it is the form the GTK app
    /// writes and the tests inherited from it assert on.
    public var hex: String { String(format: "#%02X%02X%02X", Int(r), Int(g), Int(b)) }

    public var rgbText: String { "rgb(\(r), \(g), \(b))" }

    public var hslText: String {
        let (h, s, l) = hsl
        return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }

    public var hsl: (h: Double, s: Double, l: Double) { rgbToHSL(r, g, b) }

    public func text(_ f: ColorFormat) -> String {
        switch f {
        case .hex: return hex
        case .rgb: return rgbText
        case .hsl: return hslText
        }
    }

    /// Perceived lightness, for deciding whether a label drawn on this colour
    /// should be black or white. Rec. 601 luma — not the most modern formula,
    /// and far more than good enough to pick one of two text colours.
    public var isLight: Bool {
        (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255 > 0.6
    }
}

public func rgbToHSL(_ r8: UInt8, _ g8: UInt8, _ b8: UInt8) -> (h: Double, s: Double, l: Double) {
    let r = Double(r8) / 255, g = Double(g8) / 255, b = Double(b8) / 255
    let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
    let l = (maxC + minC) / 2
    let d = maxC - minC
    guard d > 1e-6 else { return (0, 0, l) }
    let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
    let h: Double
    if abs(maxC - r) < 1e-6 {
        h = ((g - b) / d + (g < b ? 6 : 0)) * 60
    } else if abs(maxC - g) < 1e-6 {
        h = ((b - r) / d + 2) * 60
    } else {
        h = ((r - g) / d + 4) * 60
    }
    return (h, s, l)
}

// MARK: - swatches and palettes

/// A colour in a palette.
///
/// `RGB` stays a bare triple — it is also the history's element, and a picked
/// colour has no name. A *palette* entry is different: it usually came from
/// somewhere that named it (a design token, a GIMP swatch), and throwing that
/// name away throws away the only thing that says what the colour is FOR.
///
/// The coding keys are flat — `{"r":…,"g":…,"b":…,"name":…}` — which is the
/// shape the GTK app writes, so a palette exported there imports here and back
/// without a conversion step.
public struct Swatch: Codable, Equatable, Sendable {
    public var rgb: RGB
    public var name: String?

    public init(_ rgb: RGB, name: String? = nil) {
        self.rgb = rgb; self.name = name
    }

    private enum K: String, CodingKey { case r, g, b, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        rgb = RGB(try c.decode(UInt8.self, forKey: .r),
                  try c.decode(UInt8.self, forKey: .g),
                  try c.decode(UInt8.self, forKey: .b))
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(rgb.r, forKey: .r)
        try c.encode(rgb.g, forKey: .g)
        try c.encode(rgb.b, forKey: .b)
        // Absent rather than null, so a reader that predates names still loads it.
        try c.encodeIfPresent(name, forKey: .name)
    }

    /// What to show on the swatch: its name if it has one, else its hex.
    public var caption: String { name ?? rgb.hex }
}

/// A named list of swatches. Identified **by name**, because that is what the
/// pinned list stores and what an exported file is called — two palettes with
/// the same name would be the same palette as far as pinning is concerned, so
/// the store keeps names unique rather than letting the two meanings drift.
public struct Palette: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var colors: [Swatch]

    public init(name: String, colors: [Swatch]) {
        self.name = name; self.colors = colors
    }

    public var id: String { name }
}
