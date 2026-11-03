import Foundation

// A palette from a raster image.
//
// The honest framing: a PNG does not *declare* its colours, it only contains
// pixels, so anything we hand back is a summary. The summary is chosen to be
// one a person would recognise — the few tones they would name if asked, in
// the order of how much of the picture they cover.
//
// For an SVG we do not do this at all. An SVG states its colours, so
// `inspectSVG` reads the declared fills and stops instead. That is the
// difference between "roughly these tones" and "these exact values".

/// Alpha at or below this does not count. A near-transparent pixel's colour is
/// mostly whatever is behind it.
public let ALPHA_FLOOR: UInt8 = 128

/// Quantisation bucket: 4 bits per channel, i.e. 4096 bins. Coarse enough that
/// a gradient collapses into the few tones a human would name, fine enough to
/// keep two similar-but-distinct brand colours apart.
public let QUANT_SHIFT: UInt8 = 4

/// The image's dominant colours, most-used first.
///
/// Near-transparent pixels are skipped, and the representative for each bin is
/// the **mean** of the pixels in it rather than the bin centre — so every
/// colour handed back is one the image actually contains, not a rounded-off
/// approximation of one.
public func dominantColors(_ r: Raster, want: Int) -> [RGB] {
    guard want > 0, r.width > 0, r.height > 0 else { return [] }

    // key -> (count, sumR, sumG, sumB)
    var bins: [UInt16: (n: UInt64, r: UInt64, g: UInt64, b: UInt64)] = [:]
    bins.reserveCapacity(1024)

    var i = 0
    let end = r.px.count
    while i + 3 < end {
        defer { i += 4 }
        if r.px[i + 3] < ALPHA_FLOOR { continue }
        let cr = r.px[i], cg = r.px[i + 1], cb = r.px[i + 2]
        let key = (UInt16(cr >> QUANT_SHIFT) << 8)
            | (UInt16(cg >> QUANT_SHIFT) << 4)
            | UInt16(cb >> QUANT_SHIFT)
        var e = bins[key] ?? (0, 0, 0, 0)
        e.n += 1; e.r += UInt64(cr); e.g += UInt64(cg); e.b += UInt64(cb)
        bins[key] = e
    }

    // Sorted by count, then by key, so two bins of equal size come out in a
    // stable order rather than whatever the dictionary felt like.
    return bins.sorted { a, b in
        a.value.n != b.value.n ? a.value.n > b.value.n : a.key < b.key
    }
    .prefix(want)
    .map { _, e in
        RGB(UInt8(e.r / e.n), UInt8(e.g / e.n), UInt8(e.b / e.n))
    }
}
