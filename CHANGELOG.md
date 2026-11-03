# Changelog

All notable changes to the macOS n.cover. Versions follow [semver](https://semver.org).

This is a sibling of [`xjmzx/ncover`](https://github.com/xjmzx/ncover), the
GTK4 app for Linux — same name and purpose, no shared code, free to diverge.
Their version numbers are independent.

## [Unreleased]

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

[Unreleased]: https://github.com/macos-node/ncover/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/macos-node/ncover/releases/tag/v0.2.0
[0.1.0]: https://github.com/macos-node/ncover/releases/tag/v0.1.0
