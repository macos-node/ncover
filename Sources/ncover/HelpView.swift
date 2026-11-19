import NCoverKit
import SwiftUI

/// The Quick start: four cards saying what the app is for, and the box that
/// stops it opening here.
///
/// A fresh install opens on this rather than on an empty canvas, which is the
/// GTK sibling's decision and the right one — nothing about a blank square
/// explains what the app does. It is a *place* and not a modal: it stays in
/// the sidebar afterwards, so it can be read again without being in the way
/// once.
struct HelpView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("n.cover").font(.largeTitle.weight(.semibold))
                        Text(appVersion)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("Pick colours, and build cover and label artwork.")
                        .foregroundStyle(.secondary)
                }

                card("Artwork", "square.on.circle", [
                    "Open a PNG, SVG, JPEG or WebP — or browse a folder and step through it with ← and →.",
                    "Place it on a square canvas: drag, zoom, Cover or Fit. Then stack build steps — a background, Invert, a centred square, a disc or label mask.",
                    "Save writes a PNG or a JPEG, or an SVG when every step in the composition has a vector form. Overwrite replaces the original in its own format, and asks first.",
                ])

                card("Batch", "square.stack.3d.down.right", [
                    "One recipe over many files: a folder, ndisc's Export list, or every release ndisc has published.",
                    "Cover and Fit write new square PNGs. Cap, Square and Pad tidy each file in place instead — same name, same format — and write nothing at all for a file they would not change.",
                    "The grid shows every file the run would touch, as it would be written. Double-click one to open it in the editor; Open folder shows it in the Finder.",
                    "It never writes over your originals: the output folder cannot be the source, inside it, or above it.",
                ])

                card("Colours and palettes", "eyedropper", [
                    "Pick from anywhere on screen, from the artwork itself, or from macOS's own Colours panel. All three land in one history.",
                    "HEX, RGB and HSL at once, each with its own copy button — the text and an NSColor, so another app's colour well takes it.",
                    "Palettes import .gpl, .json and .clr, export to all four, and can be installed into ~/Library/Colors so every app's Colours panel has them.",
                ])

                card("Formats and limits", "doc.badge.gearshape", [
                    "Canvas sizes run 200–1000 px. Cover and Fit output is always PNG: the disc mask needs an alpha channel.",
                    "Cap, Square and Pad keep each file's format — a JPEG stays a JPEG at quality 92 — and refuse WebP and GIF rather than quietly converting them.",
                    "A JPEG has no alpha, so a result with transparent areas is refused rather than written as black.",
                    "Shrinking area-averages; enlarging keeps the nearest pixel, because a colour tool must not invent a colour that is in neither neighbour.",
                ])

                Divider()

                Toggle("Show this page when n.cover starts", isOn: Binding(
                    get: { model.data.tips },
                    set: { on in model.touch { $0.tips = on } }
                ))
                .tip("On for a fresh install. Turn it off and the app opens on the artwork instead.")
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(minWidth: 460)
    }

    private func card(_ title: String, _ symbol: String, _ points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.title3.weight(.medium))
            }
            ForEach(points, id: \.self) { p in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(p).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separatorColor)))
    }
}
