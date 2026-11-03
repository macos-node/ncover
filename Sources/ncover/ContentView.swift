import NCoverKit
import SwiftUI

/// The app has two halves — colour and artwork — and they are not the same
/// shape, so they do not share a layout.
///
/// A sidebar rather than tabs: the sections are places you stay in, not modes
/// you flick between, and a sidebar is the thing a Mac user already knows how
/// to collapse (⌃⌘S) when they want the canvas to have the window.
enum AppSection: String, CaseIterable, Identifiable {
    case artwork, picker, palettes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .artwork:  return "Artwork"
        case .picker:   return "Colour"
        case .palettes: return "Palettes"
        }
    }

    var symbol: String {
        switch self {
        case .artwork:  return "square.on.circle"
        case .picker:   return "eyedropper"
        case .palettes: return "swatchpalette"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: AppSection = .artwork

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(
                get: { section }, set: { section = $0 ?? .artwork }
            )) { s in
                Label(s.label, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch section {
            case .artwork:  ArtworkView()
            case .picker:   PickerView()
            case .palettes: PalettesView()
            }
        }
        .toolbar { toolbar(for: section) }
        .alert("n.cover", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        // A confirmation is not an error and does not get a dialog to dismiss.
        .overlay(alignment: .bottom) { NoteBanner() }
        .sheet(isPresented: $model.showBatch) { BatchView().environmentObject(model) }
        // Once the app is up, not in `init`: touching NSColorPanel.shared
        // creates the panel, and there is no reason to pay for that before
        // there is a window.
        .task { model.syncPalettesToColorPanel() }
    }

    @ToolbarContentBuilder
    private func toolbar(for section: AppSection) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.open() } label: { Label("Open", systemImage: "folder") }
                .help("Open artwork (PNG / SVG / JPEG / WebP)")
        }
        ToolbarItemGroup {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo the last change")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("Redo")
        }
        // The two write actions carry visible labels. They are the
        // consequential pair, one of them irreversibly so, and "you can
        // hover to find out what destroys your file" is not a design.
        ToolbarItem {
            Button { model.showBatch = true } label: {
                Label("Batch", systemImage: "square.stack.3d.down.right")
            }
            .help("Run one recipe over a folder, or over every release ndisc has published. Never writes over your originals.")
        }
        ToolbarItem {
            Button { model.saveAs() } label: {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.preview == nil)
            .help(model.saveHelp)
        }
        ToolbarItem {
            Button { model.overwrite() } label: {
                // Not a U-turn arrow: it sat next to undo and redo and read
                // as "revert", close to the opposite of what it does.
                Label("Overwrite", systemImage: "square.and.arrow.down.on.square")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!model.canOverwrite)
            .help(model.canOverwrite
                  ? "Replace the original PNG in place. This cannot be undone."
                  : "Only a PNG can be overwritten — we save PNG, and rewriting a JPEG under its own name would silently change the format.")
        }
    }
}

/// A transient line for the things that are neither errors nor worth a dialog:
/// "Copied #7AF0CD", "Installed in ~/Library/Colors".
private struct NoteBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let n = model.note {
            Text(n)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .padding(.bottom, 18)
                .transition(.opacity)
                .task(id: n) {
                    try? await Task.sleep(for: .seconds(2.2))
                    withAnimation { if model.note == n { model.note = nil } }
                }
        }
    }
}

// MARK: - artwork

struct ArtworkView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                CanvasView().frame(minWidth: 420)
                if model.showRail { SourceResultRail() }
            }
            Inspector().frame(width: 290)
        }
    }
}

