import AppKit
import NCoverKit
import SwiftUI
import UniformTypeIdentifiers

// The colour half's behaviour. The state it works on is declared in AppModel
// itself, because `@Published` cannot live in an extension.
//
// Three ways a colour arrives, and all three end at `picked`:
//
//   - the system sampler, from anywhere on screen (NSColorSampler);
//   - a click on the artwork, which is plain pixel reading and therefore the
//     one that works identically on every platform;
//   - the Colours panel (NSColorPanel), which is also where the user's own
//     colour lists and the system pickers live.
//
// The GTK app needs a separate X11 binary for the first of those and cannot do
// it at all on Wayland without going through a portal. Here it is one class.

extension AppModel {

    // MARK: - the store

    /// Mutate the store and save it. Every change goes through here, so there
    /// is no path that updates the UI and forgets the disk — the bug that
    /// loses someone's palettes is always a missing save, never a missing
    /// redraw, because a missing redraw is visible immediately.
    func touch(_ change: (inout ColorData) -> Void) {
        var d = data
        change(&d)
        data = d
        do {
            try saveColorData(d)
        } catch {
            self.error = "Could not save your palettes: \(error.localizedDescription)"
        }
    }

    // MARK: - picking

    /// A colour has been picked, from wherever. Becomes the current colour and
    /// goes into the history.
    func picked(_ c: RGB) {
        current = c
        touch { $0.remember(c) }
    }

    /// The system eyedropper: anywhere on screen, not just this window.
    func pickFromScreen() {
        NSColorSampler().show { [weak self] picked in
            guard let rgb = picked?.asRGB else { return }
            Task { @MainActor in self?.picked(rgb) }
        }
    }

    /// The system eyedropper, into the *backdrop* rather than the history.
    ///
    /// A separate entry point because the backdrop is not a colour you picked
    /// — it is a viewing condition, and putting every backdrop experiment into
    /// the history would bury the colours you actually chose.
    func pickBackdropFromScreen() {
        NSColorSampler().show { [weak self] picked in
            guard let rgb = picked?.asRGB else { return }
            Task { @MainActor in self?.backdrop = .custom(Color(rgb)) }
        }
    }

    /// Arm the in-app eyedropper: the next canvas click picks a pixel.
    func armCanvasPick(_ kind: CanvasPick) {
        canvasPick = canvasPick == kind ? .off : kind
    }

    // MARK: - the Colours panel

    /// Show macOS's own colour panel, with this app's palettes attached as
    /// colour lists.
    ///
    /// Attaching them is the point: the panel is where a Mac user expects to
    /// find their colours, and a palette that exists only inside this app is a
    /// palette they cannot use in Pages. Changes come back through
    /// `ColorPanelBridge`.
    func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        for pal in data.palettes {
            // A list has to be named and added; attaching the same name twice
            // replaces it, which is what we want after an edit.
            let list = NSColorList(name: pal.name)
            var used = Set<String>()
            for sw in pal.colors {
                var key = sw.caption
                while used.contains(key) { key += " " }
                used.insert(key)
                list.setColor(NSColor(srgbRed: Double(sw.rgb.r) / 255,
                                      green: Double(sw.rgb.g) / 255,
                                      blue: Double(sw.rgb.b) / 255, alpha: 1),
                              forKey: key)
            }
            panel.attachColorList(list)
        }
        if let c = current {
            panel.color = NSColor(srgbRed: Double(c.r) / 255, green: Double(c.g) / 255,
                                  blue: Double(c.b) / 255, alpha: 1)
        }
        colorPanelBridge.listen(self)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - copying

    /// Copy the current colour in the chosen format.
    ///
    /// Both a string **and** an `NSColor` go on the pasteboard. The string is
    /// what you paste into a stylesheet; the colour is what a colour well in
    /// another app accepts. Writing only the string would make this app's copy
    /// weaker than dragging the swatch, which would be an odd thing for the
    /// Copy button to be.
    func copyCurrent() {
        guard let c = current else { return }
        copy(c)
    }

