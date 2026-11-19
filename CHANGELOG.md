# Changelog

All notable changes to the macOS n.cover. Versions follow [semver](https://semver.org).

This is a sibling of [`xjmzx/ncover`](https://github.com/xjmzx/ncover), the
GTK4 app for Linux — same name and purpose, no shared code, free to diverge.
Their version numbers are independent.

## [Unreleased]

Phases A, B and C of [`docs/gtk-parity-plan.md`](docs/gtk-parity-plan.md): the
write layer, the three jobs that tidy a library's covers rather than reframe
them, and ndisc's Export list as a scope. Three of the four steps of the cover
review loop now run in the two apps.

### Added
- **From a list… — ndisc's Export list as a batch scope.** Point it at the
  file ndisc's *Local covers vs Blossom* writes (or any text file with one
  release folder per line) and the releases in it become the folders to walk.
  **Where a line names its cover file, only that file is taken**, so a
  release's back or inlay art is never caught up in a run. The release is
  named "Artist — Title" from the list rather than by its path.
- **The job picks the lines.** With ndisc's actions column, Cap takes the
  `ncover:cap` lines and Square and Pad the `ncover:square` ones, so one
  export drives several runs. What this run does not take is **counted and
  named** in ndisc's own order — "not in this run: 112 need a new source · 24
  to review" — because those lines belong to a person or to ndisc, not to
  nobody. A list with no actions column puts every line in, which is what
  makes a hand-made list work.
- A line whose first column is not an absolute release folder is skipped and
  reported with its line number — ndisc writes "artist — title" there for a
  release that has no folder — and the chosen list says what it holds before
  any job is applied to it.
- **Cap, Square and Pad** — three batch jobs that are not framings. They keep
  each file's name and format (a JPEG stays a JPEG at quality 92) and **write
  nothing at all for a file they would not change**, which is what makes a run
  over a whole library something you can review. **Cap** shrinks only images
  whose longer side is over the size, keeping their shape. **Square** crops a
  non-square image to the centre of its shorter side. **Pad** squares it the
  other way, filling the bars with the **edge colour** — each bar the average
  of the image edge beside it, transparency included, so a transparent logo
  gets transparent bars — or white, black, or your picked colour. Square and
  Pad leave an already-square image alone however large it is: squaring is
  what they do, and capping is Cap's job.
- The Run button counts what will actually be written: **"Run (245 of 2,377 to
  shrink)"**, decided from the same arithmetic the run itself uses, and read
  from each file's header rather than by decoding it. The survey line says the
  same thing in words, and the results list has a third outcome — **left
  alone** — because reporting an untouched file as written or failed would
  both be wrong.
- A disc and a keep-format job are **refused together**, with the reason: the
  file is a JPEG as often as not, and a JPEG has nowhere to put a disc's
  transparent corners. WebP and GIF are refused by name rather than quietly
  turned into PNGs.
- **Overwrite keeps the file's own format.** A PNG stays a PNG, and a **JPEG
  stays a JPEG** at quality 92 — the same number the GTK sibling writes, so a
  cover tidied on either platform comes out the same. A result with
  transparent areas is **refused** for a JPEG rather than flattened onto a
  colour nobody chose: a JPEG has no alpha channel, and the bytes left behind
  when that channel is dropped are black, not white, so the corners of a
  masked cover would come back black with nothing reporting it. The button's
  tooltip is now the refusal itself when it cannot go, and says what it will
  write when it can.
- Overwrite **writes beside the original and renames over it**, so an encode
  that fails leaves the original whole. The target is usually a cover inside a
  music library.
- `imageSize(of:)` reads an image's pixel size from its **header**, without
  decoding it: 37 covers in 0.023 s against 1.526 s to decode the same ones.
  What a library-wide "is this already square" survey needs.

### Changed
- Save is unchanged — PNG, and SVG where the document can. JPEG is the write
  path, not the save panel.
- `make install` now installs to **`/Applications`**, which is where a Mac
  keeps applications. It had defaulted to `~/Applications`, carried over from
  the Linux side of the suite. Override with `PREFIX=$HOME/Applications`.
- It copies with `ditto` rather than `cp -R`, for the same reason the disk
  image does: that is the copy documented to carry a bundle's signature.
