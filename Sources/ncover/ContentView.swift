import NCoverKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            CanvasView()
                .frame(minWidth: 520)
            Inspector()
                .frame(width: 260)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.open() } label: { Label("Open", systemImage: "folder") }
                    .help("Open an image (PNG / SVG / JPEG / WebP)")
            }
            ToolbarItem {
                Button { model.saveAs() } label: { Label("Save PNG", systemImage: "square.and.arrow.down") }
                    .disabled(model.preview == nil)
                    .help("Write the result to a new PNG. Your source file is not touched.")
            }
            ToolbarItem {
                // One click apart from Save in the GTK app, and the more
                // dangerous of the two. Here it is disabled unless the source is
                // genuinely a PNG, and guarded again on the way through.
                Button { model.overwrite() } label: { Label("Overwrite", systemImage: "arrow.uturn.backward.square") }
                    .disabled(!model.canOverwrite)
                    .help(model.canOverwrite
                          ? "Replace the original PNG in place. This cannot be undone."
                          : "Only a PNG can be overwritten — we save PNG, and rewriting a JPEG under its own name would silently change the format.")
            }
        }
        .alert("n.cover", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

private struct Inspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Source") {
                LabeledContent("File", value: model.sourceName)
                if !model.sourceDims.isEmpty {
                    LabeledContent("Size", value: model.sourceDims + (model.isSVG ? "  (rasterised)" : ""))
                        .help(model.isSVG
                              ? "An SVG has no intrinsic pixel size worth trusting, so it is rasterised large enough to survive any canvas."
                              : "The source image's own dimensions.")
                }
            }

            Section("Canvas") {
                Picker("Size", selection: $model.canvas) {
                    ForEach(CANVAS_SIZES, id: \.self) { Text("\($0) px").tag($0) }
                }
                .help("Output size. Changing it keeps your framing — the square around the picture grows, the picture does not move.")
                Picker("Framing", selection: $model.framing) {
                    Text("Cover").tag(Framing.cover)
                    Text("Fit").tag(Framing.fit)
                }
                .pickerStyle(.segmented)
                .help("Cover fills the square (edges cropped); Fit puts the whole image inside it.")
                Button("Reset placement") { model.resetFraming() }
                    .disabled(model.preview == nil)
                    .help("Re-centre the image and undo any dragging or zooming.")
            }

            Section("Disc / label") {
                Toggle("Disc mask", isOn: $model.discOn)
                    .help("""
                        Mask the artwork into a circle inscribed in the square — a \
                        record, not a rounded rectangle. The four areas outside the \
                        circle are what \u{201C}corners\u{201D} fills.
                        """)
                if model.discOn {
                    Picker("Corners", selection: $model.fillKind) {
                        ForEach(AppModel.FillKind.allCases) { Text($0.label).tag($0) }
                    }
                    .help("""
                        What sits outside the disc. Transparent is the honest default \
                        for artwork that will sit on an unknown background.
                        """)
                    switch model.fillKind {
                    case .solid:
                        ColorPicker("Colour", selection: $model.solid, supportsOpacity: false)
                    case .gradient:
                        ColorPicker("At the rim", selection: $model.gradInner, supportsOpacity: false)
                            .help("The colour where the fill meets the disc's edge.")
                        ColorPicker("At the corner", selection: $model.gradOuter, supportsOpacity: false)
                            .help("The colour reached at the very corner of the canvas.")
                    case .alpha, .white:
                        EmptyView()
                    }
                }
            }

            Section {
                Text("Output is always PNG — the disc mask needs an alpha channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
