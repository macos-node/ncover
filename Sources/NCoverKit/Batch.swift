import Foundation

// Running one recipe over many files.
//
// The part that matters is not the loop. It is that the loop writes somewhere
// the originals are not — see WriteGuard.swift, which is inherited verbatim
// and non-negotiable. Everything here is arranged so that a wrong output
// folder is refused rather than survived.
//
// Nothing in this file renders an SVG: that needs WebKit, which is
// asynchronous and main-actor bound, so the runner above it serialises
// through the rasteriser and hands the pixels back here.

/// Where a batch run gets its images, and what to strip to mirror the tree.
///
/// Both scopes are the same two things: a set of roots to walk, and the prefix
/// that turns an absolute hit into the relative path the output mirrors. For a
/// folder they are the same path; for the manifest the roots are the release
/// directories and the prefix is the library root — so `artist/release/cover.png`
/// comes out the same shape either way.
public struct BatchScope: Equatable, Sendable {
    /// Every directory to search. One for a folder; N release dirs for published.
    public var roots: [URL]
    /// Stripped off each hit to form the mirrored relative path.
    public var strip: URL
    /// The source boundary the guard protects. The originals live under here.
    public var guardRoot: URL
    /// What to call each root, by its path — "Artist — Title" for a release.
    ///
    /// The manifest knows this and it would be a waste to throw it away: a
    /// list of folder paths is a much worse answer to "what will this touch"
    /// than a list of records.
    public var names: [String: String]

    /// Roots that contribute **only the files a list named** rather than
    /// everything under them, by root path, in the list's own order.
    ///
    /// A line of ndisc's Export list names the exact cover its flags are
    /// about, and a release folder usually holds back and inlay art too. This
    /// has to live in the scope rather than be a filter applied afterwards,
    /// or the survey and the run could select different files — the number on
    /// the Run button is only true because they cannot.
    ///
    /// **Several lines may name files in one folder.** ndisc's label export is
    /// one line per label, every one of them pointing into the same folder of
    /// logos, so a root holds a *list* of named files. Keyed by folder to one
    /// URL it kept whichever line came last and dropped the rest in silence.
    public var only: [String: [URL]]

    /// What to call one named file, by its path: the name on the line that
    /// named it ("Ultra Records").
    ///
    /// Wins over `names`, which a folder shared by several lines cannot carry
    /// — seventy-six logos all captioned by their folder is no caption.
    public var fileNames: [String: String]

    public init(roots: [URL], strip: URL, guardRoot: URL, names: [String: String] = [:],
                only: [String: [URL]] = [:], fileNames: [String: String] = [:]) {
        self.roots = roots; self.strip = strip; self.guardRoot = guardRoot
        self.names = names; self.only = only; self.fileNames = fileNames
    }

