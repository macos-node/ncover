import Foundation

// The keep-format jobs: Cap, Square and Pad. Phase B of the parity plan.
//
// These are **not framings onto a square canvas.** Cover and Fit compute a
// placement and write a new square PNG; these three tidy a file in place —
// same name, same format, same shape where they can — and **write nothing at
// all for a file they would not change**. That last property is what makes a
// run over a whole library something you can review rather than a leap, and it
// is why their counts are decided from a header read rather than a render.

/// What fills the bars Pad leaves.
public enum PadFill: Equatable, Hashable, Sendable {
    /// Each bar is the average of the image edge beside it, **transparency
    /// included** — so a logo on a transparent background gets transparent
    /// bars, and a photographed cover gets the colour it runs out on.
    case edge
    case white
    case black
    case solid(RGB)
}

/// What a batch run does to each file.
///
/// Deliberately not more cases on `Framing`: here `Framing` is the *editor's*
/// placement intent — `resetFraming()` turns it into a `Placement` — and the
/// canvas picker and the batch picker read the same type. The GTK sibling has
/// no such sharing, which is why `Framing::Cap` is fine there and would leak
/// into the editor's control here.
public enum BatchJob: Equatable, Hashable, Sendable {
    /// Cover or Fit: a placement onto a square canvas, written as a PNG.
    case frame(Framing)
    /// Shrink only images whose longer side exceeds the size. Shape kept.
    case cap
    /// Crop a non-square image to the centre of its shorter side.
    case square
    /// Square a non-square image the other way: bars rather than a crop.
    case pad(PadFill)
    /// Re-encode a PNG as a JPEG under the same stem — `cover.png` →
    /// `cover.jpg`. Not one pixel changes; the encoder is the whole job.
    ///
    /// ndisc asks for this with `ncover:convert`, for a cover or a label
    /// image published as a PNG where the library's shape is JPEG.
    case convert

    /// Does this job keep the file's own name, extension and format?
    ///
    /// The predicate the write path and the destination planner read. A job
    /// that keeps the file also writes nothing when it would change nothing.
    public var keepsFile: Bool {
        switch self {
        case .cap, .square, .pad: return true
        case .frame, .convert:    return false
        }
    }

    /// Does the output keep the source's own name, whatever its extension?
    ///
    /// True for everything but a framing, which writes `<stem>.png` (or
    /// `<stem>-disc.png`) onto its own canvas. Convert keeps the stem and
    /// takes a new extension, which is exactly why it is not `keepsFile`:
    /// the file it writes is not the file it read.
    public var keepsName: Bool {
        if case .frame = self { return false }
        return true
    }

    /// What this job writes each file as. `nil` means "whatever the source
    /// already is", which is the keep-format jobs' whole point.
    public var writes: ImageFormat? {
        switch self {
        case .frame:              return .png
        case .cap, .square, .pad: return nil
        case .convert:            return .jpeg
        }
    }

    /// What to do when the destination cannot hold the source's alpha.
    ///
    /// **Convert is the one job that must refuse.** Cap, Square and Pad carry
    /// a JPEG's own RGB through, so there is no alpha to lose; a framing
    /// writes PNG. Convert is handed a PNG, which is where transparency
    /// actually lives — a label logo on a transparent background is the usual
    /// case — and discarding it stores those pixels as **black**, with no
    /// error from any layer. So it refuses, and says what to do instead.
    public var alphaRule: JPEGAlpha { self == .convert ? .refuse : .discard }

    /// Which of ndisc's `ncover:` actions this job acts on, for a list scope.
    ///
    /// Square and Pad both answer `square`, because cropping or padding is the
    /// operator's choice per run — ndisc says a cover is off-square, not what
    /// to do about it.
    public var listAction: String? {
        switch self {
        case .frame:            return nil
        case .cap:              return "ncover:cap"
        case .square, .pad:     return "ncover:square"
        case .convert:          return "ncover:convert"
        }
    }

    /// A word for a results row or a tooltip.
    public var name: String {
        switch self {
        case .frame(let f):  return f == .cover ? "Cover" : "Fit"
        case .cap:           return "Cap"
        case .square:        return "Square"
        case .pad:           return "Pad"
        case .convert:       return "Convert"
        }
    }
}

/// Why a job and a disc cannot run together, in words. `nil` when they can.
///
/// A job that does not write a PNG has nowhere to put a disc's transparent
/// corners: Cap, Square and Pad keep the file's own format, which is a JPEG as
/// often as not, and Convert writes a JPEG by definition. The GTK sibling
/// refuses the same combination rather than quietly dropping one of the two
/// choices.
public func jobRefusal(job: BatchJob, disc: Bool) -> String? {
    guard disc, job.writes != .png else { return nil }
    let what = job == .convert
        ? "Convert writes a JPEG, which has no room for"
        : "\(job.name) keeps each file's own format, which has no room for"
    return "\(what) a disc's transparent corners. Turn the disc off to \(job.name.lowercased())."
}