- It warns when a copy is left behind in the other location — two bundles
  sharing one identifier is how macOS starts launching the wrong build — and
  `make uninstall` now unregisters what it removes.

### Fixed
- **Two covers in one release no longer overwrite each other.** Every batch
  output is a PNG named after its source, so a release holding both
  `cover.jpg` and `cover.png` sent both to one `cover.png`: the second
  replaced the first, and the results list called both of them written. A dry
  run could not show it, because each file renders perfectly well on its own.
  Output names are now planned for the whole run before anything is written —
  sources that would share a name keep their extension in it
  (`cover-jpg.png`, `cover-png.png`), and everything else keeps the plain name
  it always had, so a library with no collisions comes out exactly as before.
  A clash that survives that is refused, naming the file that holds the name.
  The originals were never at risk: `guardBatch` keeps a run out of the source
  tree. Ported from the GTK sibling's 0.3.0, where it was found.

## [0.5.1] — 2026-11-03

### Added
- **Batch previews itself.** Four outputs render as soon as there is a recipe
  and something to apply it to, and follow every change to the scope, filter
  or recipe — through the same renderer a run uses. A preview you have to
  press is one you can forget to press. The Preview button still renders the
  full twelve.

### Fixed
- **The disc mask is off by default in batch.** `Recipe` has said "the disc
  is an option, not the point — resizing a folder of covers is a job on its
  own" from the start, and the batch sheet contradicted it in the one place
  that mattered: a run over a discography of covers produced discs.
- The batch sheet can grow, and opens taller. The survey plus two previews
  did not fit in 640 points.

## [0.5.0] — 2026-11-03

### Added
- **Batch says what it will touch, before you run it.** Choosing a scope now
  surveys it: how many images, in how many releases or folders, listed by
  release with their file names, and how many releases matched nothing. It
  keeps up as you type the filter, because a filter whose effect you cannot
  see is a guess — and it is a directory walk, so nothing is decoded.
- Releases are named from ndisc's manifest ("Artist — Title") rather than by
  folder path, which often disagrees with the record.
- The Run button says how many files it is about to touch.

## [0.4.0] — 2026-11-03

### Added
- **Use as template.** The source becomes a faint tracing guide on the canvas
  and is left out of the file. Drag and zoom still move it, and because it
  contributes nothing to the output, **a traced bitmap can be saved as SVG** —
  the result contains nothing of the bitmap. A raster source that is actually
  drawn still refuses vector output, as before.
- **Background**: a flat colour behind everything, and unlike the preview
  backdrop this one *is* written to the file. It composites underneath
  whatever is already drawn, and a mask still clips it, so a disc over a
  background is a coloured disc.

## [0.3.1] — 2026-11-03

### Changed
- Type can be set much larger: the size range now runs from 2% of the canvas
  to **200%**, so a letterform can be bigger than the square that crops it.
  It had stopped at 60%, which was short of filling the canvas at all.
- That range is a hundredfold, so the slider is now **logarithmic** — equal
  travel is equal ratio, and the small sizes stay controllable instead of
  being crushed into the first tenth. The readout shows the resulting point
  size beside the percentage.
- Tracking reaches further both ways (−0.25 to 0.75). Letters touching is
  something a monogram does on purpose.

## [0.3.0] — 2026-11-03

### Added
- **Type.** Set words on the canvas in any installed font, through the system
  font panel. Size, position, tracking and line height are fractions of the
  canvas, so type scales with the output rather than being stranded at a point
  size, and a nine-way grid places it without hunting with two sliders.
- Type exports as **outlines**, not as `<text font-family="…">`: a font
  reference renders as a different picture, or not at all, on a machine
  without the font. Measured against librsvg with no font installed, 98.8% of
  pixels are byte-identical to the raster backend and the two are aligned to
  the pixel, not merely similar.
- A **blank canvas now carries a vector form**, so a composition built from
  nothing — type, a square, a mask — saves as a real SVG. It used to be
  refused for "the source is not an SVG" even though every step in it had a
  perfectly good vector form.

### Changed
- Every colour well — the square's, the mask's, both gradient stops, batch's —
  now has your own colours one click away: the current colour, the recent ones
  and the pinned palettes, in a popover beside the well.
