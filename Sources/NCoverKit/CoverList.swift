import Foundation

// ndisc's Export list, as a batch scope. Phase C of the parity plan.
//
// This is the interop surface of the cover review loop, and it is a plain text
// file on purpose: ndisc knows what is published and this app does not, so
// ndisc says which covers need work and ncover reads that rather than ndisc's
// database. One line per release, tab-separated, no header:
//
//   folder · cover file · artist — title · disk WxH · published WxH · format ·
//   kinds · actions
//
// `-` marks an empty field, and **every column after the first is optional**,
// so a hand-made list of folders — one per line — works as well.

/// The `ncover:` and `ndisc:` actions ndisc writes, **in the order ndisc means
/// them to run**. The second element is how a count of them reads in the
/// survey line.
///
/// ncover acts on the `ncover:` ones; the rest are counted so the survey can
/// say what belongs to a person or to ndisc instead of silently dropping it.
public let LIST_ACTIONS: [(action: String, what: String)] = [
    ("resource",        "need a new source"),
    ("review",          "to review"),
    ("ncover:square",   "to square"),
    ("ncover:cap",      "to cap"),
    ("ncover:convert",  "to convert"),
    ("ndisc:reconcile", "for ndisc to reconcile"),
    ("ndisc:upload",    "for ndisc to upload"),
]

public struct CoverListLine: Equatable, Sendable {
    /// The release folder. Always absolute — a line whose first column is not
    /// is skipped, which is also how ndisc's "artist — title" fallback for a
    /// release with no folder gets left out.
    public var folder: URL
    /// The one image the flags are about, when the line names it: ncover then
    /// touches that file and nothing else in the folder, so a release's back
    /// or inlay art is never caught up in a run.
    public var cover: URL?
    /// "Artist — Title", for the Files list. The folder path is a much worse
    /// answer to "what will this touch" than the record's own name.
    public var name: String?
    public var actions: [String]

    public init(folder: URL, cover: URL? = nil, name: String? = nil, actions: [String] = []) {
        self.folder = folder; self.cover = cover; self.name = name; self.actions = actions
    }
}

public struct CoverList: Equatable, Sendable {
    public var lines: [CoverListLine]
    /// The folders' common parent: what the output mirrors and what the write
    /// guard protects.
    public var root: URL?
    /// Whether any line carried an actions column. Without one, every line is
    /// in every run — which is what makes a hand-made list of folders work.
    public var hasActions: Bool
    /// Lines that could not be used, by 1-based line number. Reported rather
    /// than dropped: a list that quietly shrinks is worse than one that
    /// complains.
    public var skipped: [Int]

    /// Does a run of `job` take this line?
    ///
    /// **The job picks the lines.** With an actions column, Cap takes only
    /// `ncover:cap` and Square and Pad only `ncover:square` — so one export
    /// drives several runs, each doing one kind of work. Without one, or for a
    /// framing, every line is in.
    public func selects(_ line: CoverListLine, job: BatchJob) -> Bool {
        guard hasActions, let want = job.listAction else { return true }
        return line.actions.contains(want)
    }

    /// What a run of `job` leaves out, in words, by each line's first action in
    /// ndisc's own order: "112 need a new source · 24 to review". Counted,
    /// never touched — these belong to a person or to ndisc.
    public func leftOut(job: BatchJob) -> String {
        guard hasActions, job.listAction != nil else { return "" }
        var counts = [Int](repeating: 0, count: LIST_ACTIONS.count)
        var nothing = 0
        for line in lines where !selects(line, job: job) {
            if let i = LIST_ACTIONS.firstIndex(where: { line.actions.contains($0.action) }) {
                counts[i] += 1
            } else {
                nothing += 1
            }
        }
        var parts = zip(LIST_ACTIONS, counts)
            .filter { $0.1 > 0 }
            .map { "\($0.1) \($0.0.what)" }
        if nothing > 0 { parts.append("\(nothing) with nothing to do") }
        return parts.joined(separator: " · ")
    }
}

/// A field, or `nil` for an empty one. ndisc writes `-` for empty; a hand-made
/// list is likelier to leave it blank.
private func listField(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty, t != "-" else { return nil }
    return t
}

/// Parse an Export list, or a hand-made list of folders.
///
/// Forgiving on purpose, in the places where being strict would only lose
/// work: blank lines and `#` comments are ignored, the columns after the first
/// are optional, and a second column that is not an image path inside the
/// folder is treated as a note rather than a cover. Strict in exactly one
/// place — a first column that is not an absolute folder is **skipped and
/// counted**, because guessing what it meant is how a run touches the wrong
/// files.
public func parseCoverList(_ text: String) -> CoverList {
    var lines: [CoverListLine] = []
    var skipped: [Int] = []
    var hasActions = false

    for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
        let row = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        let cols = row.components(separatedBy: "\t")
        guard let first = listField(cols.first), first.hasPrefix("/") else {
            skipped.append(i + 1)
            continue
        }
        let folder = URL(fileURLWithPath: first).standardizedFileURL

        // The second column is the cover only when it IS one: an image path
        // inside this folder. ndisc writes the path it has on record, and a
        // hand-made list may put a note there instead.
        let cover = listField(cols.count > 1 ? cols[1] : nil)
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { c in
                IMAGE_EXTS.contains(c.pathExtension.lowercased())
                    && c.path.hasPrefix(folder.path + "/")
            }

        var actions: [String] = []
        if cols.count > 7 {
            hasActions = true
            actions = (listField(cols[7]) ?? "")
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        lines.append(CoverListLine(folder: folder, cover: cover,
                                   name: listField(cols.count > 2 ? cols[2] : nil),
                                   actions: actions))
    }

    return CoverList(lines: lines,
                     root: commonAncestor(of: lines.map(\.folder)),
                     hasActions: hasActions,
                     skipped: skipped)
}

extension Optional {
    /// `filter` on an optional, which Swift has for sequences and not for this.
    fileprivate func filter(_ keep: (Wrapped) -> Bool) -> Wrapped? {
        guard let v = self, keep(v) else { return nil }
        return v
    }
}

public func readCoverList(at url: URL) throws -> CoverList {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw BatchError.listUnreadable(url.lastPathComponent)
    }
    return parseCoverList(text)
}
