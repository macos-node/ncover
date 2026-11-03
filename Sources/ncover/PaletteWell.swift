import AppKit
import NCoverKit
import SwiftUI

/// A colour well that knows about this app's own colours.
///
/// A plain `ColorPicker` opens the system Colours panel, which is the right
/// thing and not quite enough: having just picked a colour off the artwork,
/// reaching it again means opening a panel and finding the Palettes tab. The
/// colours you have *in this app* should be one click from the well that
/// needs them.
///
/// So: the standard well, plus a swatch button beside it holding the current
/// colour, the recent ones, and the pinned palettes. The system panel is still
/// there for everything else, and it now shows these palettes too — see
/// `syncPalettesToColorPanel`.
struct PaletteWell: View {
    let label: String
    @Binding var colour: Color
    /// Shown above the well, for the two gradient stops where "Colour" alone
    /// would not say which end.
    var help: String?

    @EnvironmentObject var model: AppModel
    @State private var showing = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                ColorPicker("", selection: $colour, supportsOpacity: false)
                    .labelsHidden()
                Button { showing = true } label: {
                    Image(systemName: "swatchpalette")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Choose from your colours")
                .tip("Your picked colours and pinned palettes, without going through the Colours panel.")
                .popover(isPresented: $showing, arrowEdge: .bottom) { choices }
            }
        }
        .tip(help ?? "")
    }

    @ViewBuilder
    private var choices: some View {
        let pins = model.data.pinned.compactMap { model.data.palette(named: $0) }
        VStack(alignment: .leading, spacing: 12) {
            if let c = model.current {
                group("Current") {
                    SwatchStrip(colours: [c]) { take($0) }
                }
            }
            if !model.data.history.isEmpty {
                group("Recent") {
                    SwatchStrip(colours: model.data.historyPalette) { take($0) }
                }
            }
            ForEach(pins) { pal in
                group(pal.name) {
                    SwatchStrip(swatches: pal.colors) { take($0.rgb) }
                }
            }
            if model.current == nil, model.data.history.isEmpty, pins.isEmpty {
                Text("Nothing yet — pick a colour, or pin a palette in Palettes.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    /// Choosing a fill colour is not *picking* a colour, so this does not go
    /// into the history — otherwise setting a square to a colour you already
    /// had would reorder the very list you took it from under your hand.
    private func take(_ c: RGB) {
        colour = Color(c)
        showing = false
    }
}