    /// Every image one root contributes: the files the list named, or a walk.
    ///
    /// The single place a root is turned into files. `findImages(in:)` (the
    /// run, the samples) and `surveyBatch` (the counts) both come through
    /// here, so there is nothing that could drift.
    public func images(under root: URL, needle: String) -> [URL] {
        // A root with no place under the prefix contributes nothing, here —
        // the one place a root becomes files — so the survey, the plan and
        // the run cannot disagree about it. `rootsWithNoPlace` is what says
        // so on screen.
        guard isPlaceable(root: root, strip: strip) else { return [] }
        guard let named = only[root.standardizedFileURL.path] else {
            var out: [URL] = []
            findImages(root: root, needle: needle, into: &out)
            return out
        }
        // **A named file ignores the name filter.** The list has already
        // chosen this exact file, and a label's image is not called `cover.*`
        // — with the filter applied on top of it, the default "cover" takes
        // every line of a label export straight out of the run.
        return named.filter {
            IMAGE_EXTS.contains($0.pathExtension.lowercased())
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Roots that lie outside the prefix, so nothing under them has a place.
    public var rootsWithNoPlace: [URL] {
        roots.filter { !isPlaceable(root: $0, strip: strip) }
    }

    /// Named files a root was asked for that are not there, for the survey.
    ///
    /// The list was exported before someone moved a file. One missing logo in
    /// a folder of seventy-six is not a root that matched nothing, and must
    /// not be reported as one — nor vanish, which is what a list that quietly
    /// shrinks does.
    public func missingNamed(under root: URL) -> Int {
        guard let named = only[root.standardizedFileURL.path] else { return 0 }
        return named.filter { !FileManager.default.fileExists(atPath: $0.path) }.count
    }

    /// A list of release folders — ndisc's Export list, or a hand-made one.
    ///
    /// The job is a parameter because **the job picks the lines**: a Cap run
    /// and a Square run over one export are different scopes. Which is why
    /// the job has to be part of whatever key re-surveys the scope.
    public static func list(_ l: CoverList, job: BatchJob) throws -> BatchScope {
        let chosen = l.lines.filter { l.selects($0, job: job) }
        guard !chosen.isEmpty else { throw BatchError.listEmpty }
        guard let root = l.root else { throw BatchError.listNoRoot }
        var roots: [URL] = []
        var names: [String: String] = [:]
        var fileNames: [String: String] = [:]
        var only: [String: [URL]] = [:]
        var linesIn: [String: Int] = [:]
        var walkWhole = Set<String>()
        for line in chosen {
            let key = line.folder.standardizedFileURL.path
            // A folder is one root however many lines name it; a duplicate
            // root would be surveyed twice and report the second pass as a
            // release that matched nothing.
            if linesIn[key, default: 0] == 0 { roots.append(line.folder) }
            linesIn[key, default: 0] += 1
            if let c = line.cover {
                var named = only[key] ?? []
                if !named.contains(c) { named.append(c) }
                only[key] = named
                if let n = line.name { fileNames[c.standardizedFileURL.path] = n }
            } else {
                // A line with no cover file asks for the whole folder, which
                // takes in anything another line named there.
                walkWhole.insert(key)
            }
            if let n = line.name { names[key] = n }
        }
        for key in walkWhole { only[key] = nil }
        // A folder several lines share is called by its own path, not by
        // whichever of them came last.
        for (key, n) in linesIn where n > 1 { names[key] = nil }
        return BatchScope(roots: roots, strip: root, guardRoot: root,
                          names: names, only: only, fileNames: fileNames)
    }

    public static func folder(_ root: URL) -> BatchScope {
        BatchScope(roots: [root], strip: root, guardRoot: root)
    }

    /// The published releases become the walk roots; the library root is both
    /// the mirror prefix and the boundary the guard protects — the originals
    /// *are* the library, and every release directory lives under it.
    public static func published(_ m: Manifest) throws -> BatchScope {
        let dirs = m.releases.map { URL(fileURLWithPath: $0.dir) }
        guard !dirs.isEmpty else { throw BatchError.manifestEmpty }
        let root = m.libraryRoot.map { URL(fileURLWithPath: $0) }
            ?? commonAncestor(of: dirs)
        guard let root else { throw BatchError.manifestNoRoot }
        var names: [String: String] = [:]
        for r in m.releases {
            let parts = [r.artist, r.title].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty {
                names[URL(fileURLWithPath: r.dir).standardizedFileURL.path]
                    = parts.joined(separator: " — ")
            }
        }
        return BatchScope(roots: dirs, strip: root, guardRoot: root, names: names)
    }
}

public enum BatchError: LocalizedError, Equatable {
    case manifestMissing
    case manifestEmpty
    case manifestNoRoot
    case notAnImage(String)
    case emptyImage
    /// Two sources in one run plan the same output file.
    case destinationTaken(first: String, dest: String)
    /// A keep-format job met a format this app does not write.
    case keepFormatUnsupported(String)
    case listUnreadable(String)
    case listEmpty
    case listNoRoot
    /// A source has no place under the scope's prefix, so there is nowhere to
    /// mirror it to. Refused rather than written under a name of its own.
    case noPlace(String)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "ndisc has not exported a manifest, so there is no published discography to batch over."
        case .manifestEmpty:
            return "The manifest lists no releases."
        case .manifestNoRoot:
            return "The manifest names no library root, and its releases have no folder in common — there is nothing to mirror the output against."
        case .notAnImage(let p):
            return "Could not read \(p) as an image"
        case .emptyImage:
            return "Empty image"
        case .destinationTaken(let first, let dest):
            return "would overwrite the output of \(first) (\(dest)); not written"
        case .keepFormatUnsupported(let ext):
            return "Cap, Square and Pad keep each file's own format and cannot write .\(ext); left as it is"
        case .listUnreadable(let name):
            return "Could not read \(name) as text. A cover list is one release folder per line."
        case .listEmpty:
            return "No line in that list is for this job. Check the job against the list's actions column — Cap takes the `ncover:cap` lines and Square the `ncover:square` ones."
        case .listNoRoot:
            return "The folders in that list have no parent in common, so there is nothing for the output to mirror."
        case .noPlace(let what):
            return "\(what) is not under the scope's own folder, so it has no place in the output; refused rather than written under a name of its own"
        }
    }
}

