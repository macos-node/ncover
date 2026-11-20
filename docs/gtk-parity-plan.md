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
- Save was to stay **PNG (and SVG where the document can)**, GTK's Save being
  PNG-only. **Changed on the user's ask, 2026-11-20:** the panel offers JPEG
  too. It is a departure and is recorded as one — a draggable crop saved as
  JPEG is on the GTK backlog, and this is half of that arriving here first.
  The alpha rule is unchanged: a render with transparency is refused, by the
  same guard Overwrite uses, so a disc mask cannot be written as black.
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

## Where the layouts differ, and why

Recorded 2026-11-20, from GTK 0.4.0 beside this app's 1.0.5. **These are not
bugs and not a backlog.** The two apps are the same features in each
platform's own idiom, and the point of writing them down is so that a later
reader can tell a deliberate difference from a thing nobody got round to.

| | GTK | here |
|---|---|---|
| Places | A header switch: Edit · Batch · Palettes · ⓘ | A sidebar: Artwork · Batch · Colour · Palettes · Quick start |
| Colour | A column down the left of the Edit page, always there | Its own sidebar place, plus the pinned palettes in it |
| Editor sides | Colours left, Source / Result right, each hideable | Inspector right, Source / Result under the canvas, both hideable from one toolbar menu |
| Batch controls | One column of compact rows under the same four section titles as here (since 2026-11-20): scope icons, Source, Output, recipe, Dry run / Run / Stop, and why Run is greyed out under them | A grouped `Form` of titled sections, with Run in the window's footer and why it cannot go beside it |
| Batch right side | A **Files / Last run** pair of tabs | The grid, which the last run's results replace until the recipe changes |
| Recipe | Dropdowns on one row (`Cover ∨`, `No disc ∨`, `600 px ∨`) | A segmented Job control, a Canvas stepper, a Disc toggle |
| Version | In the window title: `ncover 0.4.0` | The window's subtitle, beside the name |
| Samples | Ships sample artwork, with *Open samples folder* and *Restore samples* on the Quick start | **Not built here** — the nearest thing is opening any folder |

