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
                        guides(side: side)
                    }
                    .frame(width: side, height: side)
                    .overlay(Rectangle().strokeBorder(.separator, lineWidth: 1))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard !model.samplingBackdrop else { return }
                                model.beginDrag()
                                model.dragTo(v.translation, viewScale: viewScale)
                            }
                            .onEnded { v in
                                if model.samplingBackdrop {
                                    model.sampleBackdrop(canvasX: v.location.x / viewScale,
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
                    .tip(model.samplingBackdrop
                          ? "Click a pixel to make it the backdrop colour."
                          // Short on purpose: this one fires whenever the
                          // pointer rests anywhere on the artwork, so a
                          // paragraph here is a paragraph draped over the work.
                          : "Drag to move, pinch to zoom. Snaps to the centre and edges.")
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
        }
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
