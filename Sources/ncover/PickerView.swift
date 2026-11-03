import AppKit
import NCoverKit
import SwiftUI

/// The colour half's front page: one colour, written three ways, and the
/// colours you have picked recently.
///
/// The three sources of a colour are three buttons, and which of them you
/// reach for is the only difference between them — a pick is a pick, and all
/// three end up in the same history.
struct PickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                current
                sources
                history
                pinned
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - the current colour

    @ViewBuilder
    private var current: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                MiniChecker()
                (model.current.map { Color($0) } ?? Color.clear)
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .tip(model.current == nil
                 ? "No colour picked yet."
                 : "The colour you are working with. Click Copy, or drop it into a palette.")

            VStack(alignment: .leading, spacing: 10) {
                // All three forms at once, not just the chosen one. The format
                // switch decides what Copy puts on the pasteboard; it should
                // not decide what you are allowed to read.
                if let c = model.current {
                    ForEach(ColorFormat.allCases, id: \.self) { f in
                        Button { model.setFormat(f); model.copy(c) } label: {
                            HStack(spacing: 10) {
                                Text(f.label)
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .frame(width: 30, alignment: .leading)
                                Text(c.text(f))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(model.data.format == f ? .primary : .secondary)
                                Image(systemName: "doc.on.doc")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .tip("Copy as \(f.label), and make it the format Copy uses from now on.")
                    }
                } else {
                    Text("Pick a colour — from the screen, from the artwork, or from the Colours panel.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    // MARK: - where a colour comes from

    @ViewBuilder
    private var sources: some View {
        HStack(spacing: 10) {
            Button { model.pickFromScreen() } label: {
                Label("Pick from screen", systemImage: "eyedropper.halffull")
            }
            .tip("The system colour sampler: magnifies the screen and picks any pixel on it, in any app.")

            Button { model.showColorPanel() } label: {
                Label("Colours…", systemImage: "paintpalette")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .tip("macOS's own colour panel — wheels, sliders, and your colour lists. Your palettes are attached to it, so they show up in its Palettes tab.")

            Button { colorPanelBridge.commit() } label: {
                Label("Keep", systemImage: "plus.circle")
            }
            .tip("Put the Colours panel's current colour into the history. The panel itself does not — dragging across a colour wheel would otherwise fill all 32 slots with the path your cursor took.")

            Spacer()

            if !model.data.palettes.isEmpty, model.current != nil {
                Menu {
                    ForEach(model.data.palettes) { pal in
                        Button(pal.name) { model.addCurrentToPalette(pal.name) }
                    }
                } label: {
                    Label("Add to palette", systemImage: "square.grid.2x2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - history

    @ViewBuilder
    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading("History", count: model.data.history.count)
                Spacer()
                Button("Save as palette") { model.saveHistoryAsPalette() }
                    .buttonStyle(.link)
                    .disabled(model.data.history.isEmpty)
                    .tip("Keep every colour in the history — all \(model.data.history.count) of them, not just the ten shown.")
                Button("Clear") { model.clearHistory() }
                    .buttonStyle(.link)
                    .disabled(model.data.history.isEmpty)
            }
            if model.data.history.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.tertiary)
            } else {
                // The compact strip: the most recent ten, which is a row you
                // can scan. The other twenty-two are kept, not shown.
                SwatchStrip(colours: model.data.historyPalette) { c in
                    model.current = c
                    model.copy(c)
                }
                if model.data.history.count > HISTORY_PALETTE {
                    Text("\(model.data.history.count - HISTORY_PALETTE) more kept, and saved with the palette.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - pinned palettes

    @ViewBuilder
    private var pinned: some View {
        let pins = model.data.pinned.compactMap { model.data.palette(named: $0) }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Pinned", count: pins.count)
            if pins.isEmpty {
                Text("Pin up to \(PINNED_MAX) palettes in Palettes, and they ride along here.")
                    .font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(pins) { pal in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(pal.name).font(.callout)
                        SwatchStrip(swatches: pal.colors) { sw in model.use(sw, from: pal.name) }
                    }
                }
            }
        }
    }
}

struct SectionHeading: View {
    let title: String
    let count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title; self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            if let c = count, c > 0 {
                Text("\(c)").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
    }
}

/// A row of swatches that wraps. Ten per row, because ten reads as a row you
/// can count at a glance and more becomes a wall.
struct SwatchStrip: View {
    let swatches: [Swatch]
    let onPick: (Swatch) -> Void

    init(swatches: [Swatch], onPick: @escaping (Swatch) -> Void) {
        self.swatches = swatches; self.onPick = onPick
    }

    init(colours: [RGB], onPick: @escaping (RGB) -> Void) {
        self.swatches = colours.map { Swatch($0) }
        self.onPick = { onPick($0.rgb) }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6),
                                 count: SWATCHES_PER_ROW),
                  alignment: .leading, spacing: 6) {
            ForEach(Array(swatches.enumerated()), id: \.offset) { _, sw in
                ColourChip(swatch: sw) { onPick(sw) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// One swatch.
///
/// Draggable as its hex, which drops into a stylesheet, a text field or a
/// terminal. Not as an `NSColor`: AppKit's colour drag wants a real view and
/// `NSColor` conforms to neither `Transferable` nor `NSItemProviderWriting`,
/// so a colour-well drag would be a view of its own for one gesture. Copy puts
/// the `NSColor` on the pasteboard, which is the same reach by a different
/// route.
struct ColourChip: View {
    let swatch: Swatch
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color(swatch.rgb)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.separator.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .draggable(swatch.rgb.hex)
        .tip(swatch.name.map { "\($0) — \(swatch.rgb.hex)" } ?? swatch.rgb.hex)
        .accessibilityLabel(swatch.caption)
    }
}
