import AppKit
import Foundation

// `.clr` — NSColorList, macOS's own palette format.
//
// This is the one format in the set that is here because of the platform
// rather than because of the GTK app. A Mac already has colour lists: the
// Colours panel's "Colour Palettes" tab is a list of them, Keynote and
// Pixelmator write them, and `~/Library/Colors` is where they live. An app
// that can read .gpl but not .clr is asking its user to convert their own
// files to talk to it.
//
// Which is also why export offers "install into ~/Library/Colors": a palette
// written there shows up in the Colours panel of *every* app, not just this
// one. That is the whole point of using the system's format.

/// Where macOS looks for the user's colour lists.
public func userColorListsDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Colors", isDirectory: true)
}

public func readColorList(at url: URL) throws -> Palette {
    let stem = url.deletingPathExtension().lastPathComponent
    guard let list = NSColorList(name: stem, fromFile: url.path) else {
        throw PaletteError.notAPalette("macOS could not read it as a colour list")
    }
    var colors: [Swatch] = []
    for key in list.allKeys {
        guard let c = list.color(withKey: key)?.usingColorSpace(.sRGB) else { continue }
        let rgb = RGB(UInt8((c.redComponent * 255).rounded().clamped(0, 255)),
                      UInt8((c.greenComponent * 255).rounded().clamped(0, 255)),
                      UInt8((c.blueComponent * 255).rounded().clamped(0, 255)))
        // A key that is just the colour's own hex carries no information, so
        // it is dropped rather than stored as a name — that is what `writeGPL`
        // and the swatch captions already do for an unnamed colour.
        let name = (key as String) == rgb.hex ? nil : (key as String)
        colors.append(Swatch(rgb, name: name))
    }
    guard !colors.isEmpty else { throw PaletteError.noColours }
    return Palette(name: stem, colors: colors)
}

/// Write a `.clr`. Nameless swatches get their hex as the key, and a duplicate
/// key gets a numeric suffix — NSColorList is a *dictionary*, so two swatches
/// under one key would silently become one.
public func writeColorList(_ pal: Palette, to url: URL) throws {
    let list = NSColorList(name: pal.name.isEmpty ? "Palette" : pal.name)
    var used = Set<String>()
    for sw in pal.colors {
        var key = sw.name ?? sw.rgb.hex
        if used.contains(key) {
            var n = 2
            while used.contains("\(key) \(n)") { n += 1 }
            key = "\(key) \(n)"
        }
        used.insert(key)
        list.setColor(NSColor(srgbRed: Double(sw.rgb.r) / 255,
                              green: Double(sw.rgb.g) / 255,
                              blue: Double(sw.rgb.b) / 255,
                              alpha: 1),
                      forKey: key)
    }
    try list.write(to: url)
}

/// Install a palette as a system colour list, where every app's Colours panel
/// will find it. Returns where it landed.
@discardableResult
public func installColorList(_ pal: Palette) throws -> URL {
    let dir = userColorListsDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(sanitize(pal.name.isEmpty ? "Palette" : pal.name))
        .appendingPathExtension("clr")
    try writeColorList(pal, to: url)
    return url
}

/// Every colour list macOS knows about, by name. Used to offer the user's
/// existing palettes for import without making them find the files.
public func systemColorListNames() -> [String] {
    NSColorList.availableColorLists.compactMap(\.name)
}

/// One of those lists, as a palette.
public func paletteFromSystemColorList(named name: String) -> Palette? {
    guard let list = NSColorList.availableColorLists.first(where: { $0.name == name })
    else { return nil }
    var colors: [Swatch] = []
    for key in list.allKeys {
        guard let c = list.color(withKey: key)?.usingColorSpace(.sRGB) else { continue }
        let rgb = RGB(UInt8((c.redComponent * 255).rounded().clamped(0, 255)),
                      UInt8((c.greenComponent * 255).rounded().clamped(0, 255)),
                      UInt8((c.blueComponent * 255).rounded().clamped(0, 255)))
        colors.append(Swatch(rgb, name: (key as String) == rgb.hex ? nil : (key as String)))
    }
    return colors.isEmpty ? nil : Palette(name: name, colors: colors)
}