- The app's palettes are attached to the shared Colours panel **app-wide**, not
  only when the Colour view opens it. Every `ColorPicker` opens that same
  panel, so attaching on our own Show Colours left the palettes missing from
  exactly the wells that wanted them. A renamed or deleted palette is now
  detached rather than lingering in the panel for the session.

## [0.2.0] — 2026-11-03

Feature parity with the GTK sibling, plus what only macOS can do.

### Added

**Colour** — the half that was missing entirely.

- Pick from anywhere on screen (the system sampler), from the artwork (click a
  pixel, with a readout of what is under the pointer), or from macOS's own
  Colours panel. All three land in the same history.
- HEX, RGB and HSL shown at once, each its own copy button. Copy puts the text
  *and* an `NSColor` on the pasteboard, so another app's colour well takes it.
- A colour history, 32 deep and recency-deduplicated, with the most recent ten
  as a strip.
- Palettes with named swatches: import `.gpl`, `.json` and `.clr` — including
  the colour lists macOS already has, by name — and export to GPL, JSON, CSS or
  CLR. Pin up to three to the Colour view.
- **Install a palette into `~/Library/Colors`**, so it appears in every app's
  Colours panel; and the app's palettes are attached to `NSColorPanel`, so they
  appear in its Palettes tab.
- A palette from the artwork: a raster's dominant colours, quantised, or an
  SVG's **declared** colours with its fonts and text beside them.

**Artwork**

- Browse a folder: every image beside the one you opened is one arrow key, or
  ⌘[ / ⌘], away.
- Build steps that stack: a blank canvas, Invert (RGB only — alpha untouched)
  and a centred square, each an operation with its own vector form, each
  undoable.
- A grid over the preview (thirds, centre, the inscribed circle) and a
  Source / Result rail.
- **Batch**: one recipe over a folder, or over every release ndisc has
  published, with a preview contact sheet and a dry run. It never writes over
  your originals.

**Release**

- `make dmg` builds a disk image for Apple silicon and verifies the signature
  on the app *inside* it; the workflow publishes both the `.dmg` and the `.zip`,
  and refuses a tag whose version disagrees with `Info.plist`.

### Changed

- The window has a sidebar — Artwork, Colour, Palettes — because the two halves
  of the app are not the same shape.
- `guardBatch` also refuses a source folder nested inside the output folder. It
  overwrites nothing, and still has a run write over the folder its own inputs
  sit in.
- The canvas size is remembered between launches.
- 95 automated tests, up from 21.

## [0.1.0] — 2026-09-23

First release.

### Added
- Open PNG, SVG, JPEG and WebP.
- Place the source on a square canvas (200–1000 px) with drag, pinch-zoom and
  snapping to the canvas centre and edges, each axis snapping independently
  with a visible guide.
- Cover and Fit framing. Changing the canvas size rescales the framing rather
  than re-cropping it.
- Masks — disc, rounded rectangle and chamfer, the latter two with an
  adjustable amount — inscribed either in the canvas or in the artwork's own
  bounds. Corners can be transparent, white, a colour, or a radial gradient
  from the rim outward.
- A preview backdrop (checker, grey, black, white, or a colour picked from the
  image or from anywhere on screen) that is never written to a file.
- Save as PNG, or as **SVG** when the source is vector and every step has a
  vector form — no rasterising in between.
- Overwrite the original in place, guarded to PNG sources only.
- Undo and redo across the whole edit history.

[Unreleased]: https://github.com/macos-node/ncover/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/macos-node/ncover/releases/tag/v0.5.1
[0.5.0]: https://github.com/macos-node/ncover/releases/tag/v0.5.0
[0.4.0]: https://github.com/macos-node/ncover/releases/tag/v0.4.0
[0.3.1]: https://github.com/macos-node/ncover/releases/tag/v0.3.1
[0.3.0]: https://github.com/macos-node/ncover/releases/tag/v0.3.0
[0.2.0]: https://github.com/macos-node/ncover/releases/tag/v0.2.0
[0.1.0]: https://github.com/macos-node/ncover/releases/tag/v0.1.0