/// The size an image shrinks to under `cap`, or `nil` if it is already within
/// it. Aspect is kept and the longer side becomes exactly `cap`.
public func capSize(_ w: Int, _ h: Int, cap: Int) -> (width: Int, height: Int)? {
    let long = max(w, h)
    guard long > cap, w > 0, h > 0, cap > 0 else { return nil }
    let s = Double(cap) / Double(long)
    return (max(Int((Double(w) * s).rounded()), 1), max(Int((Double(h) * s).rounded()), 1))
}

/// Crop to a square of the shorter side, taken from the centre.
///
/// The centre is the only crop a batch can choose. A cover that needs another
/// one — a CD insert with the hinge strip down one side — is the editor's job,
/// and the grid's *Open folder* and double-click are how you get there.
public func centreSquare(_ src: Raster) -> Raster {
    let side = min(src.width, src.height)
    guard side > 0, src.width != src.height else { return src }
    let x0 = (src.width - side) / 2
    let y0 = (src.height - side) / 2
    var dst = Raster(empty: side, height: side)
    for y in 0..<side {
        for x in 0..<side {
            dst.set(x, y, src.sample(x0 + x, y0 + y))
        }
    }
    return dst
}

/// Put a non-square image in the middle of a square of its **longer** side,
/// and fill the two bars.
///
/// For covers with art or type running to the edge, where a centre crop would
/// cut into them, and for label logos.
public func padToSquare(_ src: Raster, fill: PadFill) -> Raster {
    let side = max(src.width, src.height)
    guard side > 0, src.width != src.height else { return src }
    // The two bars, in order: top/bottom for a wide image, left/right for a
    // tall one. `edge` reads the row or column each bar sits against, so the
    // two can differ — a sky at the top and a floor at the bottom.
    let (first, second): (RGBA, RGBA)
    switch fill {
    case .white:       first = RGBA(255, 255, 255, 255); second = first
    case .black:       first = RGBA(0, 0, 0, 255);       second = first
    case .solid(let c): first = RGBA(c.r, c.g, c.b, 255); second = first
    case .edge:
        if src.width >= src.height {
            first  = edgeAverage(src, row: 0)
            second = edgeAverage(src, row: src.height - 1)
        } else {
            first  = edgeAverage(src, column: 0)
            second = edgeAverage(src, column: src.width - 1)
        }
    }

    var dst = Raster(empty: side, height: side)
    let x0 = (side - src.width) / 2
    let y0 = (side - src.height) / 2
    for y in 0..<side {
        for x in 0..<side {
            let sx = x - x0, sy = y - y0
            if sx >= 0, sy >= 0, sx < src.width, sy < src.height {
                dst.set(x, y, src.sample(sx, sy))
            } else if src.width >= src.height {
                dst.set(x, y, sy < 0 ? first : second)
            } else {
                dst.set(x, y, sx < 0 ? first : second)
            }
        }
    }
    return dst
}

/// The average of one edge, **in premultiplied space** and keeping the mean
/// alpha — the same reasoning as the downscaler. Averaging straight RGBA lets
/// transparent pixels drag their meaningless colour in; keeping the mean alpha
/// is what gives a transparent PNG transparent bars instead of grey ones.
func edgeAverage(_ src: Raster, row: Int? = nil, column: Int? = nil) -> RGBA {
    var r = 0.0, g = 0.0, b = 0.0, a = 0.0
    let n: Int
    if let y = row {
        n = src.width
        for x in 0..<n {
            let p = src.sample(x, y)
            let af = Double(p.a) / 255
            r += Double(p.r) * af; g += Double(p.g) * af; b += Double(p.b) * af; a += af
        }
    } else if let x = column {
        n = src.height
        for y in 0..<n {
            let p = src.sample(x, y)
            let af = Double(p.a) / 255
            r += Double(p.r) * af; g += Double(p.g) * af; b += Double(p.b) * af; a += af
        }
    } else {
        return RGBA(0, 0, 0, 0)
    }
    guard n > 0 else { return RGBA(0, 0, 0, 0) }
    guard a > 0 else { return RGBA(0, 0, 0, 0) }   // a wholly transparent edge
    let k = 1.0 / a
    return RGBA(UInt8((r * k).rounded().clamped(0, 255)),
                UInt8((g * k).rounded().clamped(0, 255)),
                UInt8((b * k).rounded().clamped(0, 255)),
                UInt8((a / Double(n) * 255).rounded().clamped(0, 255)))
}

