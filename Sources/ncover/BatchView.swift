import NCoverKit
import SwiftUI

/// Batch: a recipe, a scope, and two folders that may not be the same one.
///
/// A place in the sidebar rather than a sheet. It was a sheet until the review
/// grid arrived, and the route the grid builds — pick a cover, fix it in the
/// editor, come back — closed it every time; a modal you keep closing is not
/// where a job you are working through belongs. `ContentView` owns the runner
/// for the same reason.
///
/// Laid out so the dangerous field is impossible to miss. The guard is in the
/// model and refuses regardless, but a refusal is a worse experience than a
/// layout that stops you reaching for it.
struct BatchView: View {
    @EnvironmentObject var model: AppModel
    /// Owned by `ContentView`, not by this view.
    ///
    /// The sheet is torn down every time it closes, and the intended route
    /// through the review loop closes it: pick a cover in the grid, fix it in
    /// the editor, come back. A `@StateObject` here would throw away the
    /// scope, the list and the output folder on the way out — so the runner
    /// outlives the sheet, and only the recount happens on the way back in.
    @ObservedObject var run: BatchRunner

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
            Form {
                Section("What to run it over") {
                    // Three icons rather than three sentences, as the GTK
                    // sibling has them: folder · list · disc. What each one
                    // takes is in the tip, and the row directly below names
                    // the chosen one anyway (Source / List / Manifest), so
                    // nothing is carried by the glyph alone.
                    Picker("Scope", selection: $run.scope) {
                        ForEach(BatchRunner.Scope.allCases) { s in
                            Image(systemName: s.symbol)
                                .accessibilityLabel(s.label)
                                .tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tip("Where the images come from: a folder of artwork, a text file of release folders (ndisc's Export list), or every release ndisc has published.")

                    if run.scope == .folder {
                        LabeledContent("Source") {
                            HStack {
                                Text(run.sourceFolder?.path(percentEncoded: false) ?? "—")
                                    .lineLimit(1).truncationMode(.head)
                                    .foregroundStyle(run.sourceFolder == nil ? .tertiary : .primary)
                                Spacer()
                                Button("Choose…") { run.chooseSource() }
                            }
                        }
                    } else if run.scope == .list {
                        LabeledContent("List") {
                            HStack {
                                Text(run.listPath?.path(percentEncoded: false) ?? "—")
                                    .lineLimit(1).truncationMode(.head)
                                    .foregroundStyle(run.listPath == nil ? .tertiary : .primary)
                                Spacer()
                                Button("Choose…") { run.chooseList() }
                            }
                        }
                        .tip("ndisc's Export list, from Local covers vs Blossom — or any text file with one release folder per line. Where a line names its cover file, only that file is taken.")
                        if let l = run.coverList {
                            Text(listSummary(l)).font(.caption).foregroundStyle(.secondary)
                            if !l.skipped.isEmpty {
                                Text("\(l.skipped.count) line\(l.skipped.count == 1 ? "" : "s") skipped — no absolute release folder: \(l.skipped.prefix(8).map(String.init).joined(separator: ", "))\(l.skipped.count > 8 ? "…" : "")")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    } else if let p = run.manifestPath {
                        LabeledContent("Manifest") {
                            Text(p.path(percentEncoded: false))
                                .lineLimit(1).truncationMode(.head).font(.caption)
                        }
                        .tip("ndisc writes this when it publishes. The releases in it become the folders to walk, and the library root is what the output mirrors.")
                    } else {
                        Text("ndisc has not exported a manifest.")
                            .foregroundStyle(.secondary)
                    }

                    TextField("Name contains", text: $run.needle, prompt: Text("every image"))
                        .tip("Only files whose name contains this. “cover” is the usual one — a release folder often holds back and inlay art too.")
                }

                Section("Where the results go") {
                    // Two equal choices, as the scope is. The second is the
                    // one that touches someone's library, so everything about
                    // it — its own folder, its own guard, a confirm, a red
                    // Run — hangs off this one control.
                    Picker("Output", selection: $run.output) {
                        ForEach(BatchRunner.Output.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .tip("Either the results go to a folder of their own, or each cover is replaced where it lives with its original kept first. Into the library is Cap, Square and Pad only.")

                    if run.output == .folder {
                        LabeledContent("Output") {
                            HStack {
                                Text(run.outputFolder?.path(percentEncoded: false) ?? "—")
                                    .lineLimit(1).truncationMode(.head)
                                    .foregroundStyle(run.outputFolder == nil ? .tertiary : .primary)
                                Spacer()
                                Button("Choose…") { run.chooseOutput() }
                            }
                        }
                        .tip("Never the source folder, and never inside it. To a folder does not write over your originals — not as an option, not with a confirmation.")
                    } else {
                        LabeledContent("Originals") {
                            HStack {
                                Text(run.originalsFolder?.path(percentEncoded: false) ?? "—")
                                    .lineLimit(1).truncationMode(.head)
                                    .foregroundStyle(run.originalsFolder == nil ? .tertiary : .primary)
                                Spacer()
                                Button("Choose…") { run.chooseOriginals() }
                            }
                        }
                        .tip("The folder each replaced original is copied to, under the same path as in the library, with the log beside them. Not the library, inside it, or above it. Remembered.")
                        if !run.recipe.job.keepsFile {
                            // The same sentence `blocker` refuses with, so the
                            // reason is here rather than only under the Run
                            // button — the disc refusal's pattern.
                            Text(WriteBackError.notAKeepFormatJob(run.recipe.job.name)
                                .localizedDescription)
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let last = run.lastRunInfo {
                            LabeledContent("Last run") {
                                HStack {
                                    Text("\(last.time) · \(last.swaps) cover\(last.swaps == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Put back last run") { run.askUndo() }
                                }
                            }
                            .tip("Restore the originals of the most recent run into the library, newest first, from the log in the originals folder. A cover changed since that run is left as it is and named. Press again for the run before.")
                        }
                    }

                    Toggle("Dry run", isOn: $run.dryRun)
                        .tip("Render everything and write nothing. It still fails on a file that would really fail, so it tells you what a real run would do.")
                }

                Section("The recipe") {
                    Picker("Canvas", selection: $run.canvas) {
                        ForEach(CANVAS_SIZES, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Picker("Job", selection: $run.job) {
                        Text("Cover").tag(BatchJob.frame(.cover))
                        Text("Fit").tag(BatchJob.frame(.fit))
                        Text("Cap").tag(BatchJob.cap)
                        Text("Square").tag(BatchJob.square)
                        Text("Pad").tag(BatchJob.pad(.edge))
                        Text("Convert").tag(BatchJob.convert)
                    }
                    .pickerStyle(.segmented)
                    .tip("Cover and Fit write a new square PNG. Cap, Square and Pad tidy each file in place — same name, same format — and write nothing at all for a file they would not change. Convert re-encodes a PNG as a JPEG under the same stem, for ndisc's ncover:convert lines.")
                    if run.recipe.job == .convert {
                        Text("cover.png → cover.jpg at quality 92, not one pixel changed. A PNG with transparent areas is refused rather than stored as black: give it a background first, in the editor or with Pad.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if case .pad = run.job {
                        Picker("Bars", selection: $run.padFill) {
                            Text("Edge").tag(PadFill.edge)
                            Text("White").tag(PadFill.white)
                            Text("Black").tag(PadFill.black)
                            Text("Colour").tag(PadFill.solid(run.fillColour.rgb))
                        }
                        .pickerStyle(.segmented)
                        .tip("Edge takes each bar from the average of the image edge beside it, transparency included — so a transparent logo gets transparent bars.")
                    }
                    Toggle("Disc mask", isOn: $run.discOn)
                        .disabled(run.job.keepsFile)
                        .tip(run.job.keepsFile
                             ? "\(run.job.name) keeps each file's own format, which has no room for a disc's transparent corners."
                             : "The disc is an option, not the point — resizing a folder of covers is a job on its own.")
                    if run.discOn {
                        Picker("Corners", selection: $run.fill) {
                            Text("Transparent").tag(AppModel.FillKind.alpha)
                            Text("White").tag(AppModel.FillKind.white)
                            Text("Colour").tag(AppModel.FillKind.solid)
                        }
                        .pickerStyle(.segmented)
                        if run.fill == .solid {
                            PaletteWell(label: "Colour", colour: $run.fillColour,
                                        help: "What fills outside the mask in every output.")
                        }
                    }
                    Text(run.job.keepsFile
                         ? "\(run.job.name) keeps each file's name and format — a JPEG stays a JPEG at quality 92 — and leaves a file it would not change untouched."
                         : "Every output is a PNG. Not a preference — the disc mask needs an alpha channel.")
                        .font(.caption).foregroundStyle(.tertiary)
                    if let refusal = run.jobDiscRefusal {
                        Text(refusal).font(.caption).foregroundStyle(.orange)
                    }
                }

                scopeSurvey
                filesList
            }
            .formStyle(.grouped)
            .frame(minWidth: 360, idealWidth: 420)

            // The grid gets the rest of the window, and that is the whole
            // point of it. It sat under the controls in one scrolling column
            // to begin with, which put it below fifteen release rows — a
            // preview you have to go looking for is one you will not look at,
            // and the first real run was made without ever seeing it.
            reviewPane
                .frame(minWidth: 300)
        }

            Divider()
            footer
        }
        .frame(minWidth: 860, idealWidth: 1000, minHeight: 560, idealHeight: 760)
        // Re-survey when the scope, the filter or the recipe changes — and
        // on the whole view, not on a section inside the Form. It lived on
        // the survey's Section, whose branch is replaced the moment the first
        // survey lands, which tore the task down mid-flight and left the grid
        // empty beside counts that said fifteen.
        //
        // The overwrite count is in the id for the recount: a cover squared
        // by hand in the editor changes on disk, so the counts and the grid
        // have to be re-read rather than keep describing the file as it was.
        .task(id: "\(run.sampleKey)|\(model.overwriteCount)") {
            // A beat, so no walk starts on every keystroke or every notch of
            // a slider.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await run.refreshSurvey()
        }
        .alert("Batch", isPresented: Binding(
            get: { run.error != nil }, set: { if !$0 { run.error = nil } }
        )) {
            Button("OK", role: .cancel) { run.error = nil }
        } message: { Text(run.error ?? "") }
        // Replacing covers in the library asks, as Overwrite does. Cancel
        // takes the cancel role so Esc and ⌘. both take the safe way out, and
        // the destructive role is what makes the other button red on a Mac
        // rather than a colour chosen here.
        .alert(run.pendingLibraryRun?.title ?? "", isPresented: Binding(
            get: { run.pendingLibraryRun != nil },
            set: { if !$0 { run.pendingLibraryRun = nil } }
        )) {
            Button("Cancel", role: .cancel) { run.pendingLibraryRun = nil }
            Button("Replace", role: .destructive) {
                run.pendingLibraryRun = nil
                Task { await run.run(confirmed: true) }
            }
        } message: { Text(run.pendingLibraryRun?.detail ?? "") }
        .alert(run.pendingUndo?.title ?? "", isPresented: Binding(
            get: { run.pendingUndo != nil }, set: { if !$0 { run.pendingUndo = nil } }
        )) {
            Button("Cancel", role: .cancel) { run.pendingUndo = nil }
            Button("Put back", role: .destructive) {
                run.pendingUndo = nil
                Task { await run.putBackLastRun() }
            }
        } message: { Text(run.pendingUndo?.detail ?? "") }
    }

    /// The right pane: every file the run would touch, as a grid — or the
    /// last run's results once there are some.
    ///
    /// The grid replaced the four automatic samples and the twelve-thumbnail
    /// preview, and it replaced them because it is both of those done
    /// properly: always current, every file rather than the first few, and
    /// under a keep-format job **only the files the run would change**, so its
    /// length is the Run button's count.
    @ViewBuilder
    private var reviewPane: some View {
        VStack(spacing: 0) {
            reviewHeader
            Divider()
            if !run.rows.isEmpty {
                resultsList
            } else if run.plan.isEmpty {
                VStack(spacing: 6) {
                    if run.planning {
                        ProgressView().controlSize(.small)
                        Text("Working out what it would touch…")
                    } else {
                        // Not `blocker`: that is about running, and the
                        // preview does not need an output folder.
                        Text(run.scopeHint)
                            .multilineTextAlignment(.center)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .background(Color(.underPageBackgroundColor))
    }

    private var reviewHeader: some View {
        HStack(spacing: 8) {
            Text(run.rows.isEmpty
                 ? (run.showBefore ? "The files as they are" : "What the run would write")
                 : "Results")
                .font(.headline)
            if run.planning { ProgressView().controlSize(.small) }
            Spacer()
            if run.rows.isEmpty {
                Text("\(run.plan.count)").monospacedDigit().foregroundStyle(.secondary)
                Toggle("Before", isOn: $run.showBefore)
                    .toggleStyle(.button)
                    .disabled(run.plan.isEmpty)
                    .tip("Show the files as they are now, rather than as the run would write them.")
            }
            if let item = run.selectedItem {
                Button("Open folder") { run.revealInFinder(item) }
                    .tip("Show this cover in the Finder — for replacing one by hand.")
                Button("Edit") { openInEditor(item) }
                    .tip("Open this file in the editor. The grid becomes the browse list, so ⌘[ and ⌘] step through it in this order.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                ForEach(run.plan) { item in
                    cell(item)
                }
            }
            .padding(12)
        }
    }

    /// The same files, numbered, under the controls. One array, one selection:
    /// that is why the numbers agree and why picking in either moves the other.
    @ViewBuilder
    private var filesList: some View {
        if !run.plan.isEmpty {
            Section("Files") {
                ForEach(run.plan) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.number)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 26, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.callout).lineLimit(1)
                            Text(item.words.isEmpty ? item.rel : item.words)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(item.url.lastPathComponent)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 1)
                    .background(run.selected == item.id
                                ? Color.accentColor.opacity(0.14) : Color.clear)
                    .contentShape(Rectangle())
                    // The DOUBLE tap is declared first, and has to be: with
                    // the single first, SwiftUI resolves that one and the
                    // double never fires at all.
                    .onTapGesture(count: 2) { openInEditor(item) }
                    .onTapGesture { run.selected = item.id }
                }
            }
        }
    }

    /// One grid cell: its thumbnail, rendered when it first appears and never
    /// before. A plan is thousands of files; rendering it up front is not an
    /// option, and the `.task` goes away with the cell when it scrolls off.
    private func cell(_ item: PlanItem) -> some View {
        VStack(spacing: 3) {
            ZStack {
                MiniChecker()
                if let i = run.thumb(item, before: run.showBefore) {
                    Image(nsImage: i).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(run.selected == item.id ? Color.accentColor : Color(.separatorColor),
                              lineWidth: run.selected == item.id ? 2 : 1))
            Text("\(item.number)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(run.selected == item.id ? .primary : .tertiary)
        }
        .contentShape(Rectangle())
        // Double first — see the Files list above.
        .onTapGesture(count: 2) { openInEditor(item) }
        .onTapGesture { run.selected = item.id }
        .tip("\(item.number) · \(item.name)\n\(item.words.isEmpty ? item.rel : item.words)")
        // Watches what decides the picture, not everything that triggers a
        // refresh: choosing an output folder must not restart every render.
        .task(id: "\(item.id)|\(run.showBefore)|\(run.thumbKey)") {
            await run.requestThumb(item, before: run.showBefore)
        }
    }

    /// Hand the file to the editor, with the grid as its browse list, and get
    /// out of the way. Overwrite is then one confirm from the library — which
    /// is the intended route for a cover a centre crop would be wrong for.
    private func openInEditor(_ item: PlanItem) {
        model.adoptBrowseList(run.plan.map(\.url), at: item.url)
        model.section = .artwork
    }

    /// What the run would touch, before anything is rendered. Walking
    /// directories decodes nothing, so this can keep up with typing — and a
    /// filter whose effect you cannot see is a guess.
    @ViewBuilder
    private var scopeSurvey: some View {
        Section("What it will touch") {
            if let s = run.survey {
                HStack(spacing: 8) {
                    Text(headline(s)).font(.callout)
                    if run.surveying { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !run.leftOut.isEmpty {
                    // What the list holds for someone else. Counted and named
                    // rather than missing: a line this job does not take has
                    // not been dealt with, it is just not this run's work.
                    Text("not in this run: \(run.leftOut)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if s.total == 0 {
                    Text(run.needle.isEmpty
                         ? "No images found under that scope."
                         : "Nothing matches “\(run.needle)”. Clear the filter to take every image.")
                        .font(.caption).foregroundStyle(.orange)
                }
                // The per-release disclosure list that used to be here is
                // gone: the numbered Files list below says the same thing
                // better (it is the grid's own order, with each file's size
                // change), and fifteen expandable rows between the controls
                // and the grid is what pushed the grid off the window.
            } else if run.surveying {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…") }
            } else {
                Text("Choose a scope.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    /// What the chosen list holds, before any job is applied to it.
    private func listSummary(_ l: CoverList) -> String {
        var out = "\(l.lines.count) release\(l.lines.count == 1 ? "" : "s")"
        let named = l.lines.filter { $0.cover != nil }.count
        if named > 0 { out += " · \(named) name a cover file" }
        out += l.hasActions ? " · with ndisc's actions" : " · no actions column, so every line is in"
        return out
    }

    private func headline(_ s: BatchSurvey) -> String {
        let what = run.scope == .folder ? "folder" : "release"
        var out = "\(s.total) image\(s.total == 1 ? "" : "s")"
        out += " in \(s.groups.count) \(what)\(s.groups.count == 1 ? "" : "s")"
        if s.emptyRoots > 0 {
            out += " · \(s.emptyRoots) \(what)\(s.emptyRoots == 1 ? "" : "s") matched nothing"
        }
        if s.rootsWithNoPlace > 0 {
            // Not under the scope's own folder, so there is nowhere to mirror
            // what is in it: ndisc's manifest naming a release outside the
            // library root is how this arises.
            out += " · \(s.rootsWithNoPlace) \(what)\(s.rootsWithNoPlace == 1 ? " is" : "s are") outside the scope"
        }
        if s.missingNamed > 0 {
            // The list named a file that is not there any more. Said plainly:
            // it is neither a failure nor nothing, and it is someone's to look at.
            out += " · \(s.missingNamed) named file\(s.missingNamed == 1 ? " is" : "s are") not there"
        }
        if let n = run.changeCount, let verb = run.actionVerb {
            out += " · \(n) \(verb), \(s.total - n) already as they should be"
        }
        return out
    }

    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(run.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    switch row.outcome {
                    case .wrote:
                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                    case .failed:
                        Image(systemName: "xmark").foregroundStyle(.orange)
                    case .skipped:
                        // Not a tick and not a cross: nothing happened to this
                        // file, which is a third thing and reads as one.
                        Image(systemName: "minus").foregroundStyle(.tertiary)
                    }
                    Text(row.rel).lineLimit(1).truncationMode(.head)
                    Spacer()
                    if case .failed(let why) = row.outcome {
                        Text(why).font(.caption).foregroundStyle(.orange)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if case .skipped(let why) = row.outcome {
                        Text(why).font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
            }
            }
            .padding(.vertical, 8)
        }
    }

    /// The button says how many files it is about to touch. "Run" over an
    /// unknown number of someone's originals is a worse button than "Run 20".
    private var runLabel: String {
        let verb = run.dryRun ? "Dry run" : "Run"
        guard let n = run.actionCount, n > 0 else { return verb }
        // A keep-format job looked at everything and will write a fraction of
        // it, and the button has to say which number is which: "Run (245 of
        // 2,377 to shrink)" is the promise, "Run 2,377" would be a false one.
        if let what = run.actionVerb, let total = run.survey?.total {
            return "\(verb) (\(n) of \(total) \(what))"
        }
        return "\(verb) \(n)"
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if run.running {
                ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
                    .frame(width: 140)
            }
            Text(run.blocker ?? run.summary)
                .font(.callout)
                .foregroundStyle(run.blocker == nil ? Color.secondary : Color.orange)
                .lineLimit(2)
            Spacer()
            if run.running {
                Button("Stop") { run.cancel() }
            } else {
                // Red while a press would replace covers in someone's
                // library — the sibling's rule, in this app's terms: the
                // prominent style is what carries a tint on a Mac, and the
                // plain button is right for every other run.
                let intoLibrary = run.output == .library && !run.dryRun
                Button(runLabel) { Task { await run.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(run.blocker != nil)
                    .buttonStyle(.borderedProminent)
                    .tint(intoLibrary ? .red : .accentColor)
            }
        }
        .padding(14)
    }
}
