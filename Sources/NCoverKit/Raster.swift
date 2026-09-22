import Foundation

/// A plain RGBA8 buffer, **non-premultiplied**, row-major, stride `width * 4`.
///
/// Deliberately not a `CGContext`. The rules this app inherits are defined on
/// exact bytes — nearest-neighbour sampling, a one-pixel coverage ramp, a
/// gradient normalised to the furthest pixel *centre*. Drawing through Core
/// Graphics would add antialiasing and premultiplication we do not control, and
/// the port would drift from its specification without anyone noticing. Core
/// Graphics still does what it is good at: decoding and encoding files.
public struct Raster: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, RGBA.
    public var px: [UInt8]

    public init(width: Int, height: Int, px: [UInt8]) {
        precondition(px.count == width * height * 4, "buffer is not width*height*4")
        self.width = width
        self.height = height
        self.px = px
    }

    /// Fully transparent.
    public init(empty width: Int, height: Int) {
        self.width = width
        self.height = height
        self.px = [UInt8](repeating: 0, count: width * height * 4)
    }

    @inline(__always)
    public func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    /// Nearest-neighbour sample, clamped to the edge.
    ///
    /// A colour tool must not invent colours: bilinear would blend two swatches
    /// into a third that is in neither.
    @inline(__always)
    public func sample(_ x: Int, _ y: Int) -> RGBA {
        guard width > 0, height > 0 else { return RGBA(0, 0, 0, 0) }
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        let i = index(cx, cy)
        return RGBA(px[i], px[i + 1], px[i + 2], px[i + 3])
    }

    @inline(__always)
    public mutating func set(_ x: Int, _ y: Int, _ c: RGBA) {
        let i = index(x, y)
        px[i] = c.r; px[i + 1] = c.g; px[i + 2] = c.b; px[i + 3] = c.a
    }
}

public struct RGBA: Equatable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public struct RGB: Equatable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public static let white = RGB(255, 255, 255)
    public static let black = RGB(0, 0, 0)
}

@inline(__always)
func lerp(_ a: UInt8, _ b: UInt8, _ t: Double) -> UInt8 {
    UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded().clamped(0, 255))
}

extension Double {
    @inline(__always) func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
