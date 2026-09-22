import AppKit
import NCoverKit
import SwiftUI

/// What sits behind the artwork while you work.
///
/// **Preview only.** It is never composited into anything written to disk — the
/// point of it is to judge alpha against the background the artwork will
/// actually sit on, which only works if it stays out of the file. Anything that
/// makes this reach the renderers is a bug, not a feature.
enum Backdrop: Hashable {
    /// The honest default: transparency looks like transparency.
    case checker
    case grey
    case black
    case white
    case custom(Color)

    var colour: Color? {
        switch self {
        case .checker:       return nil
        case .grey:          return Color(white: 0.25)
        case .black:         return .black
        case .white:         return .white
        case .custom(let c): return c
        }
    }

    var label: String {
        switch self {
        case .checker: return "Checker"
        case .grey:    return "Grey"
        case .black:   return "Black"
        case .white:   return "White"
        case .custom:  return "Picked"
        }
    }

    // MARK: persistence — a backdrop that reset every launch would be a chore

    private static let key = "backdrop"

    func save() {
        let d = UserDefaults.standard
        switch self {
        case .checker, .grey, .black, .white:
            d.set(label, forKey: Self.key)
        case .custom(let c):
            let rgb = c.rgb
            d.set(String(format: "#%02x%02x%02x", rgb.r, rgb.g, rgb.b), forKey: Self.key)
        }
    }

    static func load() -> Backdrop {
        guard let s = UserDefaults.standard.string(forKey: key) else { return .checker }
        switch s {
        case "Grey":  return .grey
        case "Black": return .black
        case "White": return .white
        case let hex where hex.hasPrefix("#") && hex.count == 7:
            var v: UInt64 = 0
            Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
            return .custom(Color(RGB(UInt8((v >> 16) & 0xff),
                                     UInt8((v >> 8) & 0xff),
                                     UInt8(v & 0xff))))
        default: return .checker
        }
    }
}

/// The transparency checker. Artwork with alpha is the normal case here, so
/// "transparent" has to look different from "white".
struct Checkerboard: View {
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
