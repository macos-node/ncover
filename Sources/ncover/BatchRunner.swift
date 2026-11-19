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



    // MARK: - the plan: every file the run would touch

    /// Every file this run would write, numbered and in review order. The
    /// grid and the Files list are two views of this one array — that is why
    /// their numbers agree and why selecting in either moves the other.
    @Published private(set) var plan: [PlanItem] = []
    @Published private(set) var planning = false
    /// The selected row, shared by both views.
    @Published var selected: String?
    /// Show the files as they are now rather than as the run would write them.
    @Published var showBefore = false

    /// Rendered thumbnails, by file, recipe and before/after.
    @Published private(set) var thumbs: [String: NSImage] = [:]
    private var inFlight = Set<String>()

    /// How many thumbnails render at once.
    ///
    /// Not unbounded: a whole-library Cover scope is a couple of thousand
    /// renders at the full canvas size, and the grid asks for every cell that
    /// scrolls past. Four keeps the window responsive while filling visibly.
    /// An SVG source has to go through the main actor anyway (WKWebView), so
    /// those serialise regardless of this number.
    private static let thumbWorkers = 4
    /// How many rendered cells to keep across recipe changes before starting
    /// over. Switching Cover → Cap → Cover should be instant the second time.
    private static let thumbCap = 600
    private var rendering = 0

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
    /// Recompute what the run would touch: the counts **and** the plan.
    ///
    /// One function and one `await`, deliberately. These were two — survey,
    /// then plan — behind a `Task.isCancelled` check between them, and the
    /// plan lost that race: the first survey publishes into the view that
    /// hosts the task, the task is torn down at that moment, and the grid
    /// stayed empty while the counts beside it said fifteen. Two numbers from
    /// one walk must not be able to arrive separately.
    ///
    /// Off the main actor and header-reads only, so it can run over a whole
    /// library and stay current while the recipe is being changed.
    /// **It asks for a scope and a recipe, and nothing else.** The plan used
    /// to be gated on `blocker == nil`, which includes "choose an output
    /// folder" — so picking a list built the counts and an empty plan, and
    /// choosing the output afterwards did not rebuild it, because the output
    /// folder was not in `sampleKey` either. The grid stayed empty beside
    /// counts that said fifteen, for as long as the window was open.
    ///
    /// Where the results go has nothing to do with what the run would touch.
    /// The Run button carries the blocker; the preview does not.
    func refreshSurvey() async {
        guard let scope = try? currentScope() else {
            survey = nil; changeCount = nil; plan = []; thumbs = [:]; return
        }
        let needle = self.needle
        let r = recipe
        surveying = true
        planning = true
        defer { surveying = false; planning = false }

        let result = await Task.detached(priority: .userInitiated) {
            let survey = surveyBatch(scope, needle: needle)
            let files = findImages(in: scope, needle: needle)
            // The change count is taken over the RUN's own file list, so
            // "245 of 2,377" cannot be a count of something else.
            let changes: Int? = r.job.keepsFile
                ? files.filter { wouldChange($0, job: r.job, canvas: r.canvas) }.count
                : nil
            let plan = planItems(files: files, scope: scope, recipe: r)
            return (survey, changes, plan)
        }.value

        // The filter may have moved on while we walked; the last word wins.
        guard needle == self.needle else { return }
        survey = result.0
        changeCount = result.1
        // The thumbnails are NOT cleared here. A refresh happens for reasons
        // that have nothing to do with a picture — a new output folder, a
        // recount after an overwrite — and clearing on each one is what left
        // the grid empty.
        plan = result.2
        // The last run's counts go with its results. "15 written" sitting
        // under a plan of three is a sentence about a run nobody can see any
        // more, and it reads as a claim about this one.
        total = 0; done = 0; ok = 0; failed = 0; skipped = 0; stopped = false
        // The last run's results describe a recipe that is no longer on
        // screen. Clearing them is also what puts the grid back in the pane.
        rows = []
        if let sel = selected, !plan.contains(where: { $0.id == sel }) { selected = nil }
        trace("scope \(scope.roots.count) roots · survey \(result.0.total) · plan \(plan.count)")
    }

    /// Env-gated, and to **stderr on purpose**: `print` is fully buffered when
    /// redirected to a file, and the hover tracing this copies came back empty
    /// that way while it was working. Run the binary directly to watch:
    /// `NCOVER_TRACE_PLAN=1 /Applications/n.cover.app/Contents/MacOS/ncover`
    private func trace(_ what: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["NCOVER_TRACE_PLAN"] != nil else { return }
        FileHandle.standardError.write(Data("[plan] \(what())\n".utf8))
    }

    // MARK: - thumbnails

    /// What a thumbnail IS: this file, under this recipe, before or after.
    ///
    /// It was keyed by a counter bumped on every refresh, and that lost a race
    /// it could not win. Changing the recipe re-renders the cells at once,
    /// while the refresh behind it is debounced by 300 ms — so the pictures
    /// arrived, the refresh then cleared the cache underneath them, and
    /// nothing re-requested because the cells' own inputs had not changed
    /// again. The grid flashed and went empty, and which jobs it happened to
    /// was pure timing.
    ///
    /// Keyed by the recipe, none of that can happen: a refresh that does not
    /// change the picture does not disturb it, and one that does changes the
    /// key. Nothing has to be invalidated by hand.
    private func key(_ item: PlanItem, before: Bool, recipe r: Recipe) -> String {
        "\(before ? "before" : "after")|\(r.canvas)|\(r.job)|\(String(describing: r.disc))|\(item.url.path)"
    }

    /// Why the grid has nothing in it, in words — about the *scope*, not
    /// about whether a run could go.
    var scopeHint: String {
        switch scope {
        case .folder where sourceFolder == nil: return "Choose a folder of artwork."
        case .list where listPath == nil:       return "Choose a cover list."
        case .published where manifestPath == nil:
            return "ndisc has not exported a manifest."
        default:
            return survey?.total == 0
                ? "Nothing under that scope matches."
                : "Nothing this job would change."
        }
    }

    /// The selected row, as an item.
    var selectedItem: PlanItem? { plan.first { $0.id == selected } }

    /// Show this cover in the Finder, for replacing one by hand. One of the
    /// two ways out of the grid — the other is the editor.
    func revealInFinder(_ item: PlanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func thumb(_ item: PlanItem, before: Bool) -> NSImage? {
        thumbs[key(item, before: before, recipe: recipe)]
    }

    /// Everything that decides what a cell shows. The cell's own task watches
    /// this, so changing the output folder — which cannot change a picture —
    /// no longer restarts every render in the grid.
    var thumbKey: String {
        "\(canvas)|\(recipe.job)|\(discOn ? fill.rawValue + fillColour.rgb.hex : "plain")"
    }

    /// Render one cell, if nothing else is already doing it.
    ///
    /// Called from each cell as it appears, so only what is on screen renders
    /// — a plan is thousands of files and rendering it up front is not an
    /// option. Through the run's own `renderOne`, so a cell is what the run
    /// would write and not an impression of it.
    func requestThumb(_ item: PlanItem, before: Bool) async {
        // The recipe is read ONCE, here, and both the render and the key it
        // lands under come from that one value. Reading it again after the
        // await is how a picture ends up filed under a recipe that did not
        // make it.
        let r = recipe
        let k = key(item, before: before, recipe: r)
        guard thumbs[k] == nil, !inFlight.contains(k) else { return }
        inFlight.insert(k)
        defer { inFlight.remove(k) }
        while rendering >= Self.thumbWorkers {
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return }
        }
        rendering += 1
        defer { rendering -= 1 }
        let image: NSImage?
        if before {
            image = await Task.detached(priority: .utility) {
                (try? Raster.load(contentsOf: item.url))?.nsImage()
            }.value
        } else {
            image = try? await renderOne(item.url, recipe: r)?.nsImage()
        }
        guard let image else { return }
        // No staleness check: the key names the recipe that made it, so a
        // picture from a recipe nobody is looking at is simply never asked
        // for. It costs a little memory and buys back instant switching.
        if thumbs.count > Self.thumbCap { thumbs = [:] }
        thumbs[k] = image
    }

    /// Everything the survey and the plan depend on, as one value — so no
    /// change can leave a stale count or a stale picture on screen beside the
    /// controls that no longer made it. The job belongs here because under a
    /// list scope the job picks the lines, so it is part of the scope itself.
    var sampleKey: String {
        // The output folder is in here even though the plan no longer depends
        // on it: `guardBatch`'s refusals do, and a key that leaves out an
        // input is exactly how the grid went stale against the controls.
        [scope.rawValue, sourceFolder?.path ?? "", listPath?.path ?? "",
         outputFolder?.path ?? "", needle,
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
        rows = []; error = nil
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
