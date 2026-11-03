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

    public init(roots: [URL], strip: URL, guardRoot: URL) {
        self.roots = roots; self.strip = strip; self.guardRoot = guardRoot
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
        return BatchScope(roots: dirs, strip: root, guardRoot: root)
    }
}

public enum BatchError: LocalizedError, Equatable {
    case manifestMissing
    case manifestEmpty
    case manifestNoRoot
    case notAnImage(String)
    case emptyImage

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
    for root in scope.roots { findImages(root: root, needle: needle, into: &hits) }
    var seen = Set<String>()
    return hits.filter { seen.insert($0.standardizedFileURL.path).inserted }
        .sorted { $0.path < $1.path }
}

/// The path of a hit relative to the scope's prefix — the shape the output
/// mirrors. A hit somewhere outside the prefix falls back to its own filename
/// rather than producing a path full of `..`.
public func relativePath(of hit: URL, under strip: URL) -> String {
    let h = hit.standardizedFileURL.pathComponents
    let s = strip.standardizedFileURL.pathComponents
    guard h.count > s.count, Array(h.prefix(s.count)) == s else {
        return hit.lastPathComponent
    }
    return h.dropFirst(s.count).joined(separator: "/")
}

// MARK: - one file

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

/// Render one already-decoded source through the recipe.
///
/// The one place batch output is produced, so what a preview shows and what a
/// run writes are identical by construction rather than by two code paths
/// agreeing. Pure, and therefore runnable off the main actor.
public func batchRender(_ src: Raster, recipe r: Recipe) throws -> Raster {
    guard src.width > 0, src.height > 0 else { throw BatchError.emptyImage }
    return render(src, recipe: r)
}