**What is shared is the vocabulary, not the furniture**: the same five jobs
under the same names, the same scopes in the same order (folder · list ·
disc), the same counts in the same words ("37 images in 21 releases · 2
releases matched nothing", "Run (10 of 10 to shrink)"), the same grid of every
file a run would touch, the same Before, the same double-click into the
editor. Someone who knows one can use the other without being told anything.

**If the two are ever to converge**, the question to settle first is *which
way*, and it is a real choice rather than an obvious one:

- **Towards GTK's compact column.** Denser, more of the recipe visible at
  once, and a tab pair that keeps the last run reachable after the grid comes
  back. It would mean giving up `Form`'s grouped sections, which are what make
  this app look like a Mac app rather than a port.
- **Towards this app's titled sections.** Easier to read cold, and the section
  titles carry a lot of the explanation that GTK puts in tooltips. It would
  mean more vertical space for the same controls, which is exactly what the
  GTK window is short of.

Nothing needs deciding to keep both working. Decide it only if the drift
starts costing something — a feature that lands in one shape and cannot be
described in the other.

## Phase F: what GTK did after 0.4.0, and what this app takes from it

Recorded 2026-11-20, after comparing this app's 1.0.6 with GTK side by side
(screenshots of every place). **Agreed: each app keeps its own layout** —
sidebar here, header switch there; Colour as a place here, a column there;
`Form` sections here, compact rows there. Those stay as the table above
records them. What follows is the rest: behaviour that should match, and the
small things each side does better. GTK has already taken its share (below);
this app's share is F1–F7, in that order (F7 can go any time).

### Already taken by GTK from this app (2026-11-20, unreleased there)

- **The four section titles** in Batch's column: *What to run it over*,
  *Where the results go*, *The recipe*, *What it will touch*. Same words.
- **Why Run cannot go, said in place**, with Run and Dry run greyed out —
  this app's footer line. GTK had a dialog on press.
- **`nameForFile`**, ported as `Scope::name_for_file`: a file is named by the
  record of the nearest named folder above it, else its folder under the
  scope. GTK's folder scope had captioned every cell with the scope folder's
  own name.

### F1. Write into the library, keeping the originals (port; L)

Step 3 of the loop. GTK's `ncover/src/writeback.rs` is the reference; port
its decisions and its tests, not its code. In GTK's words, the rule becomes
**"never writes over your source without keeping the original."**

- **Where:** *Where the results go* gets a choice, **To a folder** / **Into the
  library**. Into the library is offered for **Cap, Square and Pad only**:
  they keep the file's name and format, so ndisc's `cover_art_path` still
  points at it. Cover and Fit write a PNG under another name; the choice is
  disabled for them, and picking one while it is on goes back to a folder.
  Under Into the library the folder chooser picks the **originals folder**,
  which is remembered between launches.
- **Per file, in this order** — the library holds the old file or the new
  one at every moment, never neither:
  1. Refuse if the original's slot (`originals/<rel>`) is already taken: a
     second run must never overwrite the first original. Per file, with the
     reason; a dry run refuses it too.
  2. Copy the original whole into its slot: a temp name beside the slot,
     synced, length checked, modified time kept, renamed into place. A
     copy, not a move, so the originals folder may be on another disk.
  3. Write the result beside the source (`.cover.jpg.ncover-tmp`) and rename
     it over the source — what Overwrite already does. If this fails, delete
     the kept copy, so the slot is free.
  4. Append the `swap` line to the log. If the log cannot be written, put
     the original straight back: a swap the log does not know about cannot
     be undone.
- **The path rule.** The library file written is the walked source itself,
  never a path rebuilt from names, and its slot is its **whole** path under
  the scope's root, matched to its plan by position. So
  `Autechre/Amber/cover.jpg` and `Boards of Canada/Amber/cover.jpg` keep their
  originals in two places (GTK test:
  `the_same_title_under_two_artists_keeps_two_originals_in_two_places`). A
  file not under the root, or whose relative path holds `..`, is **refused**
  — see F6.
- **The guard** (`guard_originals`): the originals folder may not be the
  library, inside it (the next run would walk the originals as covers), or
  above it.
- **The log** is `ncover-log.tsv` in the root of the originals folder. Keep
  the format identical, so either app's log reads the same:

  ```
  # n.cover write-back log. One `swap` line per replaced file, one `undo` line per run put back.
  # swap	run	time	job	library file	original kept	before	after	written bytes	written mtime (ns)
  # undo	run	time	restored	skipped
  swap	20261120-103913	2026-11-20 10:39:13	square	/…/library/A/Amber/cover.jpg	/…/originals/A/Amber/cover.jpg	600x538	538x538	22725	1795145953867044569
  undo	20261120-103913	2026-11-20 10:52:01	2	0
  ```

  Tab-separated, absolute paths, one line per file appended and synced as it
  happens. `run` is the local start time, made unique against the log
  (`-2`, `-3` for two runs in one second); `job` is `cap`, `square` or `pad`.
  A path holding a tab or a line break is refused (the log could not record
  it).
- **Put back last run**: restores the newest run without an `undo` line,
  newest swap first. A library file whose size or modified time is not what
  the run wrote has changed since (edited by hand, say) and is **left as it
  is**, named, with its original still kept. Restoring copies the original
  beside the library file and renames it over, then deletes the kept copy
  and prunes now-empty folders. Then an `undo` line marks the run. Pressing
  it again reaches the run before. The user rated this nice-to-have; it is
  built on GTK, so port it.
- **Asking first.** A real run into the library confirms: "Replace N covers
  in the library?", naming the library, the originals folder and the log.
  Put back confirms too. On GTK the Run button turns red (destructive) while
  this output is on; here, the footer's Run button should take the same
  destructive role.
- **After a run or a Put back**, the plan recounts (the fixed covers drop out
  of Square's grid), and **the run's results stay on screen** — see F3.
- **Quick start**: "It never writes over your originals: the output folder
  cannot be the source, inside it, or above it" becomes true only of *To a
  folder*. Reword it, and add a line for Into the library.
- **Tests to port** (GTK `writeback_tests`): a run replaces and keeps byte for
  byte and logs; the two-artists case, including its Put back; outside the
  root / `..` refused; a taken slot refused, dry or not, both files
  untouched; a square file left alone and a dry run writing and keeping
  nothing; Cover and Fit refused; Put back skips a changed file, keeps its
  original, prunes empty folders and marks the run; two runs put back newest
  first with distinct run ids; the guard's three refusals.

### F2. Dry run is a button, not a toggle (S; before or with F1)

Today the footer's **Run 37** does whatever the *Dry run* switch says. Left
off, it writes; left on, a real run looks like it did nothing. Once Run can
replace files in the library that ambiguity is not acceptable. Two buttons,
as GTK has: **Dry run** and **Run**, with Run taking the destructive style
only under Into the library.

### F3. Keep the last run reachable (S)

Here the last run's results replace the grid until the recipe changes, then
are gone. GTK's **Files / Last run** pair keeps both. Take that as a
two-segment control above the grid. It matters most after F1: the grid
recounts (the fixed covers leave it), and the list of what was replaced has
to stay readable.

### F4. Grid captions (XS, optional)

The cells here show only their number; GTK's show the number, the release
name and the size change. Both are fine — the Files list carries the detail
here — but if the number alone is ever ambiguous, add the name the Files
list already has (`nameForFile`).

### F5. Small wording (XS)

- The empty Artwork page says *Open a PNG or SVG*; it opens JPEG and WebP
  too.
- *Every output is a PNG. Not a preference — the disc mask needs an alpha
  channel.* under the recipe should show only for Cover and Fit (Cap, Square
  and Pad keep the format). Check it follows the job.

### F6. A file outside the scope's root has no place (S; with F1)

`relativePath(of:under:)` falls back to the **file name** for a hit outside
the prefix. For a folder run that can put two releases' `cover.jpg` at one
output path; for F1 it would put an original at `originals/cover.jpg`.
GTK's equivalent fell back to the *absolute* path, which joined onto the
output folder is the source itself, and was fixed on 2026-11-20 by refusing
such a file with the reason (`rel_under`). Do the same here: return a
failure, never a made-up place. It is reachable with a published manifest
whose release folders are not under its `library_root`.

### F7. A list may name several files in one folder (S)

**Where this is going.** The user's aim (2026-11-20): label artwork handled
the same way as release covers, in both apps. Today a label is only
`{name, imageUrl, siteUrl}` in ndisc, with nothing on disk to check, so none
of the cover tools see labels. ndisc's backlog 4b plans three stages:

1. survey the published label images (size, PNG, not square) into the
   quality group, from headers, no local files;
2. move labels into ndisc's database (kind 31238 unchanged);
3. a **label art folder** setting, matched by normalised name, so labels
   join the quality survey and the **Export list**, one line per label.

Stage 3 is where n.cover comes in, by the same loop as covers: ndisc
exports the lines, n.cover runs Square, Cap or Pad over them from *From a
list…* (Pad was built partly for logos: square without cropping), writes
them back keeping the originals (F1), and ndisc uploads and republishes.
**n.cover needs no label-specific feature** — no Labels page, no label
scope. A label is a list line whose file happens to be a logo.

**The one thing in the way.** Covers live one release per folder; label art
lives **many labels in one folder** (the masters folder: ~363 files such as
`Ultra.Records.label.jpg`). The list scope was built around covers:
`BatchScope.only` (like GTK's `Scope::only` until 2026-11-20) maps a folder
to **one** named file, so 290 label lines into one folder take only the
last line's logo — and a survey and run that agree with each other on the
wrong number, so nothing looks broken. Found by reading the code while
planning, not by a failure; no export with shared folders exists yet.

**Decisions** (GTK, ported as decisions, with its test
`many_lines_naming_files_in_one_folder_take_every_one_of_them`):

- **Key named files per line, keep roots per folder.** `only` maps a folder
  to *every* file named in it, in list order, de-duplicated. A folder is
  one walk root however many lines name it, so the survey groups and the
  "N images in M folders" line count folders, not lines.
- **Names follow the line, not the folder.** Each file takes its own line's
  name (`file_names`, checked first by `nameForFile`). A folder several
  lines share loses its folder-level name rather than wearing whichever
  line came last — it is called by its own name.
- **A named file ignores the name filter.** The filter (default "cover")
  narrows a walk; a file the list names was chosen by the list. Found on
  ndisc's first real label export, where the filter dropped every
  `*.label.jpg`. GTK test: the shared-folder test above, run under "cover".
- **A missing file is reported by itself.** One unreadable entry per missing
  named file, naming the file, under its folder; the folder's other files
  still run, and it is not also counted as an empty root.
- **A bare folder line still means the whole folder.** If any line names
  the folder without a file, the folder is walked as before, taking the
  named files and the rest. A hand-made list of folders keeps working.
- **Nothing else changes.** Each file's place for output and for kept
  originals is still its whole path under the list's root (F1, F6), so a
  logo's original is kept at `originals/<labels folder>/<file>`, and two
  logos never share a slot because they never share a name in one folder.

**Why not a label scope, or a labels mode. Decided 2026-11-20 by the user:
labels stay list lines.** Considered and set aside: it
would be a fourth scope that is only a list with a different file, and the
two apps would then need a label vocabulary of their own. Keeping it as
list lines means ndisc owns which labels need work (it is the one that
knows what is published), n.cover stays a reader of plain files, and the
fix is one data-structure change on each side.

**Order.** F7 is independent of F1–F6 and small. It is only *needed* once
ndisc's stage 3 exports label lines, but should land before then, so the
first label export is not run over one logo.

### F8. The Label art scope and the `_labels` skip (S)

GTK 2026-11-20 (unreleased, for 0.5.0): a fourth scope button (a tag) after
folder · list · disc — `<library root>/_labels`, the root read from
published.json, offered only when the manifest is. It is a folder scope on
that directory; the name filter is emptied on entering it (label files are
not `cover.*`) and restored on leaving. And every folder walk skips a
directory named `_labels` (SUITE.md reserves it), unless it is the folder
being walked. GTK test: `a_walk_skips_labels_unless_it_is_the_folder_walked`.
Labels still also reach n.cover as list lines (F7); the scope is for
running over the whole folder.

## Not yet on either side

1-1 means these are **not** built here first. If one is wanted sooner, say so
deliberately rather than drifting ahead:

- ~~Write results into the library, keeping originals~~ — **built on GTK
  2026-11-20; see Phase F.**
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
