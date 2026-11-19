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
        case folder, list, published
        var id: String { rawValue }
        var label: String {
            switch self {
            case .folder:    return "A folder"
            case .list:      return "From a list…"
            case .published: return "ndisc's published releases"
            }
        }
    }

    struct Row: Identifiable {
        let id = UUID()
        let rel: String
        /// Where it went, or why it did not. A plain enum rather than
        /// `Result<String, String>`, which Swift will not have: the failure
        /// type has to be an `Error`, and a sentence meant for a person is not
        /// one.
        /// `skipped` is the keep-format jobs' third answer: the file is
        /// already square, or already within the cap, so the run writes
        /// nothing for it. Reporting that as `wrote` or `failed` would both
        /// be lies.
        enum Outcome { case wrote(String), failed(String), skipped(String) }
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
    /// The cover list file, and what parsing it gave. Parsed when it is
    /// chosen rather than on every survey: it is a file someone picked, and
    /// re-reading it per keystroke would be its own surprise.
    @Published private(set) var listPath: URL?
    @Published private(set) var coverList: CoverList?
    @Published var outputFolder: URL?
    @Published var needle = ""
    @Published var canvas = CANVAS_DEFAULT
    @Published var job: BatchJob = .frame(.cover)
    /// What fills Pad's bars. Kept beside the job so switching away and back
    /// does not lose the choice.
    @Published var padFill: PadFill = .edge
    /// Off by default, and the Recipe type next door says why: "the disc is an
    /// option, not the point — resizing a folder of covers is a job on its
    /// own". Defaulting it on contradicted that in the one place it mattered,
    /// and a batch of covers came out as discs because the default said so.
    @Published var discOn = false
    @Published var fill: AppModel.FillKind = .alpha
    @Published var fillColour: Color = .white
    @Published var dryRun = false

    // What happened
    @Published private(set) var running = false
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    @Published private(set) var ok = 0
    @Published private(set) var failed = 0
    /// Files a keep-format job left alone. Counted, not hidden: "wrote 245"
    /// out of 2,377 is only honest next to "left 2,132 alone".
    @Published private(set) var skipped = 0
    @Published private(set) var rows: [Row] = []
    @Published private(set) var thumbs: [Thumb] = []
    @Published private(set) var stopped = false
    @Published var error: String?

    /// What the current scope and filter select, kept current while you type.
    /// `nil` until the first survey lands; the walk is cheap but not free.
    @Published private(set) var survey: BatchSurvey?

    /// How many of those files a keep-format job would actually rewrite.
    /// `nil` for a framing, which reframes every one of them, and before the
    /// first survey. Read from each file's header, which is why counting a
    /// couple of thousand of them is a second rather than a minute.
    @Published private(set) var changeCount: Int?
    @Published private(set) var surveying = false

    private var cancelled = false

    /// How many result rows the list shows. Beyond this the run is still
    /// complete and still counted — the LIST is what is capped, and it says so.
    /// A silent truncation reads as "that was everything".
    static let resultRows = 300

    /// How many outputs the full preview renders. A contact sheet is a SAMPLE
    /// you eyeball to catch "my recipe is wrong" before it touches 500 files.
    static let previewCount = 12

    /// How many render themselves, unasked, as soon as there is a recipe and
    /// something to apply it to.
    ///
    /// Four rather than twelve because this runs on every change to the
    /// recipe — and it runs at all because a preview you have to ask for is a
    /// preview you can forget to ask for. A folder of covers came out as
    /// discs that way, and the Run button cannot say "37 of them, as discs".
    static let autoPreviewCount = 4

    /// The always-on sample. Separate from `thumbs` so pressing Preview for
    /// the full twelve does not fight the automatic four.
    @Published private(set) var samples: [Thumb] = []
    @Published private(set) var sampling = false

    var manifestPath: URL? { publishedManifestPath() }

    var recipe: Recipe {
        var j = job
        if case .pad = j { j = .pad(padFill) }
        return Recipe(canvas: canvas, job: j, disc: discOn ? outerFill : nil)
    }

    /// Why this job and this disc cannot run together. The UI shows it and
    /// `blocker` refuses on it, so the two cannot disagree.
    var jobDiscRefusal: String? { jobRefusal(job: job, disc: discOn) }

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
        if let r = jobDiscRefusal { return r }
        switch scope {
        case .folder:
            if sourceFolder == nil { return "Choose a source folder." }
        case .list:
            if listPath == nil { return "Choose a cover list." }
            guard let l = coverList, !l.lines.isEmpty else {
                return "That list has no usable line: each one needs an absolute release folder in its first column."
            }
            if l.lines.allSatisfy({ !l.selects($0, job: recipe.job) }) {
                return BatchError.listEmpty.localizedDescription
            }
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
        case .list:
            guard let l = coverList else { throw BatchError.listEmpty }
            return try .list(l, job: recipe.job)
        case .published:
            guard let p = manifestPath else { throw BatchError.manifestMissing }
            return try .published(try loadManifest(at: p))
        }
    }

    /// What this run leaves to a person or to ndisc, in words. Empty unless a
    /// list with an actions column is driving it.
    var leftOut: String { coverList?.leftOut(job: recipe.job) ?? "" }

    // MARK: - surveying

    /// Recompute what the run would touch.
    ///
    /// Off the main actor: it is only a directory walk and decodes nothing,
    /// but a library of a few thousand releases is still a few thousand
    /// `contentsOfDirectory` calls and the filter field has to stay typeable.
    func refreshSurvey() async {
        guard let scope = try? currentScope() else { survey = nil; changeCount = nil; return }
        let needle = self.needle
        let job = recipe.job
        let cap = canvas
        surveying = true
        defer { surveying = false }
        let result = await Task.detached(priority: .userInitiated) {
            // The change count is taken over the RUN's own file list, so "245
            // of 2,377" cannot be a count of something else. Header reads
            // only: nothing is decoded here either.
            let survey = surveyBatch(scope, needle: needle)
            let changes: Int? = job.keepsFile
                ? findImages(in: scope, needle: needle)
                    .filter { wouldChange($0, job: job, canvas: cap) }.count
                : nil
            return (survey, changes)
        }.value
        // The filter may have moved on while we walked; the last word wins.
        guard needle == self.needle else { return }
        survey = result.0
        changeCount = result.1
    }

    /// Render the first few outputs, unasked.
    ///
    /// Through the same `renderOne` a run uses, so it is a sample of the real
    /// thing rather than an impression of it. Cancellable, because it is
    /// driven by controls somebody is still moving.
    func refreshSamples() async {
        guard blocker == nil, let scope = try? currentScope() else {
            samples = []; return
        }
        let hits = Array(findImages(in: scope, needle: needle).prefix(Self.autoPreviewCount))
        guard !hits.isEmpty else { samples = []; return }
        sampling = true
        defer { sampling = false }
        let r = recipe
        var out: [Thumb] = []
        for hit in hits {
            if Task.isCancelled { return }
            let label = relativePath(of: hit, under: scope.strip)
            do {
                // A sample of what the run does, and for a keep-format job
                // that includes doing nothing: a file it would leave alone has
                // no output to show, so it is not one of the samples.
                guard let made = try await renderOne(hit, recipe: r) else { continue }
                out.append(Thumb(label: label, image: made.nsImage(), error: nil))
            } catch {
                out.append(Thumb(label: label, image: nil, error: error.localizedDescription))
            }
        }
        guard !Task.isCancelled else { return }
        samples = out
    }

    /// Everything a sample depends on, as one value — so no change can leave a
    /// stale picture on screen next to the controls that no longer made it.
    var sampleKey: String {
        [scope.rawValue, sourceFolder?.path ?? "", listPath?.path ?? "", needle,
         String(canvas), String(describing: job),
         String(describing: padFill), discOn ? "disc" : "plain", fill.rawValue,
         fillColour.rgb.hex].joined(separator: "|")
    }

    // MARK: - choosing folders

    func chooseSource() {
        if let u = pickFolder("Choose the folder of artwork") { sourceFolder = u }
    }

    func chooseList() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "ndisc's Export list, or a text file with one release folder per line"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        listPath = u
        do {
            coverList = try readCoverList(at: u)
            error = nil
        } catch {
            coverList = nil
            self.error = error.localizedDescription
        }
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
                    if let out = try await renderOne(hit, recipe: r) {
                        thumbs.append(Thumb(label: label, image: out.nsImage(), error: nil))
                    } else {
                        thumbs.append(Thumb(label: label, image: nil,
                                            error: "left alone — \(r.job.name) would not change it"))
                    }
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
            // Planned for the whole run, not file by file: two covers in one
            // release would otherwise plan the same output and the second
            // would replace the first, both reported as written.
            let rels = hits.map { relativePath(of: $0, under: s.strip) }
            let plan = planDests(rels: rels, outRoot: out, job: r.job, disc: r.disc != nil)

            for ((hit, rel), planned) in zip(zip(hits, rels), plan) {
                if cancelled { break }
                do {
                    let dest = try planned.get()
                    // The format is settled before the render, so a file this
                    // app cannot write is reported as left-as-it-is rather
                    // than decoded and then refused.
                    let format = try batchWriteFormat(dest: dest, job: r.job)
                    guard let rendered = try await renderOne(hit, recipe: r) else {
                        skipped += 1
                        record(Row(rel: rel,
                                   outcome: .skipped("\(r.job.name) would not change it")))
                        done += 1
                        continue
                    }
                    if !dry {
                        try FileManager.default.createDirectory(
                            at: dest.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        // A keep-format job carries a JPEG's own RGB through,
                        // so there is no alpha to lose and nothing to refuse;
                        // the framings write PNG and keep theirs.
                        try rendered.write(to: dest, as: format, alpha: .discard)
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
        total = 0; done = 0; ok = 0; failed = 0; skipped = 0
        rows = []; thumbs = []; error = nil
    }


    private func record(_ row: Row) {
        guard rows.count < Self.resultRows else { return }
        rows.append(row)
    }

    /// Decode one file and render it. SVG goes through WebKit and is therefore
    /// awaited; everything else is a straight decode.
    /// `nil` = the keep-format job would leave this file alone.
    private func renderOne(_ url: URL, recipe r: Recipe) async throws -> Raster? {
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
    /// What the Run button promises: the number of someone's files this run
    /// will write. For a keep-format job that is not the number it looked at.
    var actionCount: Int? { recipe.job.keepsFile ? changeCount : survey?.total }

    /// "to shrink", "to square" — what the button's count is a count of.
    var actionVerb: String? {
        switch recipe.job {
        case .frame:            return nil
        case .cap:              return "to shrink"
        case .square, .pad:     return "to square"
        }
    }

    var summary: String {
        if running { return "\(done) of \(total)…" }
        if total == 0 { return "" }
        var s = "\(ok) \(dryRun ? "would be written" : "written")"
        if skipped > 0 { s += ", \(skipped) left alone" }
        if failed > 0 { s += ", \(failed) failed" }
        if stopped { s += " — stopped" }
        if rows.count >= Self.resultRows {
            s += ". Showing the first \(Self.resultRows) of \(done)."
        }
        return s
    }
}
