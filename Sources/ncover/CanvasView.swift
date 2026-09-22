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
                Color(nsColor: .underPageBackgroundColor)

                if let img = model.preview {
                    ZStack {
                        Checkerboard()
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
                                model.beginDrag()
                                model.dragTo(v.translation, viewScale: viewScale)
                            }
                            .onEnded { _ in model.endDrag() }
                    )
                    // simultaneous, not a second .gesture: two plain gesture
                    // modifiers compete, and the later one swallowed the drag.
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in model.zoom(by: 1 + (v.magnification - 1) * 0.06) }
                            .onEnded { _ in model.endZoom() }
                    )
                    .help("""
                        Drag to move the image on the canvas. Pinch to zoom.

                        It snaps to the canvas centre and edges — each axis \
                        independently, so you can be held horizontally while \
                        still free vertically. A pink guide shows which one caught.
                        """)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 42, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("Open a PNG or SVG").foregroundStyle(.secondary)
                        Button("Open…") { model.open() }
                            .help("Open an image (PNG / SVG / JPEG / WebP)")
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
            if model.snappedX {
                Rectangle().fill(.pink).frame(width: 1, height: side)
            }
            if model.snappedY {
                Rectangle().fill(.pink).frame(width: side, height: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The transparency checker. Artwork with alpha corners is the normal case
/// here, so "transparent" has to look different from "white".
private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: Double = 8
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.22)))
            var y: Double = 0, row = 0
            while y < size.height {
                var x: Double = (row % 2 == 0) ? 0 : s
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)),
                             with: .color(Color(white: 0.28)))
                    x += s * 2
                }
                y += s; row += 1
            }
        }
    }
}
