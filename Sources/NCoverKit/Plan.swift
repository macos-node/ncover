import Foundation

// What a run would touch, as a list you can look at. Phase D of the parity
// plan.
//
// The survey counts files; this names them, says what each one would become,
// and puts them in the order worth reviewing. It is built from header reads
// only — no image is decoded here — because the point is that it can exist for
// a whole library and stay current while someone changes the recipe.

public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    init(_ t: (width: Int, height: Int)) { self.init(width: t.width, height: t.height) }

    public var long: Int { max(width, height) }
    public var isSquare: Bool { width == height }
    /// How far off square, as a fraction of the longer side. 0 for a square.
    public var offSquare: Double {
        guard long > 0 else { return 0 }
        return Double(long - min(width, height)) / Double(long)
    }
}

/// One file a run would write, with its number.
///
/// The number is shared by the grid and the Files list on purpose: they are
/// one model under one selection, so "41 / 241 · cover.jpg" means the same
/// thing in both and selecting in either scrolls the other.
public struct PlanItem: Identifiable, Equatable, Sendable {
    public var number: Int
    public var url: URL
    /// The path within the scope — what the output mirrors.
    public var rel: String
    /// "Artist — Title" where the scope knew it, else the folder's own path.
    public var name: String
    /// The file as it is now. `nil` for a vector or anything with no readable
    /// pixel size.
    public var from: PixelSize?
    /// What the run would write. `nil` only if the file would be left alone,
    /// and such a file is not in the plan at all.
    public var to: PixelSize?
    /// The change in words: "600 × 533 → 533 × 533 · 67 px off the sides (11%)".
    public var words: String

    public var id: String { url.path }
}

/// Name a file by the release it belongs to, walking up to the scope's prefix.
///
/// A scope's `names` are keyed by root, and a hit can be nested below one (a
/// disc subfolder). Falling straight back to the path would lose the record's
/// name for exactly the releases that are filed in subfolders.
func nameForFile(_ url: URL, in scope: BatchScope) -> String {
    var dir = url.deletingLastPathComponent().standardizedFileURL
    let stop = scope.strip.standardizedFileURL.path
    while true {
        if let n = scope.names[dir.path] { return n }
        if dir.path == stop || dir.path == "/" { break }
        let up = dir.deletingLastPathComponent()
        if up.path == dir.path { break }
        dir = up
    }
    return relativePath(of: url.deletingLastPathComponent(), under: scope.strip)
}

/// Every file a run of `recipe` would write, numbered and in review order.
///
/// **The length of this list is the Run button's count.** Under a framing that
/// is every file the scope selects; under a keep-format job it is only the
/// files the run would change, which is the same decision `wouldChange` makes
/// for the counter — one arithmetic, as phase B established.
///
/// Review order is by what you would want to look at first: under Cap the
/// largest files, under Square and Pad the least square ones, and under a
/// framing the order the run itself goes in (by path), because every file gets
/// the same treatment and there is nothing to triage.
public func planItems(files: [URL], scope: BatchScope, recipe r: Recipe) -> [PlanItem] {
    var rows: [(url: URL, from: PixelSize?, to: PixelSize?)] = []
    for f in files {
        let from = imageSize(of: f).map(PixelSize.init)
        let to: PixelSize?
        if r.job.keepsFile {
            guard let from else { continue }   // no pixel size: nothing to tidy
            guard let want = jobResultSize(width: from.width, height: from.height,
                                           job: r.job, canvas: r.canvas) else { continue }
            to = PixelSize(want)
        } else {
            to = PixelSize(width: r.canvas, height: r.canvas)
        }
        rows.append((f, from, to))
    }

    switch r.job {
    case .cap:
        rows.sort { ($0.from?.long ?? 0, $0.url.path) > ($1.from?.long ?? 0, $1.url.path) }
    case .square, .pad:
        rows.sort {
            let a = $0.from?.offSquare ?? 0, b = $1.from?.offSquare ?? 0
            return a == b ? $0.url.path < $1.url.path : a > b
        }
    case .frame:
        rows.sort { $0.url.path < $1.url.path }
    }

    return rows.enumerated().map { i, row in
        PlanItem(number: i + 1,
                 url: row.url,
                 rel: relativePath(of: row.url, under: scope.strip),
                 name: nameForFile(row.url, in: scope),
                 from: row.from,
                 to: row.to,
                 words: row.from.flatMap { f in
                     row.to.map { t in
                         sizeChangeInWords(from: (f.width, f.height),
                                           to: (t.width, t.height), job: r.job)
                     }
                 } ?? "")
    }
}
