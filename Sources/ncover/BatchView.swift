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
    @StateObject private var run = BatchRunner()
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
                    Picker("Framing", selection: $run.framing) {
                        Text("Cover").tag(Framing.cover)
                        Text("Fit").tag(Framing.fit)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Disc mask", isOn: $run.discOn)
                        .tip("The disc is an option, not the point — resizing a folder of covers is a job on its own.")
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
                    Text("Every output is a PNG. Not a preference — the disc mask needs an alpha channel.")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                scopeSurvey
                if !run.thumbs.isEmpty { previewSheet }
                if !run.rows.isEmpty { results }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .alert("Batch", isPresented: Binding(
            get: { run.error != nil }, set: { if !$0 { run.error = nil } }
        )) {
            Button("OK", role: .cancel) { run.error = nil }
        } message: { Text(run.error ?? "") }
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
        .task(id: "\(run.scope.rawValue)|\(run.sourceFolder?.path ?? "")|\(run.needle)") {
            // A beat, so a walk does not start on every keystroke.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await run.refreshSurvey()
        }
    }

    private func headline(_ s: BatchSurvey) -> String {
        let what = run.scope == .published ? "release" : "folder"
        var out = "\(s.total) image\(s.total == 1 ? "" : "s")"
        out += " in \(s.groups.count) \(what)\(s.groups.count == 1 ? "" : "s")"
        if s.emptyRoots > 0 {
            out += " · \(s.emptyRoots) \(what)\(s.emptyRoots == 1 ? "" : "s") matched nothing"
        }
        return out
    }

    @ViewBuilder
    private var previewSheet: some View {
        Section(run.total > BatchRunner.previewCount
                ? "Preview — the first \(BatchRunner.previewCount) of \(run.total)"
                : "Preview") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 10), count: 5),
                      spacing: 12) {
                ForEach(run.thumbs) { t in
                    VStack(spacing: 3) {
                        ZStack {
                            MiniChecker()
                            if let i = t.image {
                                Image(nsImage: i).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                        Text(t.label)
                            .font(.caption2).lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.secondary)
                    }
                    .tip(t.error ?? t.label)
                }
            }
        }
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
                    }
                    Text(row.rel).lineLimit(1).truncationMode(.head)
                    Spacer()
                    if case .failed(let why) = row.outcome {
                        Text(why).font(.caption).foregroundStyle(.orange)
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
                Button("Preview") { Task { await run.preview() } }
                    .disabled(run.blocker != nil)
                Button(runLabel) { Task { await run.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(run.blocker != nil)
            }
        }
        .padding(14)
    }
}
