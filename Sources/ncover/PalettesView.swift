import AppKit
import NCoverKit
import SwiftUI

/// The palette library: a list on the left, the chosen palette on the right.
///
/// A list and a detail rather than one long scroll, because a palette is a
/// thing you work *in* — renaming swatches, adding one, exporting it — and all
/// of that wants room.
struct PalettesView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
            detail.frame(minWidth: 320)
        }
    }

    // MARK: - the list

    @ViewBuilder
    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedPalette) {
                ForEach(model.data.palettes) { pal in
                    HStack(spacing: 8) {
                        // The palette's own first few colours, so the list is
                        // readable without selecting anything.
                        HStack(spacing: 2) {
                            ForEach(Array(pal.colors.prefix(4).enumerated()), id: \.offset) { _, sw in
                                Color(sw.rgb).frame(width: 7, height: 16)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(pal.name).lineLimit(1)
                            Text("\(pal.colors.count) colours")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if isPinned(model.data, pal.name) {
                            Image(systemName: "pin.fill")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .tip("Pinned to the Colour view")
                        }
                    }
                    .tag(pal.name)
                    .contextMenu { rowMenu(pal.name) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Menu {
                    Button("Empty palette") {
                        model.newPalette(named: "Palette", colors: [])
                    }
                    if model.isVector {
                        Button("From the SVG's declared colours") { model.paletteFromSVG() }
                    } else if model.doc != nil {
                        Button("From the open image") { model.paletteFromImage() }
                    }
                    if !model.data.history.isEmpty {
                        Button("From the colour history") { model.saveHistoryAsPalette() }
                    }
                    Divider()
                    Button("Import a file…") { model.importPalette() }
                    // The lists macOS already has. Offering them by name saves
                    // the user finding ~/Library/Colors themselves, and it is
                    // the reason reading .clr is worth having at all.
                    Menu("Import a macOS colour list") {
                        ForEach(systemColorListNames(), id: \.self) { n in
                            Button(n) { model.importSystemColorList(named: n) }
                        }
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tip("A palette from nothing, from the artwork, from the history, or from a file.")
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func rowMenu(_ name: String) -> some View {
        Button(isPinned(model.data, name) ? "Unpin" : "Pin to Colour view") {
            model.togglePinned(name)
        }
        Button("Rename…") { renaming = name; newName = name }
        Divider()
        Menu("Export") {
            Button("GIMP palette (.gpl)") { model.exportPalette(name, as: "gpl") }
            Button("JSON (.json)") { model.exportPalette(name, as: "json") }
            Button("CSS custom properties (.css)") { model.exportPalette(name, as: "css") }
            Button("macOS colour list (.clr)") { model.exportPalette(name, as: "clr") }
        }
        Button("Install in ~/Library/Colors") { model.installPaletteSystemWide(name) }
        Divider()
        Button("Delete", role: .destructive) { model.deletePalette(name) }
    }

    // MARK: - the chosen palette

    @ViewBuilder
    private var detail: some View {
        if let name = model.selectedPalette, let pal = model.data.palette(named: name) {
            PaletteDetail(palette: pal, renaming: $renaming, newName: $newName)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "swatchpalette")
                    .font(.system(size: 40, weight: .thin)).foregroundStyle(.tertiary)
                Text(model.data.palettes.isEmpty
                     ? "No palettes yet. Make one from the artwork, the history, or a file."
                     : "Choose a palette.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PaletteDetail: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    @Binding var renaming: String?
    @Binding var newName: String
    /// Which swatch's name is being edited, by index.
    @State private var editing: Int?
    @State private var swatchName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                grid
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        .alert("Rename palette", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming { model.renamePalette(old, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(palette.name).font(.title2)
                Text("\(palette.colors.count) colours").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                model.togglePinned(palette.name)
            } label: {
                Image(systemName: isPinned(model.data, palette.name) ? "pin.fill" : "pin")
            }
            .tip(isPinned(model.data, palette.name)
                 ? "Unpin from the Colour view."
                 : "Pin to the Colour view. Up to \(PINNED_MAX); the oldest drops off.")
            .accessibilityLabel("Pin")

            if model.current != nil {
                Button("Add current colour") { model.addCurrentToPalette(palette.name) }
                    .tip("Append the colour the picker is showing.")
            }
            Menu {
                Button("GIMP palette (.gpl)") { model.exportPalette(palette.name, as: "gpl") }
                Button("JSON (.json)") { model.exportPalette(palette.name, as: "json") }
                Button("CSS custom properties (.css)") { model.exportPalette(palette.name, as: "css") }
                Button("macOS colour list (.clr)") { model.exportPalette(palette.name, as: "clr") }
                Divider()
                Button("Install in ~/Library/Colors") {
                    model.installPaletteSystemWide(palette.name)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .tip("GPL for other colour tools, JSON to round-trip without loss, CSS for a stylesheet, CLR for macOS itself.")
        }
    }

    /// Larger tiles than the picker's strip, with the name and hex under each,
    /// because this is the view where a swatch's *name* is the point.
    @ViewBuilder
    private var grid: some View {
        if palette.colors.isEmpty {
            Text("Empty. Pick a colour and use “Add current colour”.")
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
                      alignment: .leading, spacing: 14) {
                ForEach(Array(palette.colors.enumerated()), id: \.offset) { i, sw in
                    VStack(spacing: 4) {
                        Button { model.use(sw, from: palette.name) } label: {
                            Color(sw.rgb)
                                .frame(height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.separator))
                        }
                        .buttonStyle(.plain)
                        .tip("Pick this colour. It also moves this palette to the front of the pinned list.")

                        if editing == i {
                            TextField("name", text: $swatchName)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    model.renameSwatch(in: palette.name, at: i, to: swatchName)
                                    editing = nil
                                }
                        } else {
                            Text(sw.name ?? "—")
                                .font(.caption).lineLimit(1)
                                .foregroundStyle(sw.name == nil ? .tertiary : .primary)
                        }
                        Text(sw.rgb.hex)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .contextMenu {
                        Button("Copy \(sw.rgb.text(model.data.format))") { model.copy(sw.rgb) }
                        Button("Name…") { editing = i; swatchName = sw.name ?? "" }
                        Divider()
                        Button("Remove", role: .destructive) {
                            model.removeSwatch(from: palette.name, at: i)
                        }
                    }
                }
            }
        }
    }
}
