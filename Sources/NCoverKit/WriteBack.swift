import Foundation

// Writing a run back into the library — step 3 of the cover review loop, and
// phase F1 of docs/gtk-parity-plan.md.
//
// Cap, Square or Pad replaces each cover where it lives and keeps the
// original. Until this, a run ended in an output folder and the swap back was
// a desktop script (`swap-covers.py`); the GTK sibling built it first, by
// agreement, and this is a port of its decisions rather than of its Rust.
//
// The rules, each of which is a test:
//
// - **Only the keep-format jobs.** Cap, Square and Pad write the file's own
//   name and format, so `cover.jpg` is still `cover.jpg` and ndisc's
//   `cover_art_path` still points at it. Cover and Fit write a PNG, usually
//   under another name, which would orphan that path.
// - **The library never loses a file.** Per file: copy the original into the
//   originals folder (a temp name beside its slot, synced, its length
//   checked, then renamed into the slot), write the result beside the source
//   and rename it over it, then log. A copy and not a move, so the originals
//   folder may sit on another disk; and at every moment in between, the
//   library holds either the old file or the new one, never neither.
// - **The original's slot decides.** A file whose slot is already taken is
//   refused: a second run must never overwrite the first original.
// - **The place is the source's own**, its whole path under the scope's
//   prefix (`placeUnder`, phase F6), so `Autechre/Amber/cover.jpg` and
//   `Boards/Amber/cover.jpg` keep their originals in two different places. A
//   file with no place is refused rather than given one.
// - **Every swap is logged** in `ncover-log.tsv` in the originals folder, as
//   plain TSV, and the last run can be put back from it. A swap the log does
//   not know about cannot be undone, so a swap whose line cannot be written
//   is undone at once instead of being left in place.
//
// The log is **the same file, name and columns as the GTK app's**, which is
// not decoration: one library, one originals folder, and either app may have
// written the run you are putting back.

/// The log, in the root of the originals folder.
public let WRITEBACK_LOG = "ncover-log.tsv"

private let LOG_HEAD = """
# n.cover write-back log. One `swap` line per replaced file, one `undo` line per run put back.
# swap\trun\ttime\tjob\tlibrary file\toriginal kept\tbefore\tafter\twritten bytes\twritten mtime (ns)
# undo\trun\ttime\trestored\tskipped

"""

public enum WriteBackError: LocalizedError, Equatable {
    /// Cover or Fit asked to write into the library.
    case notAKeepFormatJob(String)
    case originalsIsLibrary
    case originalsInsideLibrary
    case libraryInsideOriginals
    /// An original is already kept for this file.
    case slotTaken(String)
    /// The log is TSV, and this path would break a line of it.
    case pathHoldsTabOrNewline(String)
    /// No place under the scope's prefix, so no slot either.
    case noPlace(String)
    case copyIncomplete(copied: Int, of: Int)
    /// The log could not be written. The swap is undone first, and this says
    /// whether that worked.
    case logUnwritable(why: String, putBack: String)

    public var errorDescription: String? {
        switch self {
        case .notAKeepFormatJob(let job):
            return "Only Cap, Square and Pad replace a file where it is. \(job) writes a new file under another name, so the old one would still be there and ndisc would still point at it."
        case .originalsIsLibrary:
            return "The originals folder is the library itself. Choose a folder outside it."
        case .originalsInsideLibrary:
            return "The originals folder is inside the library. The next run would walk the kept originals as covers. Choose a folder outside it."
        case .libraryInsideOriginals:
            return "The library is inside the originals folder. Choose a folder beside the library, not above it."
        case .slotTaken(let kept):
            return "An original is already kept for this file (\(kept)); move it out of the originals folder to run this file again."
        case .pathHoldsTabOrNewline(let p):
            return "\(p) holds a tab or a line break, which the log cannot record; left as it is."
        case .noPlace(let p):
            return "\(p) has no place under the scope's own folder, so there is nowhere to keep its original."
        case .copyIncomplete(let copied, let of):
            return "Copied \(copied) of \(of) bytes of the original; nothing was replaced."
        case .logUnwritable(let why, let putBack):
            return "The log could not be written (\(why)), so \(putBack)"
        }
    }
}