/// The deepest directory every one of these paths is inside.
func commonAncestor(of urls: [URL]) -> URL? {
    guard var shared = urls.first?.pathComponents else { return nil }
    for u in urls.dropFirst() {
        let parts = u.pathComponents
        var i = 0
        while i < shared.count, i < parts.count, shared[i] == parts[i] { i += 1 }
        shared = Array(shared.prefix(i))
    }
    guard shared.count > 1 else { return nil }   // only "/" in common is not an answer
    return URL(fileURLWithPath: NSString.path(withComponents: shared))
}

// MARK: - ndisc's manifest

/// ndisc's export: the releases it has published, each with its folder.
///
/// Only the fields batch needs; the rest of the shape is ndisc's business and
/// is ignored. `libraryRoot` is optional in the v2 shape, so it is optional
/// here too rather than being assumed.
public struct Manifest: Decodable, Sendable {
    public var libraryRoot: String?
    public var releases: [Release]

    public struct Release: Decodable, Sendable {
        public var dir: String
        public var artist: String?
        public var title: String?
    }
}

/// Where ndisc writes it.
///
/// `~/.local/share/ndisc-suite/` on macOS as well as Linux — not Application
/// Support. That is ndisc's decision, made so that every app in the suite
/// resolves the path the same way, and this app has to follow it rather than
/// be idiomatic on its own. `nil` when it has never exported one, in which
/// case the published scope is not offered: a scope that matches nothing is
/// worse than no scope.
public func publishedManifestPath() -> URL? {
    let p = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/ndisc-suite/published.json")
    return FileManager.default.fileExists(atPath: p.path) ? p : nil
}

public func loadManifest(at url: URL) throws -> Manifest {
    try JSONDecoder().decode(Manifest.self, from: try Data(contentsOf: url))
}

// MARK: - discovery

/// Walk `root` for images whose filename contains `needle`, case-insensitively;
/// an empty needle matches everything.
///
/// Hidden directories are skipped — nothing in a `.git` is artwork. The order
/// is by name, because a dry run and the real run have to agree and "the order
/// the filesystem felt like" is not an order.
public func findImages(root: URL, needle: String, into out: inout [URL]) {
    let want = needle.lowercased()
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []
    )) ?? []
    for path in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = path.lastPathComponent
        if name.hasPrefix(".") { continue }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir)
        if isDir.boolValue {
            // A folder we cannot read is not fatal to the whole run.
            findImages(root: path, needle: needle, into: &out)
            continue
        }
        guard IMAGE_EXTS.contains(path.pathExtension.lowercased()) else { continue }
        if want.isEmpty || name.lowercased().contains(want) { out.append(path) }
    }
}

/// Every image the scope covers, in a stable order and with no duplicates
/// (two manifest releases can nest, and a file found twice would be written
/// twice).
public func findImages(in scope: BatchScope, needle: String) -> [URL] {
    var hits: [URL] = []
    for root in scope.roots { hits += scope.images(under: root, needle: needle) }
    var seen = Set<String>()
    return hits.filter { seen.insert($0.standardizedFileURL.path).inserted }
        .sorted { $0.path < $1.path }
}

