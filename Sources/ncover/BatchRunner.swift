import AppKit
import NCoverKit
import SwiftUI

/// Running a recipe over many files, with a preview first.
///
/// `@MainActor` throughout, and that is not laziness: an SVG source goes
/// through `WKWebView`, which is asynchronous and main-actor bound, so a batch
/// has to **serialise** through the rasteriser rather than fan out. Pixel work
/// is pure and could run anywhere, but splitting the loop in two to move it
/// off would buy throughput on a job that is already bounded by decoding files.
///
/// What the loop actually guarantees is the part worth reading: every write
/// goes to a folder `guardBatch` has approved, the destination mirrors the
/// source tree, and a dry run renders everything and writes nothing — so it
/// still fails on a file that would really fail.
@MainActor
final class BatchRunner: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case folder, published
        var id: String { rawValue }
        var label: String {
            self == .folder ? "A folder" : "ndisc's published releases"
        }
    }

    struct Row: Identifiable {
        let id = UUID()
        let rel: String
        /// Where it went, or why it did not. A plain enum rather than
        /// `Result<String, String>`, which Swift will not have: the failure
        /// type has to be an `Error`, and a sentence meant for a person is not
        /// one.
        enum Outcome { case wrote(String), failed(String) }
        let outcome: Outcome
    }

    struct Thumb: Identifiable {
        let id = UUID()
        let label: String
        let image: NSImage?
        let error: String?
    }

    // What to run
    @Published var scope: Scope = .folder
    @Published var sourceFolder: URL?
    @Published var outputFolder: URL?
    @Published var needle = ""
    @Published var canvas = CANVAS_DEFAULT
    @Published var framing: Framing = .cover
    @Published var discOn = true
    @Published var fill: AppModel.FillKind = .alpha
    @Published var fillColour: Color = .white
    @Published var dryRun = false

    // What happened
    @Published private(set) var running = false
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    @Published private(set) var ok = 0
    @Published private(set) var failed = 0
    @Published private(set) var rows: [Row] = []
    @Published private(set) var thumbs: [Thumb] = []
    @Published private(set) var stopped = false
    @Published var error: String?

    /// What the current scope and filter select, kept current while you type.
    /// `nil` until the first survey lands; the walk is cheap but not free.
    @Published private(set) var survey: BatchSurvey?
    @Published private(set) var surveying = false

    private var cancelled = false

    /// How many result rows the list shows. Beyond this the run is still
    /// complete and still counted — the LIST is what is capped, and it says so.
    /// A silent truncation reads as "that was everything".
    static let resultRows = 300

    /// How many outputs a preview renders. A contact sheet is a SAMPLE you
    /// eyeball to catch "my recipe is wrong" before it touches 500 files.
    static let previewCount = 12

    var manifestPath: URL? { publishedManifestPath() }

    var recipe: Recipe {
        Recipe(canvas: canvas, framing: framing, disc: discOn ? outerFill : nil)
    }

    private var outerFill: OuterFill {
        switch fill {
        case .alpha:    return .alpha
        case .white:    return .white
        case .solid:    return .solid(fillColour.rgb)
        // A gradient needs two colours and the batch sheet offers one. Rather
        // than a second pair of pickers for a case nobody has asked for, the
        // sheet does not offer it and this never runs.
        case .gradient: return .solid(fillColour.rgb)
        }
    }

    /// Whether Run and Preview can go, and why not when they cannot. One
    /// property so the two buttons and the explanation beneath them cannot
    /// disagree.
    var blocker: String? {
        if running { return "A run is in progress." }
        switch scope {
        case .folder:
            if sourceFolder == nil { return "Choose a source folder." }
        case .published:
            if manifestPath == nil {
                return "ndisc has not exported a manifest, so there is nothing published to batch over."
            }
        }
        guard let out = outputFolder else { return "Choose an output folder." }
        do {
            try guardBatch(source: try currentScope().guardRoot, output: out)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    func currentScope() throws -> BatchScope {
        switch scope {
        case .folder:
            guard let src = sourceFolder else { throw BatchError.manifestEmpty }
            return .folder(src)
        case .published:
            guard let p = manifestPath else { throw BatchError.manifestMissing }
            return try .published(try loadManifest(at: p))
        }
    }

    // MARK: - surveying

    /// Recompute what the run would touch.
    ///
    /// Off the main actor: it is only a directory walk and decodes nothing,
    /// but a library of a few thousand releases is still a few thousand
    /// `contentsOfDirectory` calls and the filter field has to stay typeable.
    func refreshSurvey() async {
        guard let scope = try? currentScope() else { survey = nil; return }
        let needle = self.needle
        surveying = true
        defer { surveying = false }
        let result = await Task.detached(priority: .userInitiated) {
            surveyBatch(scope, needle: needle)
        }.value
        // The filter may have moved on while we walked; the last word wins.
        guard needle == self.needle else { return }
        survey = result
    }

    // MARK: - choosing folders

    func chooseSource() {
        if let u = pickFolder("Choose the folder of artwork") { sourceFolder = u }
    }

    func chooseOutput() {
        if let u = pickFolder("Choose where the results go — never the source folder") {
            outputFolder = u
        }
    }

    private func pickFolder(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - preview

    /// A contact sheet of the first few outputs. The same `batchRender` the run
    /// uses, so what you are looking at is what would be written.
    func preview() async {
        guard blocker == nil else { error = blocker; return }
        reset()
        running = true
        defer { running = false }
        do {
            let s = try currentScope()
            let hits = findImages(in: s, needle: needle)
            total = hits.count
            let r = recipe
            for hit in hits.prefix(Self.previewCount) {
                if cancelled { break }
                let label = relativePath(of: hit, under: s.strip)
                do {
                    let out = try await renderOne(hit, recipe: r)
                    thumbs.append(Thumb(label: label, image: out.nsImage(), error: nil))
                } catch {
                    // A preview must show the failures too, or it lies about
                    // what the run will do.
                    thumbs.append(Thumb(label: label, image: nil,
                                        error: error.localizedDescription))
                }
                done += 1
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - the run

    func run() async {
        guard blocker == nil, let out = outputFolder else { error = blocker; return }
        reset()
        running = true
        defer { running = false; stopped = cancelled }
        do {
            let s = try currentScope()
            // Checked again here, not just in `blocker`: the folders are
            // user-typed paths and could have moved since the sheet opened.
            try guardBatch(source: s.guardRoot, output: out)
            let hits = findImages(in: s, needle: needle)
            total = hits.count
            let r = recipe
            let dry = dryRun

            for hit in hits {
                if cancelled { break }
                let rel = relativePath(of: hit, under: s.strip)
                do {
                    let dest = batchDest(rel: rel, outRoot: out, disc: r.disc != nil)
                    let rendered = try await renderOne(hit, recipe: r)
                    if !dry {
                        try FileManager.default.createDirectory(
                            at: dest.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        try rendered.writePNG(to: dest)
                    }
                    ok += 1
                    record(Row(rel: rel, outcome: .wrote(dest.path)))
                } catch {
                    failed += 1
                    // Carry the REASON. "31 failed" is unactionable and sends
                    // you guessing at the tool from the outside.
                    record(Row(rel: rel, outcome: .failed(error.localizedDescription)))
                }
                done += 1
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancel() { cancelled = true }

    private func reset() {
        cancelled = false; stopped = false
        total = 0; done = 0; ok = 0; failed = 0
        rows = []; thumbs = []; error = nil
    }

    private func record(_ row: Row) {
        guard rows.count < Self.resultRows else { return }
        rows.append(row)
    }

    /// Decode one file and render it. SVG goes through WebKit and is therefore
    /// awaited; everything else is a straight decode.
    private func renderOne(_ url: URL, recipe r: Recipe) async throws -> Raster {
        let src: Raster
        if url.pathExtension.lowercased() == "svg" {
            // Rasterised comfortably above any canvas we offer, so scaling
            // down is the only thing that happens to it.
            src = try await SVGRasterizer.rasterize(url, side: max(1024, r.canvas))
        } else {
            src = try Raster.load(contentsOf: url)
        }
        return try batchRender(src, recipe: r)
    }

    /// What the buttons should say they are about to do.
    var actionCount: Int? { survey?.total }

    var summary: String {
        if running { return "\(done) of \(total)…" }
        if total == 0 { return "" }
        var s = "\(ok) \(dryRun ? "would be written" : "written")"
        if failed > 0 { s += ", \(failed) failed" }
        if stopped { s += " — stopped" }
        if rows.count >= Self.resultRows {
            s += ". Showing the first \(Self.resultRows) of \(done)."
        }
        return s
    }
}
