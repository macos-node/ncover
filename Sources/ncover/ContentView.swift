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

            Section("Backdrop") {
                // Preview only — never composited into anything written.
                LabeledContent("Behind") {
                    HStack(spacing: 8) {
                        BackdropRow(backdrop: $model.backdrop)
                        Divider().frame(height: 18)
                        Button { model.samplingBackdrop.toggle() } label: {
                            Image(systemName: "eyedropper")
                        }
                        .help("Pick from the image — then click a pixel on the canvas.")
                        .accessibilityLabel("Pick backdrop from image")
                        Button { model.pickBackdropFromScreen() } label: {
                            Image(systemName: "eyedropper.halffull")
                        }
                        .help("Pick from anywhere on screen, using the system colour sampler.")
                        .accessibilityLabel("Pick backdrop from screen")
                    }
                    .buttonStyle(.borderless)
                }
                .help("What sits behind the artwork while you work, so alpha can be judged against a real background. Never written to the file.")

                if model.samplingBackdrop {
                    Text("Click a pixel on the canvas…")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Mask") {
                Toggle("Mask", isOn: $model.discOn)
                    .help("The mask is inscribed in the CANVAS, not fitted to the artwork — so an inset source is only clipped at its corners.")
                if model.discOn {
                    Picker("Shape", selection: $model.maskShape) {
                        ForEach(AppModel.MaskKind.allCases) { kind in
                            Image(systemName: kind.symbol)
                                .accessibilityLabel(kind.label)
                                .help(kind.help)
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Disc, rounded rectangle, or chamfer. Rounded and chamfer cut corners by the amount below — at 100% a rounded rectangle IS the disc.")

                    if model.maskHasAmount {
                        LabeledContent("Amount") {
                            HStack(spacing: 8) {
                                Slider(value: $model.maskAmount, in: 0...1)
                                Text(String(format: "%.0f%%", model.maskAmount * 100))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                        .help("How much corner goes, as a fraction of half the canvas.")
                    }

                    LabeledContent("Corners") {
                        FillRow(kind: $model.fillKind,
                                solid: model.solid,
                                gradInner: model.gradInner,
                                gradOuter: model.gradOuter)
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
