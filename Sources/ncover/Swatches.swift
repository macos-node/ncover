import NCoverKit
import SwiftUI

// Small controls that show the thing rather than name it.
//
// A colour is better shown than spelled, and a mask shape is better drawn than
// called "Chamfer". Every one of these keeps a tooltip and an accessibility
// label, so nothing is lost by dropping the visible word — an icon without
// either is just a puzzle.

/// A selectable square showing a fill.
struct SwatchButton<Content: View>: View {
    let isSelected: Bool
    let help: String
    let accessibility: String
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                                      lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A checker small enough to read at swatch size — the full Checkerboard's 8px
/// squares would be a single flat tile in 22 points.
struct MiniChecker: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 4
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.85)))
            for row in 0..<4 {
                for col in 0..<4 where (row + col) % 2 == 1 {
                    ctx.fill(Path(CGRect(x: Double(col) * s, y: Double(row) * s,
                                         width: s, height: s)),
                             with: .color(Color(white: 0.6)))
                }
            }
        }
    }
}

/// The backdrop, as colours rather than colour names.
struct BackdropRow: View {
    @Binding var backdrop: Backdrop

    var body: some View {
        HStack(spacing: 6) {
            SwatchButton(isSelected: backdrop == .checker,
                         help: "Checker — transparency looks like transparency. The honest default.",
                         accessibility: "Checker backdrop") { backdrop = .checker } content: {
                MiniChecker()
            }
            ForEach([Backdrop.grey, .black, .white], id: \.self) { b in
                SwatchButton(isSelected: backdrop == b,
                             help: "\(b.label) backdrop",
                             accessibility: "\(b.label) backdrop") { backdrop = b } content: {
                    (b.colour ?? .gray)
                }
            }
            if case .custom(let c) = backdrop {
                SwatchButton(isSelected: true,
                             help: "The colour you picked",
                             accessibility: "Picked backdrop") { } content: { c }
            }
        }
    }
}

/// What sits outside the mask, shown as what it will look like.
struct FillRow: View {
    @Binding var kind: AppModel.FillKind
    let solid: Color
    let gradInner: Color
    let gradOuter: Color

    var body: some View {
        HStack(spacing: 6) {
            SwatchButton(isSelected: kind == .alpha,
                         help: "Transparent — the honest default for artwork that will sit on an unknown background.",
                         accessibility: "Transparent corners") { kind = .alpha } content: {
                MiniChecker()
            }
            SwatchButton(isSelected: kind == .white,
                         help: "White corners",
                         accessibility: "White corners") { kind = .white } content: { Color.white }
            SwatchButton(isSelected: kind == .solid,
                         help: "A colour of your choosing",
                         accessibility: "Coloured corners") { kind = .solid } content: { solid }
            SwatchButton(isSelected: kind == .gradient,
                         help: "A radial gradient, from the mask's rim out to the corner",
                         accessibility: "Gradient corners") { kind = .gradient } content: {
                LinearGradient(colors: [gradInner, gradOuter],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

extension AppModel.MaskKind {
    /// SF Symbols that *are* the shapes. The chamfer is an octagon, which is
    /// precisely what cutting four corners off a square produces.
    var symbol: String {
        switch self {
        case .disc:    return "circle.fill"
        case .rounded: return "app.fill"
        case .chamfer: return "octagon.fill"
        }
    }

    var help: String {
        switch self {
        case .disc:    return "Disc — a circle inscribed in the canvas."
        case .rounded: return "Rounded rectangle. At 100% it is exactly the disc."
        case .chamfer: return "Chamfer — corners cut straight, giving an octagon."
        }
    }
}
