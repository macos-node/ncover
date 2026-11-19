import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageError: LocalizedError, Equatable {
    case cannotOpen(String)
    case cannotDecode(String)
    case cannotEncode(ImageFormat)
    /// A JPEG was asked for and the result is not opaque. Writing it anyway
    /// would store every transparent pixel as black — see `writeJPEG`.
    case jpegHasAlpha

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let p):   return "Could not open \(p)"
        case .cannotDecode(let p): return "Could not decode \(p)"
        case .cannotEncode(let f): return "Could not encode \(f.name)"
        case .jpegHasAlpha:
            return "This result has transparent areas and a JPEG has no alpha channel, so they would be written as black. Save it as a PNG, or put a background behind it first."
        }
    }
}

/// The raster formats this app writes.
public enum ImageFormat: String, Sendable, Equatable, CaseIterable {
    case png, jpeg

    /// For a message. "JPEG", not "jpeg".
    public var name: String { self == .png ? "PNG" : "JPEG" }

    /// The quality a JPEG is written at. 92 because a file reaching this path
    /// is usually being made *smaller*, which hides the re-encoding, and a
    /// photographed cover has no alpha to need PNG for. The GTK sibling's
    /// `cap_format` passes the same number; a cover tidied on either platform
    /// should come out the same size and the same quality.
    public static let jpegQuality = 0.92

    /// What a file of this name is written as. `nil` for anything we do not
    /// write — WebP and GIF are refused with the reason rather than quietly
    /// turned into something else.
    public static func of(_ url: URL) -> ImageFormat? {
        switch url.pathExtension.lowercased() {
        case "png":          return .png
        case "jpg", "jpeg":  return .jpeg
        default:             return nil
        }
    }
}

/// An image's pixel size from its header, without decoding it.
///
/// `CGImageSourceCopyPropertiesAtIndex` reads the metadata and stops, which is
/// what makes a library-wide survey possible: deciding "is this already square"
/// or "is this within the cap" for a few thousand covers must not mean decoding
/// a few thousand JPEGs. The GTK sibling hand-parses PNG and JPEG headers for
/// the same reason — gdk-pixbuf's `file_info` reads far into a JPEG, 14 s for
/// 2,400 covers against 0.1 s — and here ImageIO already answers from the
/// header, so this is one place to be platform-native rather than faithful.
///
/// `nil` for anything with no pixel size: an SVG, a file that is not an image,
/// one that cannot be read.
public func imageSize(of url: URL) -> (width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0
    else { return nil }
    return (w, h)
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
            throw ImageError.cannotEncode(.png)
        }
        guard let cg = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { throw ImageError.cannotEncode(.png) }
        return cg
    }

    /// Is every pixel fully opaque?
    ///
    /// The question a JPEG has to ask, because alpha has nowhere to live in
    /// one and the bytes it leaves behind are not neutral.
    public var isOpaque: Bool {
        for i in stride(from: 3, to: px.count, by: 4) where px[i] != 255 { return false }
        return true
    }

    /// What a composition with a mask or a framed source leaves transparent.
    /// Cover / Fit output is PNG for exactly this reason.
    public func writePNG(to url: URL) throws {
        try write(to: url, as: .png)
    }

    /// A JPEG, at `ImageFormat.jpegQuality`.
    ///
    /// **Alpha is a decision, not a detail.** `cgImage()` carries
    /// non-premultiplied alpha, ImageIO's JPEG encoder drops that channel and
    /// keeps the RGB bytes — and `Raster.load` zeroes RGB wherever alpha is 0.
    /// So writing a masked render as a JPEG stores its transparent corners as
    /// **black**, with no error from anything. The caller therefore says which
    /// answer it wants, and both are in use:
    ///
    /// - `.refuse` — Overwrite, from the editor. A result with transparency is
    ///   refused rather than flattened onto a colour nobody chose.
    /// - `.discard` — batch's keep-format jobs. A JPEG source has no alpha to
    ///   begin with, so there is nothing to lose and the channel is simply not
    ///   written. It is stated at the call rather than assumed.
    public func writeJPEG(to url: URL, alpha: JPEGAlpha = .refuse) throws {
        try write(to: url, as: .jpeg, alpha: alpha)
    }

    public func write(to url: URL, as format: ImageFormat,
                      alpha: JPEGAlpha = .refuse) throws {
        if format == .jpeg, alpha == .refuse, !isOpaque { throw ImageError.jpegHasAlpha }
        let cg = format == .jpeg ? try opaqueCGImage() : try cgImage()
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, type as CFString, 1, nil
        ) else { throw ImageError.cannotEncode(format) }
        let opts: CFDictionary? = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: ImageFormat.jpegQuality] as CFDictionary
            : nil
        CGImageDestinationAddImage(dest, cg, opts)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.cannotEncode(format) }
    }

    /// The same bytes with the fourth one read as padding rather than alpha —
    /// no copy, no compositing, and nothing invented. This is what "discard
    /// the alpha channel" means here.
    private func opaqueCGImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else {
            throw ImageError.cannotEncode(.jpeg)
        }
        guard let cg = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { throw ImageError.cannotEncode(.jpeg) }
        return cg
    }

    /// Replace a file that already exists, keeping it whole if the write fails.
    ///
    /// The image is written to a sibling temp file and only then moved onto the
    /// original. Overwrite's target is typically a cover inside someone's music
    /// library: a half-written file there is worse than no write at all, and an
    /// encoder that fails midway through `url` leaves exactly that. The sibling
    /// is in the same directory so the move is a rename within one filesystem.
    public func replaceFile(at url: URL, as format: ImageFormat,
                            alpha: JPEGAlpha = .refuse) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".ncover-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try write(to: temp, as: format, alpha: alpha)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

/// What to do about alpha when the destination has no room for it.
public enum JPEGAlpha: Sendable, Equatable {
    /// Refuse the write and say why.
    case refuse
    /// Write the RGB and forget the channel.
    case discard
}
