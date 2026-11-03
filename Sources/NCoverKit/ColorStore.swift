import Foundation

// What the app remembers between launches: the colours you picked, the
// palettes you keep, and which of them ride along on the picker.
//
// A JSON file rather than UserDefaults, for one reason that matters: palettes
// are the user's data, they are what an export produces, and they should be
// copyable, diffable and recoverable with a text editor. A plist buried in
// ~/Library/Preferences is none of those. It is also the same shape the GTK
// app writes, so the two can read each other's file.

/// How deep the colour history goes.
public let HISTORY_LIMIT = 32

/// How many of the most-recent history colours become the compact "History
/// palette" — a strip you scan at a glance, not the whole 32-deep list.
public let HISTORY_PALETTE = 10

/// How many palettes ride along on the picker beside the history.
public let PINNED_MAX = 3

/// Swatches per row before a palette wraps. Ten reads as a row you can count;
/// more and it becomes a wall.
public let SWATCHES_PER_ROW = 10

public struct ColorData: Codable, Equatable, Sendable {
    public var format: ColorFormat = .hex
    public var history: [RGB] = []
    public var palettes: [Palette] = []
    /// The palettes shown on the picker, most-recent first, **by name**. Capped
    /// at `PINNED_MAX`. It is both "the last few you used" (using a palette's
    /// swatch moves it to the front) and "the ones you chose" (the palette list
    /// pins and unpins explicitly) — one list, so the two never fight.
    public var pinned: [String] = []
    /// The output canvas size, remembered. Anything not in `CANVAS_SIZES` is
    /// ignored on load.
    public var canvas: Int = CANVAS_DEFAULT

    public init() {}

    private enum K: String, CodingKey { case format, history, palettes, pinned, canvas }

    /// Every field optional on the way in. The file is shared with another app
    /// and with older versions of this one; a missing key is normal, not an
    /// error, and one unknown field must not cost someone their palettes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        format = try c.decodeIfPresent(ColorFormat.self, forKey: .format) ?? .hex
        history = try c.decodeIfPresent([RGB].self, forKey: .history) ?? []
        palettes = try c.decodeIfPresent([Palette].self, forKey: .palettes) ?? []
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        canvas = saneCanvas(try c.decodeIfPresent(Int.self, forKey: .canvas) ?? CANVAS_DEFAULT)
    }
}

extension RGB: Codable {
    private enum K: String, CodingKey { case r, g, b }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        self.init(try c.decode(UInt8.self, forKey: .r),
                  try c.decode(UInt8.self, forKey: .g),
                  try c.decode(UInt8.self, forKey: .b))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(r, forKey: .r); try c.encode(g, forKey: .g); try c.encode(b, forKey: .b)
    }
}

// MARK: - history

extension ColorData {
    /// Push a colour onto the history: newest first, deduplicated by moving an
    /// existing entry to the front rather than adding a second copy, and capped.
    ///
    /// Deduplicating by recency rather than refusing a repeat is what makes the
    /// history useful: picking the same brand colour four times in a row should
    /// leave one entry at the front, not four.
    public mutating func remember(_ c: RGB) {
        history.removeAll { $0 == c }
        history.insert(c, at: 0)
        if history.count > HISTORY_LIMIT { history.removeLast(history.count - HISTORY_LIMIT) }
    }

    /// The compact strip shown on the picker.
    public var historyPalette: [RGB] { Array(history.prefix(HISTORY_PALETTE)) }
}

// MARK: - pinning

public func isPinned(_ d: ColorData, _ name: String) -> Bool { d.pinned.contains(name) }

/// Move a palette to the front of the pinned list, adding it if it is not
/// there. Recency-deduplicated and capped, exactly like the history.
public func pinToFront(_ d: inout ColorData, _ name: String) {
    d.pinned.removeAll { $0 == name }
    d.pinned.insert(name, at: 0)
    if d.pinned.count > PINNED_MAX { d.pinned.removeLast(d.pinned.count - PINNED_MAX) }
}

/// Pin if unpinned, unpin if pinned. Returns the state it ended in.
@discardableResult
public func togglePin(_ d: inout ColorData, _ name: String) -> Bool {
    if isPinned(d, name) {
        d.pinned.removeAll { $0 == name }
        return false
    }
    pinToFront(&d, name)
    return true
}

// MARK: - palettes

extension ColorData {
    /// A name no existing palette has. Identity is the name — the pinned list
    /// stores names, and an export is called after one — so two palettes with
    /// the same name would be one palette in half the app.
    public func uniqueName(_ wanted: String) -> String {
        let base = wanted.trimmingCharacters(in: .whitespaces).isEmpty ? "Palette" : wanted
        if !palettes.contains(where: { $0.name == base }) { return base }
        var n = 2
        while palettes.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }

    /// Add a palette under a name nothing else is using, and return that name.
    @discardableResult
    public mutating func add(_ pal: Palette) -> String {
        var p = pal
        p.name = uniqueName(pal.name)
        palettes.append(p)
        return p.name
    }

    public func palette(named name: String) -> Palette? {
        palettes.first { $0.name == name }
    }

    /// Rename, keeping the pinned list pointing at the same palette. Refused if
    /// the new name is taken — silently renaming to "Brand 2" when the user
    /// typed "Brand" would be worse than doing nothing.
    @discardableResult
    public mutating func rename(_ old: String, to new: String) -> Bool {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = palettes.firstIndex(where: { $0.name == old }) else {
            return false
        }
        if trimmed == old { return true }
        guard !palettes.contains(where: { $0.name == trimmed }) else { return false }
        palettes[i].name = trimmed
        if let p = pinned.firstIndex(of: old) { pinned[p] = trimmed }
        return true
    }

    public mutating func remove(_ name: String) {
        palettes.removeAll { $0.name == name }
        pinned.removeAll { $0 == name }
    }
}

// MARK: - persistence

/// `~/Library/Application Support/n.cover/data.json`.
///
/// Not the bundle identifier, which is the Apple convention: the file is meant
/// to be found and read by a person, and `uk.upleb.ncover` tells them nothing.
public func colorDataURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("n.cover/data.json")
}

/// Load, or an empty store. A corrupt file is **not** an error here: there is
/// nothing the user could do about it at launch, and refusing to start is a
/// worse answer than starting empty. It is not overwritten until something is
/// actually saved, so the broken file is still there to look at.
public func loadColorData() -> ColorData {
    guard let data = try? Data(contentsOf: colorDataURL()),
          let d = try? JSONDecoder().decode(ColorData.self, from: data)
    else { return ColorData() }
    return d
}

public func saveColorData(_ d: ColorData) throws {
    let url = colorDataURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(d).write(to: url, options: .atomic)
}
