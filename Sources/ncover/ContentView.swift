import NCoverKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            CanvasView().frame(minWidth: 520)
            Inspector().frame(width: 280)
        }
        .toolbar {
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
            ToolbarItem {
                Button { model.saveAs() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(model.preview == nil)
                    .help(model.saveHelp)
            }
            ToolbarItem {
                Button { model.overwrite() } label: { Label("Overwrite", systemImage: "arrow.uturn.backward.square") }
                    .disabled(!model.canOverwrite)
                    .help(model.canOverwrite
                          ? "Replace the original PNG in place. This cannot be undone."
                          : "Only a PNG can be overwritten — we save PNG, and rewriting a JPEG under its own name would silently change the format.")
            }
        }
        .alert("n.cover", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
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
                    .help(model.isVector
                          ? "An SVG has no native resolution. It is re-rendered at the size it is drawn at, so it is never resampled."
                          : "The source image's own dimensions.")
                }
            }

            Section("Canvas") {
                Picker("Size", selection: Binding(
                    get: { model.canvas }, set: { model.canvas = $0 })) {
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
                    .help("Mask to a circle inscribed in the canvas — a record, not a rounded rectangle. It is inscribed in the CANVAS, so an inset source is only clipped at its corners.")
                if model.discOn {
                    Picker("Corners", selection: $model.fillKind) {
                        ForEach(AppModel.FillKind.allCases) { Text($0.label).tag($0) }
                    }
                    .help("What sits outside the mask. Transparent is the honest default for artwork that will sit on an unknown background.")
                    switch model.fillKind {
                    case .solid:
                        ColorPicker("Colour", selection: $model.solid, supportsOpacity: false)
                    case .gradient:
                        ColorPicker("At the rim", selection: $model.gradInner, supportsOpacity: false)
                            .help("The colour where the fill meets the mask's edge.")
                        ColorPicker("At the corner", selection: $model.gradOuter, supportsOpacity: false)
                            .help("The colour reached at the very corner of the canvas.")
                    case .alpha, .white:
                        EmptyView()
                    }
                }
            }

            // The app's actual shape, shown rather than implied. Each step says
            // whether it can be written as vector, which is what decides
            // whether SVG export is on the table.
            Section("Steps") {
                if model.steps.isEmpty {
                    Text("nothing yet").foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(model.steps) { step in
                        StepRow(step: step)
                    }
                }
            }

            Section {
                if model.canSaveVector {
                    Label("Can save as SVG — no pixels involved", systemImage: "seal")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let why: String = model.vectorRefusal ?? ""
                    Label("PNG only — " + why, systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
                .help(step.hasVectorForm ? "has a vector form" : "raster only")
        }
        .font(.callout)
    }
}
