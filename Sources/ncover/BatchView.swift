import NCoverKit
import SwiftUI

/// The batch sheet: a recipe, a scope, and two folders that may not be the
/// same one.
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("What to run it over") {
                    Picker("Scope", selection: $run.scope) {
                        ForEach(BatchRunner.Scope.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.radioGroup)

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
                    LabeledContent("Output") {
                        HStack {
                            Text(run.outputFolder?.path(percentEncoded: false) ?? "—")
                                .lineLimit(1).truncationMode(.head)
                                .foregroundStyle(run.outputFolder == nil ? .tertiary : .primary)
                            Spacer()
                            Button("Choose…") { run.chooseOutput() }
                        }
                    }
                    .tip("Never the source folder, and never inside it. Batch does not write over your originals — not as an option, not with a confirmation.")

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
                    }
                    .pickerStyle(.segmented)
                    .tip("Cover and Fit write a new square PNG. Cap, Square and Pad tidy each file in place — same name, same format — and write nothing at all for a file they would not change.")
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
                planGrid
                if !run.rows.isEmpty { results }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 600, idealHeight: 760)
        .alert("Batch", isPresented: Binding(
            get: { run.error != nil }, set: { if !$0 { run.error = nil } }
        )) {
            Button("OK", role: .cancel) { run.error = nil }
        } message: { Text(run.error ?? "") }
    }

    /// Every file the run would touch, as a grid, with the same files
    /// numbered in a list beside it.
    ///
    /// This replaces the four automatic samples and the twelve-thumbnail
    /// preview, and it replaces them because it is both of those done
    /// properly: it is always current, it shows everything rather than the
    /// first few, and under a keep-format job it shows **only the files the
    /// run would change** — so its length is the Run button's count.
    ///
    /// The grid and the list are one array under one selection, which is why
    /// their numbers agree.
    @ViewBuilder
    private var planGrid: some View {
        if !run.plan.isEmpty || run.planning {
            Section {
                HStack(spacing: 8) {
                    Toggle("Before", isOn: $run.showBefore)
                        .toggleStyle(.button)
                        .tip("Show the files as they are now, rather than as the run would write them.")
                    if run.planning { ProgressView().controlSize(.small) }
                    Spacer()
                    if let item = run.selectedItem {
                        Button("Open folder") { run.revealInFinder(item) }
                            .tip("Show this cover in the Finder — for replacing one by hand.")
                        Button("Edit") { openInEditor(item) }
                            .tip("Open this file in the editor. The grid becomes the browse list, so ← and → step through it in this order.")
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(run.plan) { item in
                        cell(item)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                HStack {
                    Text(run.showBefore ? "The files as they are" : "What the run would write")
                    Spacer()
                    Text("\(run.plan.count)").monospacedDigit().foregroundStyle(.tertiary)
                }
            }

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
                    .onTapGesture { run.selected = item.id }
                    .onTapGesture(count: 2) { openInEditor(item) }
                }
            }
        }
    }

    /// One grid cell: its thumbnail, rendered when it first appears and never
    /// before. A plan is thousands of files; rendering it up front is not an
    /// option, and the `.task` goes away with the cell when it scrolls off.
    private func cell(_ item: PlanItem) -> some View {
        VStack(spacing: 2) {
            ZStack {
                MiniChecker()
                if let i = run.thumb(item, before: run.showBefore) {
                    Image(nsImage: i).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(run.selected == item.id ? Color.accentColor : Color(.separatorColor),
                              lineWidth: run.selected == item.id ? 2 : 1))
            Text("\(item.number)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(run.selected == item.id ? .primary : .tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { run.selected = item.id }
        .onTapGesture(count: 2) { openInEditor(item) }
        .tip("\(item.number) · \(item.name)\n\(item.words.isEmpty ? item.rel : item.words)")
        .task(id: "\(item.id)|\(run.showBefore)|\(run.sampleKey)") {
            await run.requestThumb(item, before: run.showBefore)
        }
    }

    /// Hand the file to the editor, with the grid as its browse list, and get
    /// out of the way. Overwrite is then one confirm from the library — which
    /// is the intended route for a cover a centre crop would be wrong for.
    private func openInEditor(_ item: PlanItem) {
        model.adoptBrowseList(run.plan.map(\.url), at: item.url)
        dismiss()
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
                } else {
                    ForEach(s.groups) { g in
                        DisclosureGroup {
                            ForEach(g.files, id: \.self) { f in
                                Text(f)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        } label: {
                            HStack {
                                Text(g.name).lineLimit(1)
                                Spacer()
                                Text("\(g.files.count)")
                                    .monospacedDigit().foregroundStyle(.tertiary)
                            }
                            .font(.callout)
                        }
                    }
                }
            } else if run.surveying {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…") }
            } else {
                Text("Choose a scope.").font(.callout).foregroundStyle(.tertiary)
            }
        }
        // Re-survey when the scope or the filter changes. The id covers all
        // three inputs, so no change can leave a stale count on screen.
        // The overwrite count is in here for the recount: a cover squared by
        // hand in the editor changes on disk, so the survey, the plan and the
        // Run button have to be re-read when you come back rather than
        // describing the file as it was.
        .task(id: "\(run.sampleKey)|\(model.overwriteCount)") {
            // A beat, so neither a walk nor a render starts on every keystroke
            // or every notch of a slider.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await run.refreshSurvey()
            guard !Task.isCancelled else { return }
            await run.refreshPlan()
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
        if let n = run.changeCount, let verb = run.actionVerb {
            out += " · \(n) \(verb), \(s.total - n) already as they should be"
        }
        return out
    }

    @ViewBuilder
    private var results: some View {
        Section("Results") {
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
            }
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
                Button("Close") { dismiss() }
                Button(runLabel) { Task { await run.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(run.blocker != nil)
            }
        }
        .padding(14)
    }
}