/// The originals folder may not be the library, inside it, or above it.
///
/// Inside: the next run would walk the kept originals as covers. Above: the
/// library is then inside the originals folder, and a kept slot can be a
/// library path. This is `guardBatch`'s rule for a different pair of folders,
/// and it is deliberately its own function — the output folder is somewhere a
/// run writes *copies*, and this is where someone's only copy goes.
public func guardOriginals(library: URL, kept: URL) throws {
    let real = { (u: URL) -> URL in
        URL(fileURLWithPath: (u.path as NSString).standardizingPath).resolvingSymlinksInPath()
    }
    let l = real(library), k = real(kept)
    if k.path == l.path { throw WriteBackError.originalsIsLibrary }
    let lp = l.pathComponents, kp = k.pathComponents
    if kp.count > lp.count, Array(kp.prefix(lp.count)) == lp {
        throw WriteBackError.originalsInsideLibrary
    }
    if lp.count > kp.count, Array(lp.prefix(kp.count)) == kp {
        throw WriteBackError.libraryInsideOriginals
    }
}

// MARK: - the file's own numbers

/// A file's size and modified time, exactly as the filesystem holds them.
///
/// `lstat`, not `Date`: the undo compares what a run wrote against what is
/// there now, and `Date` carries nanoseconds since 1970 in a `Double`, which
/// has no room for them — two writes a few hundred nanoseconds apart would
/// compare equal. A symlink is not followed, so a cover replaced by a link to
/// somewhere else reads as changed, which it is.
func fileStamp(_ url: URL) -> (bytes: Int64, mtimeNS: Int64)? {
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
    return (Int64(st.st_size),
            Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec))
}

/// Does anything at all exist at this path, symlink included?
private func somethingExists(at url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0
}

private func stamp(_ now: Date, _ format: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f.string(from: now)
}

private func tmpBeside(_ url: URL) -> URL {
    url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).ncover-tmp")
}

