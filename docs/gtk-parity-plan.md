# Porting plan: bringing this app up to the GTK sibling's batch

Drafted 2026-11-20. This app is at **0.5.1** (plus two unreleased changes);
[`xjmzx/ncover`](https://github.com/xjmzx/ncover) is at **0.4.0**. The version
numbers are independent and always have been.

This is the mirror of that repo's `docs/macos-parity-plan.md`, which ported
*this* app's composition model, undo, batch survey and auto-preview to GTK
(phases 0, 1 and 4, done 2026-11-13). Having caught up, the GTK side kept
going and built a **cover review loop** that this app has nothing of. This
plan brings it across.

It ports **behaviour and decisions, not Rust.** The two share no code, by
decision, and that stays true. Where the GTK side wrote down *why* something
is the way it is (its `CLAUDE.md` "Batch: the count is a promise"), that
reasoning comes with the feature.

**The goal is 1-1 on features and functions.** Library size is explicitly not
a reason to build or skip anything: a job that is right for 2,000 covers is
right for 23, and an app that only works on the big library is an app that
cannot be tested on the small one.

## The loop this is for

Four steps, two apps, plain files between them — no shared database:

1. **ndisc** — *Local covers vs Blossom*, then *Export list*.
2. **n.cover** — *From a list…*, filtered to the problem at hand. Then Square
   or Cap, or replace a file by hand via *Open folder*.
3. **n.cover** — write the results into the library, keeping the originals.
4. **ndisc** — scan library, check again, upload, publish.

ndisc's end of it shipped in **0.7.6** (the Export list) and **0.7.7**. Step 3
is **not built on either platform** — see *Not yet on either side*.

## What is already at parity (no work)

Folder and `published.json` scopes, the survey and its per-release file lists,
releases named "Artist — Title" from the manifest, auto-preview through the
run's own renderer, the twelve-thumbnail Preview, failures carrying their
reason, the three `guardBatch` refusals, disc off by default, area-averaged
shrinking on the way down (GTK brought this forward from its phase 2;
`compose` here has done it since the port, measured 4.04% → 1.63% RMSE), a
background that composites under the artwork and *is* written to the file
(`+ Background` there, `.background` here since 0.4.0), and whole-run output
name planning (`plan_dests` there, `planDests` here as of 2026-11-19 — the
same bug, found there first).

## What this app has and GTK does not

Do not port these backwards, and do not let a "parity" change weaken them:
SDF masks with rounded-rect and chamfer shapes, `MaskRegion.artwork`, **SVG
vector export** with an honest `hasVectorForm` per operation, *Use as
template*, **type** as outlines, `.clr` import/export with
`~/Library/Colors` and `NSColorPanel` palette attachment, and the disk image.
GTK's phases 2, 3 and 5 are these, still unbuilt there.

---

## Phase A: the write layer (prerequisite, no visible feature)

Everything in B, C and E needs a JPEG encoder and a rule about alpha. Nothing
in this phase changes what the app appears to do.

- **`Raster.writeJPEG(to:quality:)`** beside `writePNG`, through
  `CGImageDestination` with `kCGImageDestinationLossyCompressionQuality`.
  **Quality 0.92**, to match `cap_format`'s `("quality", "92")` — the image is
  being made smaller, which hides the re-encoding, and a photographed cover has
  no alpha to need PNG for.
- **`Raster.isOpaque`.** The reason this is not optional: `cgImage()` hands
  over `CGImageAlphaInfo.last`, ImageIO's JPEG encoder **drops the alpha
  channel and keeps the RGB bytes**, and `Raster.load` zeroes RGB wherever
  `a == 0`. So a disc mask's transparent corners would be written as **black**,
  silently, with no error anywhere. This is the one way a JPEG path can
  corrupt output quietly, the same category as answering `hasVectorForm`
  dishonestly.
- **Two different answers to alpha, and both are deliberate** — GTK has them in
  two places and so should this:
  - *Overwrite* (one file, from the editor) **refuses** a result with
    transparency rather than flattening it onto a colour nobody chose.
  - *Batch's keep-format jobs* (phase B) **drop** alpha for a JPEG, because
    Cap / Square / Pad carry a JPEG's own RGB through and there should be no
    alpha in the first place.
- **Write beside, then rename over.** `overwrite_in_place` writes a sibling
  temp file and renames it onto the original, so a failed write leaves the
  original whole. `writePNG` writes to the URL directly, which is fine for a
  file we are creating and not fine for a file in someone's music library.
- **`guardOverwrite` learns the rule** (`WriteGuard.swift`): PNG always; JPEG
  when the result is opaque; anything else refused by extension, with the
  reason in words. It is the tested boundary, so the transparency refusal
  belongs here and not in `AppModel.overwrite`. `AppModel.canOverwrite`
  follows it rather than re-deriving it.
- **Header-only pixel size.** `imageSize(of: URL) -> (Int, Int)?` via
  `CGImageSourceCopyPropertiesAtIndex`, which reads the header and not the
  pixels. GTK hand-parses PNG and JPEG headers because gdk-pixbuf's
  `file_info` decodes far into a JPEG — 14 s for 2,400 covers against 0.1 s.
  ImageIO already answers from the header, so **this is the one place to be
  platform-native rather than faithful**; measure it on the real library and
  record the number.
- **Rewrite two `CLAUDE.md` traps** in the same commit, or the next reader
  will "fix" this back: *"Output is always PNG"* becomes "Cover / Fit output
  is always PNG; Cap, Square and Pad tidy a file, so they keep its format",
  and the Overwrite trap gains the transparency rule.

Tests: quality and the round trip, `isOpaque` on an alpha-edged render, the
guard's three answers, and that a failed write leaves the original byte-equal.

Release as **0.6.0** — it is a write-path change, visible or not.

**Status (2026-11-20): done.** `write(to:as:alpha:)`, `isOpaque`,
`replaceFile`, `imageSize(of:)`, the guard's new rule, and the two CLAUDE.md
traps. Measured on this Mac's library: 37 covers, 0.023 s from headers against
1.526 s decoding them — 65×, every answer equal to the decode's. The timing
test is off unless `NCOVER_LIBRARY` names a folder. Not verified in a window:
the confirm text and the refusal tooltip.

## Phase B: the keep-format jobs — Cap, Square, Pad

The heart of it. Three jobs that are **not framings onto a square**: they
tidy a file in place, keep its name and format, and **write nothing at all
for a file they would not change**. That last property is what makes a run
over a whole library reviewable rather than a leap.

- **Do not add cases to `Framing`.** Here `Framing` is the editor's *placement
  intent* — `resetFraming()` turns it into a `Placement` — and it is shared by
  the canvas picker and the batch picker. GTK has no such sharing, which is
  why `Framing::{Cap, Square, Pad}` is fine there and would leak into the
  editor's control here. Add a batch-only `BatchJob` instead:
  `.frame(Framing)` for Cover / Fit, and `.cap`, `.square`, `.pad(PadFill)`.
  `BatchJob.keepsFile` is the predicate the write path and the planner read.
- **Cap** shrinks only images whose longer side exceeds the size, keeping
  aspect; **Square** crops a non-square image to the centre of its shorter
  side, then shrinks if still larger; **Pad** squares it the other way, filling
  the bars with the **edge colour** (each bar the average of the image edge
  beside it, transparency included, so a transparent logo gets transparent
  bars), white, black, or the picked colour.
- **Square and Pad are one list line.** Both answer `ncover:square`, because
  cropping or padding is the operator's choice per run, not ndisc's.
- **Refusals, in words:** WebP and GIF are refused rather than converted
  (`cap_format`'s error names the extension); and **Square with the disc on is
  refused** — a format that keeps its own shape has no room for a disc's
  transparent corners.
- **A third outcome.** `BatchRunner.Row.Outcome` is `wrote` / `failed`; it
  needs `skipped(String)` ("already square", "within the cap"). Without it a
  skip has to be reported as one of the other two, and both would be lies.
- **The planner learns the family.** `batchDest` hardcodes `.png`; a
  keep-format job's destination is the source's own name and extension under
  the mirror. Note that the collision `planDests` exists for **cannot arise**
  there — two sources that differ only by extension keep different names — so
  the disambiguation stays scoped to the PNG family, and a test should say so.
- **The count and the run decide from the same read.** `would_change` is asked
  by the counter and by the runner, from `imageSize` alone. "Run (245 of 2,377
  to shrink)" is a promise; two code paths answering it separately is how it
  stops being one.

Release as **0.7.0**.

**Status (2026-11-20): done**, except the editor question below. `BatchJob`
with `.cap`, `.square`, `.pad(PadFill)`; `jobResultSize` as the one arithmetic
the survey and the run both ask; `Outcome.skipped`; `keepDest` and
`batchWriteFormat`; the disc refusal; and the Run button counting what it will
write ("Run (245 of 2,377 to shrink)"). Two things worth recording:

- **`areaResample` came out of `compose`'s downscale rather than beside it.**
  A keep-format job shrinks a rectangle to a rectangle, which is the same box
  filter with its own per-axis ratio and no placement, so both now share one
  accumulator. The pinned resampling tests passed unchanged across that
  refactor, which is what made it safe to do first.
- **`Recipe.framing` is now optional.** A keep-format recipe has no framing,
  and returning `.cover` for one would have let `render` quietly frame a file
  that was meant to be tidied. `render` states its fallback instead of
  pretending the question does not arise.

Still open from this phase: the keep-format jobs are batch-only, matching GTK.

## Phase C: the list scope

The actual interop surface, and the reason any of this is urgent.

- **A third `BatchScope`**, from a text file of one release folder per line —
  ndisc's Export list, or a hand-made list of folders. The existing
  `BatchScope` shape already takes it: roots are the folders, `strip` and
  `guardRoot` their common parent, `names` the "Artist — Title" each line
  carries.
- **Format** (tab-separated, no header, `-` for an empty field):
  `folder · cover file · artist — title · disk WxH · published WxH · format ·
  kinds · actions`. Every column after the first is optional, so a plain list
  of folders works.
- **Only the named cover file.** Where a line names one, that root contributes
  that file alone, so a release's back or inlay is never touched. This is the
  one thing today's walk-everything discovery cannot express, and it is the
  whole point — add it to the scope rather than filtering after the walk, or
  the survey and the run can disagree.
- **The job picks the lines.** With an actions column, Cap takes only
  `ncover:cap` and Square / Pad only `ncover:square`. The survey **counts what
  it left out** by each line's first action in ndisc's run order ("112 need a
  new source · 24 to review"), so work that belongs to a person or to ndisc is
  visible rather than missing.
- **Lines that cannot be used are reported with their line number.** A list
  that shrinks quietly is worse than one that complains.

Release as **0.8.0**.

**Status (2026-11-20): done.** `parseCoverList` / `CoverList`,
`BatchScope.list(_:job:)` with `only` for the named cover, `leftOut` in
ndisc's action order, and the scope row in the batch sheet. Two things worth
recording:

- **`BatchScope.images(under:needle:)` had to be introduced** before the
  restriction could exist, because `findImages(in:)` and `surveyBatch` each
  walked a root themselves. Now both go through it, which is also the
  structural answer to "the survey and the run must agree".
- **The job is part of the scope under a list**, so it is in `sampleKey`. That
  was in the plan, and it is the one easy thing to lose later.

Not verified in a window, and not yet against a list ndisc actually exported:
the test for that is opt-in behind `NCOVER_LIST`, ready for the first real
export.

## Phase D: the review surface

- **One model, two views.** A grid of every file the run would touch and a
  **numbered Files list** holding exactly those files in that order, under one
  selection — GTK uses a single `ListStore` with one `SingleSelection`, and
  that is why their numbers agree. Never give either view a list of its own.
- Under Cover / Fit, every file in run order, as the run would write it; under
  the keep-format jobs, **only the files the run would change**, most cropped
  (Square) or largest (Cap) first.
- **Thumbnails render lazily, through the run's own function**, only for cells
  on screen, each plan a generation so a stale worker stops. A whole-library
  Cover scope is ~2,400 full-canvas renders; rendering the plan up front is
  not an option. Here that means serialising SVG sources through the
  main-actor rasteriser, as the runner already must.
- Each row says its size change in words: "600 × 533 → 533 × 533 · 67 px off
  the sides (11%)".
- **Before** flips the grid to the files as they are now; **Open folder**
  reveals the selected cover in the Finder, for replacing one by hand.
- **Double-click (or Return) opens the file in the editor**, and the grid's
  files become the editor's browse list, so ⌘[ / ⌘] step through them in the
  grid's order.
- **Recount after an Overwrite.** The grid, the counts and the Run button
  re-read the files when you come back, so a cover squared by hand drops off
  Square's list.
- This replaces the four auto-samples and the twelve-thumbnail Preview, as it
  did there: a grid that is always current is both of those, done properly.

Release as **0.9.0**.

**Status (2026-11-20): done.** `planItems` / `PlanItem` in the Kit, the grid
and the numbered Files list over one selection, per-cell lazy thumbnails with
a generation check, Before, Open folder, double-click into the editor through
`adoptBrowseList`, and the recount. The samples and the Preview sheet are
gone. Three things came out differently from the plan:

- **The runner had to move out of the sheet.** `BatchView` held it as a
  `@StateObject`, and the route this phase builds — grid → editor → back —
  closes the sheet, which threw away the scope, the list and the output folder
  every time. `ContentView` owns it now, and the recount is
  `AppModel.overwriteCount` in the `.task` id. That is this app's answer to
  what GTK solved with a `written` cell and a Batch *page*; the page itself is
  still phase E.
- **`sizeChangeInWords` needed the job.** A pad followed by a cap ends up
  smaller than it started, and from two sizes alone that reads as a crop. The
  phase B signature was wrong and a phase D test is what found it.
- **A vector is in a framing's plan and in no keep-format job's**, since it
  has no pixel size to cap or square. It carries no "from" size and no
  sentence rather than a guessed one.

Not verified in a window: everything visual in it — how the grid fills while
scrolling, whether the Files list is usable at a few hundred rows, and the
double-click hand-off.

## Phase E: Overwrite from the editor, and the furniture

- **Overwrite needs no build step** — framing alone is enough, so a cover the
  grid flagged can be squared by hand and written back. It keeps JPEG as JPEG
  (phase A), and its confirm says what it will write: the original's size, and
  "600 × 600, JPEG at quality 92".
- Save stays **PNG (and SVG where the document can)**: GTK's Save is PNG-only
  too, and "JPEG export" in this plan means Overwrite and the keep-format
  batch jobs, not a JPEG item in the save panel. A draggable crop saved as
  JPEG from the editor is on *their* backlog, not in their app.
- The rest is furniture, and only worth doing if D lands: Batch as a place of
  its own rather than a sheet, the editor's side columns hideable, the Quick
  start as a page behind ⓘ, and the monochrome treatment for a chosen segment
  (inverted, light-on-dark) with Overwrite staying red.

Release as **1.0.0** if everything above is in.

**Status (2026-11-20): done, with one deliberate refusal.**

- **Overwrite needed no unblocking** — it never had a build-step gate here, so
  framing alone was already enough. What it was missing was the *confirm*,
  which the GTK app has and this one did not: it wrote immediately. That is
  now an alert naming both sizes and the format, with Cancel in the cancel
  role and Overwrite in the destructive one.
- **Batch became a sidebar place and the Quick start a fifth one.** The
  sidebar is this app's answer to GTK's header switch — re-decided in its own
  terms, as the plan asked — and it is what the grid needed rather than a
  tidy-up: the sheet closed on every trip to the editor.
- **The monochrome accents were refused**, and the reasoning is in `CLAUDE.md`
  under *Places*: GTK inverts a chosen segment to match its own theme, while a
  macOS segmented control is tinted with the user's system accent colour.
  Repainting it here would break parity with the sibling's *intent*. Overwrite
  staying red survives, as the `destructive` role.
- `ColorData` gained `tips`, `rail` and `inspector`, with `tips` taking the
  sibling's key name and its default-true, and a test pinning that a file
  written before these keys existed still loads.

Not verified in a window: the whole phase. The confirm's wording, the Quick
start at a small window size, and whether Batch reads as a place rather than a
mode are all things to look at rather than reason about.

---

## Not yet on either side

1-1 means these are **not** built here first. If one is wanted sooner, say so
deliberately rather than drifting ahead:

- **Write results into the library, keeping originals** — step 3 of the loop.
  Today both sides output to a folder and the swap is a desktop script. It
  belongs in the app, with every swap logged and an undo that restores from
  the log.
- **Convert (PNG → JPEG)**, for the `ncover:convert` lines.
- **Dimension filters** beside the name filter (non-square by more than X%,
  long side over / under N px), joining the walk's selection so every count
  agrees with them.
- **A draggable square crop in the editor**, for the covers a centre crop is
  wrong for — a CD insert with the hinge strip down one side.

## Order and sizing

| Phase | What | Size | Depends on |
|---|---|---|---|
| A | JPEG encode, alpha rule, atomic write, header size | S–M | — |
| B | Cap / Square / Pad, `BatchJob`, the skipped outcome | M–L | A |
| C | The list scope and ndisc's Export list | M | B (for the job → line mapping) |
| D | Grid + numbered Files list, lazy thumbs, Open folder | L | B |
| E | Overwrite without a build step, the furniture | S–M | A, D |

**A → B → C → D → E.** A is small and unblocks the rest; C is the one with a
waiting producer, so it is worth reaching before D.

## Things to settle before starting

- **Does the editor get the keep-format jobs too, or only batch?** They are
  batch-only on the GTK side. Keeping that is 1-1; the alternative is a
  genuine divergence and should be recorded as one.
- **Where the review grid lives.** This app has a sidebar and a split view
  where GTK has a header switch, so "Batch is a page of its own" has to be
  re-decided in this app's own terms rather than copied.
- **Verification.** Each phase gets checked in the running app, not only by
  tests — a session here cannot capture the screen, so anything visual is the
  user's to confirm, and the plan should say which step needs that.