/// The path of a hit relative to the scope's prefix, **for display**.
///
/// A hit outside the prefix falls back to its own filename rather than a path
/// full of `..`, which is the right answer for a label in a list and the
/// wrong one for a write: see `placeUnder`, and never use this to decide
/// where a file goes.
public func relativePath(of hit: URL, under strip: URL) -> String {
    placeUnder(hit, strip: strip) ?? hit.lastPathComponent
}

/// A file's **place** under the scope's prefix, or `nil` if it has none.
///
/// The shape of the library is the only thing that tells 1,600 files named
/// `cover.png` apart, so a place is the whole path under the prefix and
/// nothing less. A file that is not under the prefix has no place and is
/// refused rather than given one: a fallback to its own filename sends every
/// such file to one name in the output root, and once the write-back lands
/// (phase F1) the place is also where the original is kept.
///
/// Only plain components count. An empty place (the file *is* the prefix) and
/// anything holding `.` or `..` are refused rather than cleaned up, because
/// cleaning up is how a kept original escapes the folder it was promised to.
public func placeUnder(_ hit: URL, strip: URL) -> String? {
    let h = hit.standardizedFileURL.pathComponents
    let s = strip.standardizedFileURL.pathComponents
    guard h.count > s.count, Array(h.prefix(s.count)) == s else { return nil }
    let rel = Array(h.dropFirst(s.count))
    guard !rel.isEmpty, rel.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
        return nil
    }
    return rel.joined(separator: "/")
}

/// Is this a place a file may be written at, relative to some root?
///
/// One rule, asked by everything that turns a place into a path: the batch
/// planner and the write-back's originals folder. Empty, absolute, or holding
/// `.` or `..` is refused — `batchDest` and `keepDest` build their path by
/// *skipping* those components, which flattens a bad place into a plausible
/// one, and an originals slot computed from one could escape the folder it
/// was promised to.
public func isPlainPlace(_ place: String) -> Bool {
    guard !place.isEmpty, !place.hasPrefix("/") else { return false }
    return !place.split(separator: "/", omittingEmptySubsequences: false)
        .contains { $0 == "." || $0 == ".." || $0.isEmpty }
}

/// Is this root somewhere the scope can place what it finds?
///
/// A root is placeable when it *is* the prefix (a folder scope, where the two
/// are the same path) or lies under it. ndisc's manifest can name a release
/// outside `libraryRoot` — a library half-moved, a release on another volume —
/// and every file under such a root would mirror to a bare filename, so they
/// would land on each other in the output root.
public func isPlaceable(root: URL, strip: URL) -> Bool {
    let r = root.standardizedFileURL.path, s = strip.standardizedFileURL.path
    return r == s || placeUnder(root, strip: strip) != nil
}

// MARK: - one file

// MARK: - what a run would touch

/// What a scope and a filter actually select, before anything is rendered.
///
/// Walking directories is cheap — no image is decoded — so this can be shown
/// and kept current while someone types a filter. That is the point of it: a
/// filter you cannot see the effect of is a guess, and "run it and find out"
/// is a poor way to learn that `cover` matches twenty files and nothing
/// matches `front`.
public struct BatchSurvey: Equatable, Sendable {
    public struct Group: Equatable, Sendable, Identifiable {
        /// The walk root this came from.
        public var root: String
        /// What to call it: the release's artist and title where the manifest
        /// said, else the folder's own path within the scope.
        public var name: String
        /// Matching files, as paths relative to the scope's prefix.
        public var files: [String]

        public var id: String { root }
    }

    public var groups: [Group]
    /// Every matching file, across all groups.
    public var total: Int
    /// Roots that matched nothing. Counted rather than listed — "9 releases
    /// have no cover" is the useful form of that, and naming all nine is not.
    public var emptyRoots: Int
    /// Files a list named that are not on disk. Its own count, because a list
    /// exported before someone moved a cover is a normal thing to meet, and
    /// neither silence nor "matched nothing" says what happened.
    public var missingNamed: Int
    /// Roots outside the scope's prefix: nothing under them has a place, so
    /// nothing under them is in the run. Said rather than quietly dropped.
    public var rootsWithNoPlace: Int