/// Copy `from` to `to` without ever leaving a partial file at `to`: a temp
/// name beside it, synced, its length checked, then renamed into place.
///
/// `copyItem` carries the modified time over, which the undo then compares
/// against — so the original comes back with its own date, not with today's.
func copyWhole(from: URL, to: URL) throws {
    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let tmp = tmpBeside(to)
    try? FileManager.default.removeItem(at: tmp)
    do {
        try FileManager.default.copyItem(at: from, to: tmp)
        let want = fileStamp(from)?.bytes ?? -1
        let got = fileStamp(tmp)?.bytes ?? -2
        guard want == got else {
            throw WriteBackError.copyIncomplete(copied: Int(got), of: Int(want))
        }
        if let h = try? FileHandle(forUpdating: tmp) {
            try? h.synchronize()
            try? h.close()
        }
        try FileManager.default.moveItem(at: tmp, to: to)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}

/// Put a kept original back over a library file: copied beside it and renamed
/// over it, so the library file is whole at every moment.
private func restore(kept: URL, over lib: URL) throws {
    let tmp = tmpBeside(lib)
    try copyWhole(from: kept, to: tmp)
    do {
        _ = try FileManager.default.replaceItemAt(lib, withItemAt: tmp)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}

/// Remove a folder and its parents while they are **empty**, stopping at
/// `root`.
///
/// `rmdir`, not `removeItem`: `removeItem` deletes a folder and everything in
/// it, and this walks upward through someone's originals folder. A folder that
/// still holds anything — another run's original, a `.DS_Store` — stops it,
/// which is the behaviour wanted and not a limitation.
private func pruneEmpty(_ dir: URL, upTo root: URL) {
    var d = dir.standardizedFileURL
    let stop = root.standardizedFileURL.path
    while d.path != stop, d.path.hasPrefix(stop + "/"), rmdir(d.path) == 0 {
        d = d.deletingLastPathComponent()
    }
}

// MARK: - one run

/// One run into the library: where the originals go, and what the log calls
/// this run.
public struct WriteBack: Sendable {
    public let keptRoot: URL
    /// This run's id in the log, its local start time made unique against it.
    public let run: String
    /// The same moment, for people to read.
    public let time: String

    /// Make the originals folder if needed and name the run.
    public static func start(keptRoot: URL, now: Date = Date()) throws -> WriteBack {
        try FileManager.default.createDirectory(at: keptRoot, withIntermediateDirectories: true)
        let base = stamp(now, "yyyyMMdd-HHmmss")
        let taken = Set(try readLog(in: keptRoot).map(\.run))
        var run = base
        var n = 2
        while taken.contains(run) { run = "\(base)-\(n)"; n += 1 }
        return WriteBack(keptRoot: keptRoot, run: run, time: stamp(now, "yyyy-MM-dd HH:mm:ss"))
    }

    /// Where this source's original would be kept.
    public func slot(for place: String) throws -> URL {
        guard isPlainPlace(place) else { throw WriteBackError.noPlace(place) }
        return keptRoot.appendingPathComponent(place)
    }

    /// Replace `source` with the recipe's result, keeping the original.
    ///
    /// `nil` means the job leaves this file alone — nothing is copied, nothing
    /// is written and nothing is logged, which is what makes a run over a
    /// whole library reviewable. A returned URL is where the original is kept
    /// (or, under `dry`, where it would be).
    @discardableResult
    public func one(source: URL, place: String, recipe r: Recipe,
                    dry: Bool = false) throws -> URL? {
        guard r.job.keepsFile else { throw WriteBackError.notAKeepFormatJob(r.job.name) }
        let kept = try slot(for: place)
        // The log is TSV. A path that would break a line of it is refused
        // before anything is touched, rather than written and unrecordable.
        for p in [source.path, kept.path] where p.contains("\t") || p.contains("\n") {
            throw WriteBackError.pathHoldsTabOrNewline(p)
        }
        guard wouldChange(source, job: r.job, canvas: r.canvas) else { return nil }
        guard !somethingExists(at: kept) else { throw WriteBackError.slotTaken(kept.path) }
        // Settled before the render, so a format this app cannot write is
        // reported as left alone rather than decoded and then refused.
        let format = try batchWriteFormat(dest: source, job: r.job)
        guard let made = try batchRender(try Raster.load(contentsOf: source), recipe: r) else {
            return nil
        }
        // A keep-format job carries a JPEG's own RGB through, so there should
        // be no alpha at all; if there is, this is the guard that refuses to
        // store it as black.
        try guardOverwrite(source: source, resultIsOpaque: made.isOpaque)
        if dry { return kept }

        let before = imageSize(of: source)
        try copyWhole(from: source, to: kept)
        let forgetKept = {
            try? FileManager.default.removeItem(at: kept)
            pruneEmpty(kept.deletingLastPathComponent(), upTo: keptRoot)
        }
        do {
            try made.replaceFile(at: source, as: format, alpha: .discard)
        } catch {
            // The rename never happened, so the library still holds the
            // original: the copy is not needed, and must not hold the slot
            // against a later run.
            forgetKept()
            throw error
        }
        // A swap the log does not know about cannot be put back, so from
        // here on a failure means undoing the swap rather than leaving it.
        let undoTheSwap = { (why: String) -> WriteBackError in
            do {
                try restore(kept: kept, over: source)
            } catch {
                return .logUnwritable(
                    why: why,
                    putBack: "putting the original back failed too (\(error.localizedDescription)); it is at \(kept.path)")
            }
            forgetKept()
            return .logUnwritable(why: why, putBack: "the original was put back.")
        }
        // Its own numbers, read back from the file this run has just written:
        // they are what the undo compares against, so a guess will not do.
        guard let now = fileStamp(source) else {
            throw undoTheSwap("the file it had just written could not be read")
        }
        let line = [
            "swap", run, time, r.job.name.lowercased(), source.path, kept.path,
            before.map { "\($0.width)x\($0.height)" } ?? "-",
            "\(made.width)x\(made.height)",
            "\(now.bytes)", "\(now.mtimeNS)",
        ].joined(separator: "\t") + "\n"
        do {
            try appendLog(line, in: keptRoot)
        } catch {
            throw undoTheSwap(error.localizedDescription)
        }
        return kept
    }
}

// MARK: - the log

func appendLog(_ line: String, in keptRoot: URL) throws {
    let path = keptRoot.appendingPathComponent(WRITEBACK_LOG)
    let fresh = !FileManager.default.fileExists(atPath: path.path)
    if fresh {
        try Data(LOG_HEAD.utf8).write(to: path, options: .atomic)
    }
    let h = try FileHandle(forWritingTo: path)
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data(line.utf8))
    try h.synchronize()
}

/// One `swap` or `undo` line of the log.
public struct WriteBackLogRow: Equatable, Sendable {
    public var undo: Bool
    public var run: String
    public var time: String
    public var lib: URL?
    public var kept: URL?
    public var bytes: Int64
    public var mtimeNS: Int64
}

/// Every line of the log that is one. The header, and anything a person has
/// added, is ignored rather than refused — it is a plain text file in a folder
/// of theirs.
public func readLog(in keptRoot: URL) throws -> [WriteBackLogRow] {
    let path = keptRoot.appendingPathComponent(WRITEBACK_LOG)
    guard let text = try? String(contentsOf: path, encoding: .utf8) else {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        throw CocoaError(.fileReadCorruptFile)
    }
    var rows: [WriteBackLogRow] = []
    for line in text.components(separatedBy: .newlines) {
        let f = line.components(separatedBy: "\t")
        if f.count == 10, f[0] == "swap" {
            rows.append(WriteBackLogRow(
                undo: false, run: f[1], time: f[2],
                lib: URL(fileURLWithPath: f[4]), kept: URL(fileURLWithPath: f[5]),
                // An unreadable number must not read as "unchanged": a size
                // nothing can match and a time nothing can match.
                bytes: Int64(f[8]) ?? .max, mtimeNS: Int64(f[9]) ?? -1))
        } else if f.count >= 3, f[0] == "undo" {
            rows.append(WriteBackLogRow(undo: true, run: f[1], time: f[2],
                                        lib: nil, kept: nil, bytes: 0, mtimeNS: 0))
        }
    }
    return rows
}

/// The most recent run not yet put back: its id, start time, and how many
/// files it replaced.
public func lastRun(in keptRoot: URL) throws -> (run: String, time: String, swaps: Int)? {
    let rows = try readLog(in: keptRoot)
    let undone = Set(rows.filter(\.undo).map(\.run))
    guard let last = rows.last(where: { !$0.undo && !undone.contains($0.run) }) else {
        return nil
    }
    return (last.run, last.time, rows.filter { !$0.undo && $0.run == last.run }.count)
}

/// What putting a run back did.
public struct UndoReport: Equatable, Sendable {
    public struct Skip: Equatable, Sendable {
        public var file: URL
        public var why: String
    }
    public var run: String
    public var restored: Int
    /// Library files left as they are, each with why. Their originals stay in
    /// the originals folder, so nothing is lost by a skip.
    public var skipped: [Skip]
}

/// Put the last run back, newest swap first.
///
/// A library file that has changed since the run — its size or modified time
/// is not what the run wrote — is **left alone and named**: putting the
/// original back over it would throw that change away, and a cover someone
/// has since replaced by hand is exactly the file this is most likely to meet.
/// The run is marked undone in the log either way, because what is left is
/// each named file, not a run to try again.
public func undoLastRun(in keptRoot: URL, now: Date = Date()) throws -> UndoReport? {
    guard let (run, _, _) = try lastRun(in: keptRoot) else { return nil }
    let swaps = try readLog(in: keptRoot).filter { !$0.undo && $0.run == run }
    var report = UndoReport(run: run, restored: 0, skipped: [])
    for row in swaps.reversed() {
        guard let lib = row.lib, let kept = row.kept else { continue }
        guard let now = fileStamp(lib) else {
            report.skipped.append(.init(file: lib, why: "cannot be read"))
            continue
        }
        guard now.bytes == row.bytes, now.mtimeNS == row.mtimeNS else {
            report.skipped.append(.init(file: lib, why: "changed since the run; left as it is"))
            continue
        }
        guard fileStamp(kept) != nil else {
            report.skipped.append(.init(file: lib, why: "its original is no longer at \(kept.path)"))
            continue
        }
        do {
            try restore(kept: kept, over: lib)
            try? FileManager.default.removeItem(at: kept)
            pruneEmpty(kept.deletingLastPathComponent(), upTo: keptRoot)
            report.restored += 1
        } catch {
            report.skipped.append(.init(file: lib, why: error.localizedDescription))
        }
    }
    try appendLog(["undo", run, stamp(now, "yyyy-MM-dd HH:mm:ss"),
                   "\(report.restored)", "\(report.skipped.count)"].joined(separator: "\t") + "\n",
                  in: keptRoot)
    return report
}
