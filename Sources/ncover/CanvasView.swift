import NCoverKit
import SwiftUI

/// The square canvas, with drag, zoom and visible snap guides.
///
/// A snap you cannot see is just a bug, so the guides are drawn whenever one
/// fires — that is the whole reason `snap` reports which axes caught.
struct CanvasView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 48
            let viewScale = side / Double(model.canvas)

            ZStack {
                // The surround takes the backdrop too, so a white or black
                // choice is judged against the whole field rather than a patch.
                (model.backdrop.colour ?? Color(nsColor: .underPageBackgroundColor))
                    .ignoresSafeArea()

                if let img = model.preview {
                    ZStack {
                        if let c = model.backdrop.colour { c } else { Checkerboard() }
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.none)       // show the pixels we actually wrote
                            .frame(width: side, height: side)
                        // The tracing guide. Drawn here rather than by a
                        // renderer, like the grid and the snap guides, which
                        // is what keeps "the preview is what a PNG export
                        // writes" true of the *file* — the ghost is on the
                        // screen, never in the output.
                        if let ghost = model.templateGhost {
                            Image(nsImage: ghost)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: side, height: side)
                                .opacity(0.3)
                                .allowsHitTesting(false)
                        }
                        if model.showGrid { grid(side: side) }
                        guides(side: side)
                    }
                    .frame(width: side, height: side)
                    .overlay(Rectangle().strokeBorder(.separator, lineWidth: 1))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard !model.picking else { return }
                                model.beginDrag()
                                model.dragTo(v.translation, viewScale: viewScale)
                            }
                            .onEnded { v in
                                if model.picking {
                                    model.samplePixel(canvasX: v.location.x / viewScale,
                                                      canvasY: v.location.y / viewScale)
                                } else {
                                    model.endDrag()
                                }
                            }
                    )
                    // simultaneous, not a second .gesture: two plain gesture
                    // modifiers compete, and the later one swallowed the drag.
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in model.zoom(by: 1 + (v.magnification - 1) * 0.06) }
                            .onEnded { _ in model.endZoom() }
                    )
                    .tip(Self.canvasTip(model.canvasPick))
                    // Only while an eyedropper is armed: the readout answers
                    // "which colour am I about to get", which is not a
                    // question you have while dragging.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            model.hover(canvasX: p.x / viewScale, canvasY: p.y / viewScale)
                        case .ended:
                            model.endHover()
                        }
                    }
                    .overlay(alignment: .topLeading) { readout }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 42, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("Open a PNG or SVG").foregroundStyle(.secondary)
                        Button("Open…") { model.open() }
                            .tip("Open artwork (PNG / SVG / JPEG / WebP)")
                    }
                }

                if model.busy { ProgressView().controlSize(.large) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // The arrow keys walk the folder, which needs the canvas to be
            // focusable — a key press with nowhere to land does nothing and
            // says nothing about why. The menu carries ⌘[ and ⌘] for the same
            // actions, so this is the convenience rather than the only way.
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { model.step(-1); return .handled }
            .onKeyPress(.rightArrow) { model.step(1); return .handled }
            .onKeyPress(.upArrow) { model.step(-1); return .handled }
            .onKeyPress(.downArrow) { model.step(1); return .handled }
        }
    }

    /// What is under the pointer, while an eyedropper is armed.
    @ViewBuilder
    private var readout: some View {
        if model.picking {
            HStack(spacing: 7) {
                ZStack {
                    MiniChecker()
                    if let c = model.hovered { Color(c) }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
                Text(model.hovered?.hex ?? "transparent")
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .allowsHitTesting(false)
        }
    }

    /// Short on purpose: this one fires whenever the pointer rests anywhere on
    /// the artwork, so a paragraph here is a paragraph draped over the work.
    private static func canvasTip(_ pick: AppModel.CanvasPick) -> String {
        switch pick {
        case .backdrop: return "Click a pixel to make it the backdrop colour."
        case .colour:   return "Click a pixel to pick its colour."
        case .off:      return "Drag to move, pinch to zoom. Snaps to the centre and edges."
        }
    }

    /// Thirds and centre. Preview only, like the backdrop — a guide you can see
    /// through is worth more than one you have to remember the position of.
    @ViewBuilder
    private func grid(side: Double) -> some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var thirds = Path()
            for f in [1.0 / 3, 2.0 / 3] {
                thirds.move(to: CGPoint(x: w * f, y: 0)); thirds.addLine(to: CGPoint(x: w * f, y: h))
                thirds.move(to: CGPoint(x: 0, y: h * f)); thirds.addLine(to: CGPoint(x: w, y: h * f))
            }
            ctx.stroke(thirds, with: .color(.white.opacity(0.28)), lineWidth: 1)
            var centre = Path()
            centre.move(to: CGPoint(x: w / 2, y: 0)); centre.addLine(to: CGPoint(x: w / 2, y: h))
            centre.move(to: CGPoint(x: 0, y: h / 2)); centre.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(centre, with: .color(.white.opacity(0.45)), lineWidth: 1)
            // The inscribed circle, so a disc mask can be judged before it is on.
            ctx.stroke(Path(ellipseIn: CGRect(x: 0, y: 0, width: w, height: h)),
                       with: .color(.white.opacity(0.28)), lineWidth: 1)
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func guides(side: Double) -> some View {
        ZStack {
            if model.snappedX { Rectangle().fill(.pink).frame(width: 1, height: side) }
            if model.snappedY { Rectangle().fill(.pink).frame(width: side, height: 1) }
        }
        .allowsHitTesting(false)
    }
}