private struct Inspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Source") {
                LabeledContent("File") { Text(model.sourceName) }
                if !model.sourceDims.isEmpty {
                    LabeledContent("Size") {
                        Text(model.sourceDims + (model.isVector ? "  (rasterised)" : ""))
                    }
                    .tip(model.isVector
                          ? "An SVG has no native resolution. It is re-rendered at the size it is drawn at, so it is never resampled."
                          : "The source image's own dimensions.")
                }
                if model.folderCount > 1 {
                    LabeledContent("In folder") {
                        HStack(spacing: 6) {
                            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                                .accessibilityLabel("Previous image")
                            Text("\(model.folderIndex + 1) of \(model.folderCount)")
                                .monospacedDigit().foregroundStyle(.secondary)
                            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                                .accessibilityLabel("Next image")
                        }
                        .buttonStyle(.borderless)
                    }
                    .tip("Every image beside this one, in name order. ← and → walk through them.")
                }
            }

            Section("Canvas") {
                Picker("Size", selection: Binding(
                    get: { model.canvas }, set: { model.canvas = $0 })) {
                    ForEach(CANVAS_SIZES, id: \.self) { Text("\($0) px").tag($0) }
                }
                .tip("Output size. Changing it keeps your framing — the square around the picture grows, the picture does not move.")

                Picker("Framing", selection: $model.framing) {
                    Text("Cover").tag(Framing.cover)
                    Text("Fit").tag(Framing.fit)
                }
                .pickerStyle(.segmented)
                .tip("Cover fills the square (edges cropped); Fit puts the whole image inside it.")

                Button("Reset placement") { model.resetFraming() }
                    .disabled(model.preview == nil)
                    .tip("Re-centre the image and undo any dragging or zooming.")
            }

            Section("View") {
                Toggle("Grid", isOn: $model.showGrid)
                    .tip("Thirds, centre lines and the inscribed circle, over the preview. Never written to the file.")
                Toggle("Source / result", isOn: $model.showRail)
                    .tip("A strip under the canvas showing the raw source beside what you have built.")

                // Preview only — never composited into anything written.
                LabeledContent("Backdrop") {
                    HStack(spacing: 8) {
                        BackdropRow(backdrop: $model.backdrop)
                        Divider().frame(height: 18)
                        Button { model.armCanvasPick(.backdrop) } label: {
                            Image(systemName: "eyedropper")
                                .foregroundStyle(model.canvasPick == .backdrop ? Color.orange : Color.primary)
                        }
                        .tip("Pick from the image — then click a pixel on the canvas.")
                        .accessibilityLabel("Pick backdrop from image")
                        Button { model.pickBackdropFromScreen() } label: {
                            Image(systemName: "eyedropper.halffull")
                        }
                        .tip("Pick from anywhere on screen, using the system colour sampler.")
                        .accessibilityLabel("Pick backdrop from screen")
                    }
                    .buttonStyle(.borderless)
                }
                .tip("What sits behind the artwork while you work, so alpha can be judged against a real background. Never written to the file.")

                if model.canvasPick != .off {
                    Text("Click a pixel on the canvas…")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Build") {
                // The operations that are not placement or masking. Each one is
                // an `Operation` case, so each is undoable and each answers for
                // itself whether SVG export survives it.
                Toggle("Invert", isOn: $model.invertOn)
                    .tip("Invert the colours, leaving alpha alone — a transparent pixel stays transparent rather than becoming an opaque black one.")

                Toggle("Centred square", isOn: $model.squareOn)
                    .tip("Stamp a filled square in the middle of the canvas. A label mark is solid, so it covers transparent ground too.")
                if model.squareOn {
                    LabeledContent("Side") {
                        HStack(spacing: 8) {
                            Slider(value: $model.squareFrac, in: 0.05...1)
                            Text(String(format: "%.0f%%", model.squareFrac * 100))
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    .tip("The square's side, as a fraction of the canvas.")
                    PaletteWell(label: "Square colour", colour: $model.squareColour,
                                help: "The stamped square's colour. The swatch button beside the well holds your picked colours and pinned palettes.")
                }

                Button("Blank canvas") { model.blankCanvas() }
                    .tip("Start from a white square instead of an image — somewhere to set type, stamp a square or drop a mask. It carries a vector form, so a composition built from nothing can still be saved as SVG.")
            }

            Section("Type") {
                Toggle("Type", isOn: $model.textOn)
                    .tip("Set words on the canvas. They are exported as outlines, not as a font reference, so the SVG looks the same on a machine that does not have the font.")
                if model.textOn { typeControls }
            }

            Section("Mask") {
                Toggle("Mask", isOn: $model.discOn)
                    .tip("Mask the artwork to a shape, filling outside it.")
                if model.discOn { maskControls }
            }

            Section("Colour") {
                LabeledContent("From artwork") {
                    HStack(spacing: 8) {
                        Button { model.armCanvasPick(.colour) } label: {
                            Image(systemName: "eyedropper")
                                .foregroundStyle(model.canvasPick == .colour ? Color.orange : Color.primary)
                        }
                        .tip("Pick a pixel's colour into the history — then click the canvas.")
                        .accessibilityLabel("Pick a colour from the image")
                        if let c = model.current {
                            SwatchButton(isSelected: false, help: c.hex,
                                         accessibility: "Current colour \(c.hex)") {
                                model.copy(c)
                            } content: { Color(c) }
                        }
                    }
                    .buttonStyle(.borderless)
                }
                if model.isVector {
                    Button("Palette from the SVG's declared colours") { model.paletteFromSVG() }
                        .tip("An SVG states its colours. These are the exact values in the file, most-used first — not a guess from pixels.")
                } else if model.doc != nil {
                    Button("Palette from this image") { model.paletteFromImage() }
                        .tip("The image's dominant colours, quantised. A summary: a PNG does not declare its colours, it only contains pixels.")
                }
                if let info = model.svgInfo { SVGFacts(info: info) }
            }

            // The app's actual shape, shown rather than implied. Each step says
            // whether it can be written as vector, which is what decides
            // whether SVG export is on the table.
            Section("Steps") {
                if model.steps.isEmpty {
                    Text("nothing yet").foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(model.steps) { StepRow(step: $0) }
                }
            }

            Section {
                if model.canSaveVector {
                    Label("Can save as SVG — no pixels involved", systemImage: "seal")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("PNG only — " + (model.vectorRefusal ?? ""), systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var typeControls: some View {
        // Axis-less, so a return makes a second line. Label art is a line or
        // two set deliberately; a box that reflows is a different tool.
        TextField("Words", text: $model.textString, prompt: Text("your words"), axis: .vertical)
            .lineLimit(1...4)
            .tip("Return starts a new line. Nothing wraps on its own — a line break here is a decision, not an accident of width.")

        LabeledContent("Font") {
            HStack(spacing: 8) {
                Text(model.textFontDisplayName).lineLimit(1)
                Spacer()
                Button("Choose…") { model.chooseFont() }
            }
        }
        .tip("The system font panel, with its search and collections — rather than a worse list of the same fonts.")

        if !model.textFontIsReal {
            Label("“\(model.textFont)” is not installed — another face is being substituted.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }

        LabeledContent("Size") {
            HStack(spacing: 8) {
                Slider(value: $model.textSize, in: 0.02...0.6)
                Text(String(format: "%.0f%%", model.textSize * 100))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .tip("A fraction of the canvas, not points — so changing the output size scales the type with it instead of stranding it.")

        LabeledContent("Tracking") {
            HStack(spacing: 8) {
                Slider(value: $model.textTracking, in: -0.1...0.5)
                Text(String(format: "%+.2f", model.textTracking))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .tip("Letter spacing, as a fraction of the font size. Label lettering is usually set wider than body text.")

        if model.textString.contains("\n") {
            LabeledContent("Line height") {
                HStack(spacing: 8) {
                    Slider(value: $model.textLineSpacing, in: 0.8...2.5)
                    Text(String(format: "%.2f", model.textLineSpacing))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            .tip("A multiple of the font size.")
        }

        PaletteWell(label: "Type colour", colour: $model.textColour,
                    help: "The lettering's colour, from your own palettes.")

        LabeledContent("Position") { PositionGrid() }
            .tip("Nine places, and the two sliders below for anything between them.")

        LabeledContent("Across") {
            Slider(value: $model.textX, in: 0...1)
        }
        LabeledContent("Down") {
            Slider(value: $model.textY, in: 0...1)
        }
    }

    @ViewBuilder
    private var maskControls: some View {
        Picker("Shape", selection: $model.maskShape) {
            ForEach(AppModel.MaskKind.allCases) { kind in
                Image(systemName: kind.symbol)
                    .accessibilityLabel(kind.label)
                    .tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .tip("Disc, rounded rectangle, or chamfer. Rounded and chamfer cut corners by the amount below — at 100% a rounded rectangle IS the disc.")

        Picker("Fit to", selection: $model.maskFit) {
            ForEach(MaskFit.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .tip("""
            Canvas inscribes the mask in the square you are exporting, so \
            a source that does not reach the edges is only clipped at its \
            corners. Artwork inscribes it in whatever is actually drawn, \
            so an inset image gets a mask of itself.
            """)

        if model.maskHasAmount {
            LabeledContent("Amount") {
                HStack(spacing: 8) {
                    Slider(value: $model.maskAmount, in: 0...1)
                    Text(String(format: "%.0f%%", model.maskAmount * 100))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            .tip("How much corner goes, as a fraction of half the canvas.")
        }

        LabeledContent("Corners") {
            FillRow(kind: $model.fillKind,
                    solid: model.solid,
                    gradInner: model.gradInner,
                    gradOuter: model.gradOuter)
        }
        .tip("What sits outside the mask. Transparent is the honest default for artwork that will sit on an unknown background.")

        switch model.fillKind {
        case .solid:
            PaletteWell(label: "Colour", colour: $model.solid,
                        help: "What fills outside the mask.")
        case .gradient:
            PaletteWell(label: "At the rim", colour: $model.gradInner,
                        help: "The colour where the fill meets the mask's edge.")
            PaletteWell(label: "At the corner", colour: $model.gradOuter,
                        help: "The colour reached at the very corner of the canvas.")
        case .alpha, .white:
            EmptyView()
        }
    }
}

/// What an SVG says about itself. Shown only for a vector source, because a
/// raster has nothing to say.
private struct SVGFacts: View {
    let info: SVGInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !info.fonts.isEmpty {
                fact("Fonts", info.fonts.joined(separator: ", "))
            }
            if !info.texts.isEmpty {
                fact("Text", info.texts.joined(separator: " · "))
            }
            fact("Declares", "\(info.colors.count) colours"
                 + (info.gradients > 0 ? ", \(info.gradients) gradients" : ""))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .tip("Read out of the file, not sampled from pixels. Fonts matter because WebKit resolves them at render time — a font you do not have is a different picture.")
    }

    @ViewBuilder
    private func fact(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(k).frame(width: 58, alignment: .leading).foregroundStyle(.tertiary)
            Text(v).lineLimit(2)
        }
    }
}

/// Nine places for a line of type. A record label's wording lands on one of
/// these far more often than anywhere else, and dragging two sliders to find
/// dead centre is a chore the grid removes.
private struct PositionGrid: View {
    @EnvironmentObject var model: AppModel

    private let stops: [Double] = [0.25, 0.5, 0.75]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(stops, id: \.self) { y in
                HStack(spacing: 3) {
                    ForEach(stops, id: \.self) { x in
                        let on = abs(model.textX - x) < 0.001 && abs(model.textY - y) < 0.001
                        Button { model.placeText(x: x, y: y) } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(on ? Color.accentColor : Color.secondary.opacity(0.22))
                                .frame(width: 15, height: 11)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Place type")
                    }
                }
            }
        }
    }
}

private struct StepRow: View {
    let step: AppModel.Step

    var body: some View {
        HStack {
            Text("\(step.id + 1).")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(step.label)
            Spacer()
            Image(systemName: step.hasVectorForm ? "checkmark.seal" : "xmark.seal")
                .foregroundStyle(step.hasVectorForm ? Color.secondary : Color.orange)
                .tip(step.hasVectorForm ? "has a vector form" : "raster only")
        }
        .font(.callout)
    }
}

/// The source as it came in, beside what the operations made of it.
///
/// Worth having because every control in the inspector describes a change to
/// something you can no longer see. The left-hand tile is the file on disk;
/// the right is the canvas.
private struct SourceResultRail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            tile("Source", image: model.sourceThumb)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            tile("Result", image: model.preview)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func tile(_ label: String, image: NSImage?) -> some View {
        VStack(spacing: 4) {
            ZStack {
                MiniChecker()
                if let i = image {
                    Image(nsImage: i).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
