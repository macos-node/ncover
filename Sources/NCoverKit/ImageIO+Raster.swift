import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageError: LocalizedError {
    case cannotOpen(String)
    case cannotDecode(String)
    case cannotEncode

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let p):   return "Could not open \(p)"
        case .cannotDecode(let p): return "Could not decode \(p)"
        case .cannotEncode:        return "Could not encode PNG"
        }
    }
}

extension Raster {
    /// Decode any raster format Core Graphics knows (PNG / JPEG / WebP).
    ///
    /// Core Graphics will only give us *premultiplied* bytes from a bitmap
    /// context, so we un-premultiply on the way in and keep one representation
    /// everywhere. Skipping this would darken every antialiased edge the moment
    /// it passed through the disc mask.
    public static func load(contentsOf url: URL) throws -> Raster {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw ImageError.cannotOpen(url.lastPathComponent) }
        return try Raster(cgImage: cg)
    }

    public init(cgImage cg: CGImage) throws {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ImageError.cannotDecode("image") }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Un-premultiply.
        for i in stride(from: 0, to: buf.count, by: 4) {
            let a = buf[i + 3]
            if a == 0 { buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; continue }
            if a == 255 { continue }
            let af = Double(a)
            for c in 0..<3 {
                buf[i + c] = UInt8((Double(buf[i + c]) * 255 / af).rounded().clamped(0, 255))
            }
        }
        self.init(width: w, height: h, px: buf)
    }

    /// A CGImage carrying our exact bytes. `CGImage` — unlike `CGBitmapContext`
    /// — accepts non-premultiplied alpha, so nothing is reinterpreted here.
    public func cgImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else {
            throw ImageError.cannotEncode
        }
        guard let cg = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { throw ImageError.cannotEncode }
        return cg
    }

    /// Always PNG. Not a preference — the disc / label mask needs an alpha
    /// channel, and there is nowhere for one to live in a JPEG.
    public func writePNG(to url: URL) throws {
        let cg = try cgImage()
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw ImageError.cannotEncode }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.cannotEncode }
    }
}