/// What a keep-format job would write for an image of this size, or `nil` when
/// it would leave the file alone.
///
/// **The counter and the run both ask this, from a header read.** "Run (245 of
/// 2,377 to shrink)" is a promise about how many of someone's files are about
/// to be rewritten; two code paths answering it separately is how it stops
/// being one. Note that Square and Pad do not cap an image that is already
/// square, however large — squaring is what they do, and capping is Cap's job.
public func jobResultSize(width w: Int, height h: Int,
                          job: BatchJob, canvas: Int) -> (width: Int, height: Int)? {
    guard w > 0, h > 0 else { return nil }
    switch job {
    case .frame:
        return (canvas, canvas)
    case .convert:
        // Convert changes the encoding and not one pixel. Whether it writes
        // at all is a question about the file's format, which a size cannot
        // answer — `wouldWrite` is where that is decided.
        return (w, h)
    case .cap:
        return capSize(w, h, cap: canvas)
    case .square:
        guard w != h else { return nil }
        let side = min(w, h)
        return capSize(side, side, cap: canvas) ?? (side, side)
    case .pad:
        guard w != h else { return nil }
        let side = max(w, h)
        return capSize(side, side, cap: canvas) ?? (side, side)
    }
}

/// What a run of `job` would write for the file at `url`, or `nil` when it
/// would leave it alone.
///
/// **The one answer the survey, the plan and the run share**, and the only
/// place a job's decision meets a real file. From the header alone, so a
/// library-scale survey decodes nothing. A file with no readable pixel size
/// (an SVG, something that is not an image) has nothing to tidy and is left
/// alone — but a framing still writes it, since it renders onto its own
/// canvas and a vector has one.
public func wouldWrite(_ url: URL, job: BatchJob, canvas: Int) -> (width: Int, height: Int)? {
    if case .frame = job { return (canvas, canvas) }
    guard let s = imageSize(of: url) else { return nil }
    if job == .convert {
        // A file already in the format Convert writes is not converted: it is
        // the same rule as "writes nothing for a file it would not change",
        // asked of the encoding rather than the shape.
        guard ImageFormat.of(url) == .png else { return nil }
        return (s.width, s.height)
    }
    return jobResultSize(width: s.width, height: s.height, job: job, canvas: canvas)
}

/// Would a run of `job` rewrite the file at `url`?
public func wouldChange(_ url: URL, job: BatchJob, canvas: Int) -> Bool {
    wouldWrite(url, job: job, canvas: canvas) != nil
}

/// Run one keep-format job over a decoded source. `nil` means "left alone".
public func jobRender(_ src: Raster, job: BatchJob, canvas: Int) -> Raster? {
    guard let want = jobResultSize(width: src.width, height: src.height,
                                   job: job, canvas: canvas) else { return nil }
    switch job {
    case .frame:
        return nil     // framings go through `render`; this function is the other family
    case .convert:
        return src     // not one pixel changes; the encoder is the whole job
    case .cap:
        return areaResample(src, width: want.width, height: want.height)
    case .square:
        let cropped = centreSquare(src)
        return cropped.width == want.width
            ? cropped
            : areaResample(cropped, width: want.width, height: want.height)
    case .pad(let fill):
        let padded = padToSquare(src, fill: fill)
        return padded.width == want.width
            ? padded
            : areaResample(padded, width: want.width, height: want.height)
    }
}

/// How a file's size change reads in words: what the Files list says beside
/// each row.
///
/// **It takes the job rather than inferring from the two sizes**, and that is
/// not fussiness. A padded image that is then shrunk to the cap comes out
/// *smaller* than it went in — 1000 × 500 padded to 1000² and capped to 400²
/// — and a reader working from the sizes alone calls that a crop. It is the
/// opposite of a crop. The pixel figures describe what the job did to the
/// source, in the source's own pixels; the arrow shows where it ended up.
public func sizeChangeInWords(from: (width: Int, height: Int),
                              to: (width: Int, height: Int),
                              job: BatchJob) -> String {
    let head = "\(from.width) × \(from.height) → \(to.width) × \(to.height)"
    let long = max(from.width, from.height), short = min(from.width, from.height)
    guard long != short else { return head }

    switch job {
    case .square:
        let off = long - short
        let pct = Int((Double(off) / Double(long) * 100).rounded())
        let side = from.width > from.height ? "the sides" : "top and bottom"
        return "\(head) · \(off) px off \(side) (\(pct)%)"
    case .pad:
        let add = long - short
        let side = from.width > from.height ? "top and bottom" : "left and right"
        return "\(head) · \(add) px added \(side)"
    case .convert:
        // The sizes are equal by definition, so saying them twice tells you
        // nothing about what the run would do to this file.
        return "\(from.width) × \(from.height) · PNG → JPEG"
    case .cap, .frame:
        return head
    }
}