    public init(groups: [Group], total: Int, emptyRoots: Int, missingNamed: Int = 0,
                rootsWithNoPlace: Int = 0) {
        self.groups = groups; self.total = total; self.emptyRoots = emptyRoots
        self.missingNamed = missingNamed; self.rootsWithNoPlace = rootsWithNoPlace
    }
}

/// Survey a scope without rendering anything.
public func surveyBatch(_ scope: BatchScope, needle: String) -> BatchSurvey {
    var groups: [BatchSurvey.Group] = []
    var seen = Set<String>()
    var empty = 0
    var missing = 0
    var noPlace = 0
    var total = 0

    for root in scope.roots {
        // Counted and skipped before anything else: it is not a root that
        // matched nothing, it is a root this scope cannot write the results
        // of anywhere.
        guard isPlaceable(root: root, strip: scope.strip) else { noPlace += 1; continue }
        let hits = scope.images(under: root, needle: needle)
        let gone = scope.missingNamed(under: root)
        missing += gone
        // A file reachable from two roots (nested releases) belongs to the
        // first that found it, so the totals here match what a run writes.
        let fresh = hits.filter { seen.insert($0.standardizedFileURL.path).inserted }
        // A root that brought nothing because the file it named is not there
        // is counted as that, not as a root that matched nothing.
        guard !fresh.isEmpty else { if gone == 0 { empty += 1 }; continue }
        let key = root.standardizedFileURL.path
        groups.append(BatchSurvey.Group(
            root: key,
            name: scope.names[key] ?? relativePath(of: root, under: scope.strip),
            files: fresh.map { relativePath(of: $0, under: scope.strip) }.sorted()))
        total += fresh.count
    }
    groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return BatchSurvey(groups: groups, total: total, emptyRoots: empty, missingNamed: missing,
                       rootsWithNoPlace: noPlace)
}

/// Where one source lands when the job keeps its **name**: the same stem,
/// mirrored under the output root, with `ext` for its extension or the
/// source's own when that is `nil`.
///
/// Cap, Square and Pad tidy a file; a tidied `cover.jpg` is still `cover.jpg`,
/// which also means two sources in one folder cannot plan the same output the
/// way the PNG family can — they differ by the very extension they keep.
/// Convert is the exception and the reason this takes an extension at all:
/// `cover.png` becomes `cover.jpg`, so a folder holding both **can** plan one
/// output twice. Nothing disambiguates that — the clash check refuses it — and
/// the run keeps it from arising by never planning a file it would not write.
public func keepDest(rel: String, outRoot: URL, ext: String? = nil) -> URL {
    var parts = rel.split(separator: "/").map(String.init)
    let file = parts.popLast() ?? "image"
    var p = outRoot
    for part in parts where part != "." && part != ".." { p.appendPathComponent(part) }
    guard let ext else { return p.appendingPathComponent(file) }
    return p.appendingPathComponent((file as NSString).deletingPathExtension + "." + ext)
}

/// What format a run writes this destination as, or a refusal naming the
/// extension. WebP and GIF are refused rather than quietly turned into a PNG
/// under a name that says otherwise — the GTK sibling's `cap_format` rule.
public func batchWriteFormat(dest: URL, job: BatchJob) throws -> ImageFormat {
    // A job that names its own format answers for itself; only the ones that
    // keep the source's have to read the name they are about to write.
    if let f = job.writes { return f }
    guard let f = ImageFormat.of(dest) else {
        let ext = dest.pathExtension.lowercased()
        throw BatchError.keepFormatUnsupported(ext.isEmpty ? "(none)" : ext)
    }
    return f
}

/// Where one source lands.
///
/// The shape of the library is the only thing that tells 1,600 files named
/// `cover.png` apart. Flatten it and they all land on each other. Always PNG —
/// alpha has nowhere to live in a JPEG.
public func batchDest(rel: String, outRoot: URL, disc: Bool) -> URL {
    // Plain string components, not a URL: `URL(fileURLWithPath:)` resolves a
    // RELATIVE path against the current directory, so building one out of
    // `rel` silently drags the process's cwd into the output path.
    var parts = rel.split(separator: "/").map(String.init)
    let file = parts.popLast() ?? "image"
    let stem = (file as NSString).deletingPathExtension
    var p = outRoot
    for part in parts where part != "." && part != ".." { p.appendPathComponent(part) }
    return p.appendingPathComponent(stem + (disc ? "-disc" : "") + ".png")
}