    func copy(_ c: RGB) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([c.text(data.format) as NSString,
                         NSColor(srgbRed: Double(c.r) / 255, green: Double(c.g) / 255,
                                 blue: Double(c.b) / 255, alpha: 1)])
        note = "Copied \(c.text(data.format))"
    }

    func setFormat(_ f: ColorFormat) { touch { $0.format = f } }

    // MARK: - history

    func clearHistory() { touch { $0.history.removeAll() } }

    /// Keep the history as a palette. The *whole* history, not the visible ten:
    /// "save this" means the colours you picked, and silently dropping
    /// twenty-two of them would be a lie told by a button.
    func saveHistoryAsPalette() {
        guard !data.history.isEmpty else { return }
        let colours = data.history.map { Swatch($0) }
        newPalette(named: "History \(Self.dayStamp())", colors: colours)
    }

    static func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - palettes

    @discardableResult
    func newPalette(named name: String, colors: [Swatch]) -> String {
        var created = name
        touch { created = $0.add(Palette(name: name, colors: colors)) }
        selectedPalette = created
        return created
    }

    func addCurrentToPalette(_ name: String) {
        guard let c = current else { return }
        touch { d in
            guard let i = d.palettes.firstIndex(where: { $0.name == name }) else { return }
            d.palettes[i].colors.append(Swatch(c))
            pinToFront(&d, name)
        }
    }

    func removeSwatch(from name: String, at index: Int) {
        touch { d in
            guard let i = d.palettes.firstIndex(where: { $0.name == name }),
                  d.palettes[i].colors.indices.contains(index) else { return }
            d.palettes[i].colors.remove(at: index)
        }
    }

    func renameSwatch(in name: String, at index: Int, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        touch { d in
            guard let i = d.palettes.firstIndex(where: { $0.name == name }),
                  d.palettes[i].colors.indices.contains(index) else { return }
            d.palettes[i].colors[index].name = trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Using a swatch picks its colour *and* moves its palette to the front of
    /// the pinned list. One list for "recently used" and "chosen", so the two
    /// never disagree about which three the picker shows.
    func use(_ sw: Swatch, from palette: String) {
        current = sw.rgb
        touch { d in
            d.remember(sw.rgb)
            pinToFront(&d, palette)
        }
    }

    func renamePalette(_ old: String, to new: String) {
        var ok = true
        touch { ok = $0.rename(old, to: new) }
        if ok {
            if selectedPalette == old { selectedPalette = new.trimmingCharacters(in: .whitespaces) }
        } else {
            error = "There is already a palette called “\(new)”."
        }
    }

    func deletePalette(_ name: String) {
        touch { $0.remove(name) }
        if selectedPalette == name { selectedPalette = data.palettes.first?.name }
    }

    func togglePinned(_ name: String) { touch { _ = togglePin(&$0, name) } }

    // MARK: - import and export

    func importPalette() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PALETTE_READ_EXTS.compactMap { UTType(filenameExtension: $0) }
        // .clr and .gpl have no registered UTType on a stock system, so allow
        // the extensions outright rather than offering a filter that hides the
        // files the user came to open.
        panel.allowsOtherFileTypes = true
        panel.message = "Import a palette (.gpl, .json or .clr)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pal = try readPalette(at: url)
            newPalette(named: pal.name, colors: pal.colors)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Import one of the colour lists macOS already knows about — the ones in
    /// the Colours panel's palette tab, plus Apple's own.
    func importSystemColorList(named name: String) {
        guard let pal = paletteFromSystemColorList(named: name) else {
            error = "“\(name)” has no colours in it."
            return
        }
        newPalette(named: pal.name, colors: pal.colors)
    }

    func exportPalette(_ name: String, as ext: String) {
        guard let pal = data.palette(named: name) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitize(pal.name) + "." + ext
        panel.allowsOtherFileTypes = true
        panel.message = Self.exportMessage(ext)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch ext {
            case "css":  try writeCSS(pal, to: url)
            case "json": try writeJSON(pal, to: url)
            case "clr":  try writeColorList(pal, to: url)
            default:     try writeGPL(pal, to: url)
            }
            note = "Exported \(url.lastPathComponent)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func exportMessage(_ ext: String) -> String {
        switch ext {
        case "css":  return "CSS custom properties. Named swatches become their own names."
        case "json": return "This app's own format — the only one that round-trips without loss."
        case "clr":  return "A macOS colour list. Other apps' Colours panels can read it."
        default:     return "A GIMP palette — the format other colour tools read."
        }
    }

    /// Install into `~/Library/Colors`, where every app's Colours panel finds it.
    func installPaletteSystemWide(_ name: String) {
        guard let pal = data.palette(named: name) else { return }
        do {
            let url = try installColorList(pal)
            note = "Installed in \(url.path(percentEncoded: false)) — it will appear in any app's Colours panel."
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - a palette from the artwork

    /// Whether the open document can produce a palette, and how.
    var artworkPaletteKind: String? {
        guard doc != nil else { return nil }
        return isVector ? "svg" : "image"
    }

    /// For a raster: the dominant colours, quantised.
    ///
    /// This is a *summary* and is named as one. A PNG does not declare its
    /// colours, so anything we hand back is an answer to "what is most of this
    /// picture made of", not "what colours is it".
    func paletteFromImage() {
        guard let d = doc else { return }
        let colours = dominantColors(d.source.raster, want: SWATCHES_PER_ROW * 2)
        guard !colours.isEmpty else {
            error = "Nothing opaque enough to sample — the image is all but transparent."
            return
        }
        newPalette(named: (sourceStem ?? "Image") + " colours", colors: colours.map { Swatch($0) })
    }

    /// For an SVG: the colours it **declares**, with their use counts, most-used
    /// first. Not a summary — these are the exact values in the file.
    func paletteFromSVG() {
        guard let info = svgInfo else {
            error = "This source is not an SVG, so it declares no colours."
            return
        }
        guard !info.colors.isEmpty else {
            error = "The SVG declares no colours — everything in it may be a gradient reference."
            return
        }
        newPalette(named: (sourceStem ?? "SVG") + " colours",
                   colors: info.colors.map { Swatch($0.rgb) })
    }

    var sourceStem: String? { sourceURL?.deletingPathExtension().lastPathComponent }
}

extension NSColor {
    /// sRGB, 8-bit. Returns nil for a colour that has no RGB form at all —
    /// a pattern colour, which the sampler cannot produce but a colour panel can.
    var asRGB: RGB? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return RGB(UInt8((c.redComponent * 255).rounded().clamped(0, 255)),
                   UInt8((c.greenComponent * 255).rounded().clamped(0, 255)),
                   UInt8((c.blueComponent * 255).rounded().clamped(0, 255)))
    }
}

extension Double {
    fileprivate func clamped(_ lo: Double, _ hi: Double) -> Double { min(max(self, lo), hi) }
}

/// Carries NSColorPanel's changes into the model.
///
/// A target/action object rather than a Combine publisher, because that is the
/// only interface the panel has — it is one of the oldest classes in AppKit and
/// has never grown a modern one. A single shared instance, because the panel is
/// a singleton and attaching two listeners to it would double every pick.
@MainActor
final class ColorPanelBridge: NSObject {
    private weak var model: AppModel?

    func listen(_ model: AppModel) {
        self.model = model
        NSColorPanel.shared.setTarget(self)
        NSColorPanel.shared.setAction(#selector(changed(_:)))
    }

    @objc private func changed(_ sender: NSColorPanel) {
        guard let rgb = sender.color.asRGB else { return }
        // Only the current colour follows the panel live. The history does not:
        // dragging across the colour wheel would otherwise fill all 32 slots
        // with the path your cursor took.
        model?.current = rgb
    }

    /// Commit what the panel is showing into the history. Called from the
    /// picker's own button, so the user says when a panel colour is a pick.
    func commit() {
        guard let rgb = NSColorPanel.shared.color.asRGB else { return }
        model?.picked(rgb)
    }
}

@MainActor let colorPanelBridge = ColorPanelBridge()