/// Where every source in a run lands, planned as a whole.
///
/// `batchDest` answers for one file, and one file at a time is not enough. It
/// always writes `<stem>.png`, so a release holding both `cover.jpg` and
/// `cover.png` sends the two of them to one `cover.png`: the second replaces
/// the first, both are reported as written, and a dry run cannot show it
/// because each file renders perfectly well on its own. The originals are
/// never at risk — `guardBatch` keeps the run out of the source tree — but
/// the output is quietly half of what the run claims.
///
/// So the names are planned for the whole run before anything is written.
/// Sources that would share a name keep their extension in it
/// (`cover-jpg.png`, `cover-png.png`); everything else keeps the plain name it
/// always had, so a library with no collisions comes out exactly as before. A
/// clash that survives that — the same `rel` twice, or a source literally
/// named `cover-jpg.jpg` beside the pair — is **refused**, naming the file
/// that holds the name, rather than overwriting it without a word.
///
/// The order matches `rels`, so a caller can zip it back onto its hits.
public func planDests(rels: [String], outRoot: URL, job: BatchJob,
                      disc: Bool) -> [Result<URL, BatchError>] {
    // Belt and braces for the place itself, by the one rule `isPlainPlace`
    // holds. Whoever computed these should have used `placeUnder`; if they
    // did, this cannot fire.
    let bad = { !isPlainPlace($0) }
    // A keep-format job's names are unique by construction — each output IS
    // its source's name — so the disambiguation below has nothing to do. The
    // clash check still runs: it costs one dictionary and it is the thing that
    // would notice if that reasoning ever stopped being true.
    let plain = job.keepsName
        ? rels.map { keepDest(rel: $0, outRoot: outRoot, ext: job.writes.map { $0 == .jpeg ? "jpg" : "png" }) }
        : rels.map { batchDest(rel: $0, outRoot: outRoot, disc: disc) }
    var uses: [String: Int] = [:]
    for (rel, p) in zip(rels, plain) where !bad(rel) { uses[p.path, default: 0] += 1 }

    /// Which `rel` has claimed each output path.
    var taken: [String: String] = [:]
    var out: [Result<URL, BatchError>] = []
    out.reserveCapacity(rels.count)

    for (rel, p) in zip(rels, plain) {
        guard !bad(rel) else { out.append(.failure(.noPlace(rel))); continue }
        var dest = p
        if !job.keepsName, uses[p.path, default: 0] > 1 {
            let file = rel.split(separator: "/").last.map(String.init) ?? rel
            let stem = (file as NSString).deletingPathExtension
            let ext = (file as NSString).pathExtension.lowercased()
            // No extension to tell them apart with: leave the plain name and
            // let the clash below refuse it. Inventing a number here would
            // make the output depend on the walk order.
            if !ext.isEmpty {
                dest = p.deletingLastPathComponent()
                    .appendingPathComponent(stem + "-" + ext + (disc ? "-disc" : "") + ".png")
            }
        }
        if let first = taken[dest.path] {
            out.append(.failure(.destinationTaken(first: first, dest: dest.path)))
        } else {
            taken[dest.path] = rel
            out.append(.success(dest))
        }
    }
    return out
}

/// Render one already-decoded source through the recipe.
///
/// The one place batch output is produced, so what a preview shows and what a
/// run writes are identical by construction rather than by two code paths
/// agreeing. Pure, and therefore runnable off the main actor.
///
/// `nil` means **left alone**: only the keep-format jobs do that, for a file
/// already within the cap or already square. A run must not write a file it
/// would not change — that is what makes a library-wide run reviewable — and
/// a caller that treats `nil` as a failure is reporting a lie.
public func batchRender(_ src: Raster, recipe r: Recipe) throws -> Raster? {
    guard src.width > 0, src.height > 0 else { throw BatchError.emptyImage }
    if case .frame = r.job { return render(src, recipe: r) }
    return jobRender(src, job: r.job, canvas: r.canvas)
}
