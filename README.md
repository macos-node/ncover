# n.cover (macOS)

**n.cover** builds cover / label artwork: open a PNG or SVG, place it on a
square canvas, mask it into a disc, save a PNG.

This is the **native macOS app** — SwiftUI, Core Graphics, WebKit. It is a
sibling of [`xjmzx/ncover`](https://github.com/xjmzx/ncover), the GTK4 app for
Linux, not a port of it. The two share a purpose and a set of rules; they are
free to develop differently, and deliberately share no code.

## Install

Download the `.dmg` from
[Releases](https://github.com/macos-node/ncover/releases) and drag
**n.cover** to Applications. (A `.zip` is published too, for scripts.)

It is **Apple silicon only** and **not notarized** — the bundle is ad-hoc
signed, so macOS refuses it on first launch and says the app is damaged. It is
not. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/n.cover.app
```

If you would rather not do that, build it from source — the instructions below
produce the same app, without the flag.

## Build

```
make app     # build n.cover.app
make dmg     # build a disk image (Apple silicon)
make run     # build and launch
make test    # run the rule tests
make install # copy to ~/Applications
make icon    # regenerate ncover.icns from icon.svg (needs rsvg-convert)
make version V=0.2.0   # bump the version before tagging
```

`make dmg` writes `n.cover-<version>-macos-arm64.dmg`, then **mounts it and
verifies the signature on the app inside** — a bundle whose ad-hoc signature
did not survive the copy renders every SVG blank, silently, which is not
something to find out from a release.

Releases are cut by pushing a tag: `make version V=x.y.z`, update
`CHANGELOG.md`, commit, then `git tag v0.2.0 && git push --tags`.

Needs Xcode (Swift 6, macOS 14+ target). No `.xcodeproj` — SwiftPM builds the
binary and the Makefile assembles the bundle.

## How it is built

A **composition** is a source plus an ordered list of **operations**. Two
backends render that same list: **raster**, always available and driving the
preview, and **vector**, available when the source is an SVG and every operation
has a vector form. When it is not available the app says which step refused.

That is why SVG in can mean SVG out, with no pixels in between — a vector source
has no native resolution, so rasterising one in order to write one is pure loss.
Measured on the same composition, the two backends agree to 0.61% RMSE, and the
vector file is 5KB against 41KB for a 400px PNG while rendering at any size.

Undo is a stack of compositions, so no operation needs its own inverse.

## What it does

**Colour**

- Pick a colour from **anywhere on screen** (the system sampler), from the
  **artwork** (click a pixel, with a readout of what is under the pointer), or
  from **macOS's own Colours panel** — all three land in the same history.
- Every colour is shown as **HEX, RGB and HSL at once**, each its own copy
  button. Copy puts the text *and* an `NSColor` on the pasteboard, so another
  app's colour well takes it.
- A **history** 32 deep, recency-deduplicated, with the most recent ten as a
  strip you can scan.
- **Palettes** with named swatches: import `.gpl`, `.json` and `.clr` (including
  the colour lists macOS already has, by name), export to **GPL, JSON, CSS or
  CLR**, and **install into `~/Library/Colors`** so a palette shows up in every
  app's Colours panel. Pin up to three to the Colour view.
- A palette **from the artwork**: for a raster, its dominant colours, quantised;
  for an SVG, the colours it **declares**, with its fonts and text shown beside
  them. The difference matters — a PNG does not state its colours, an SVG does.
- The app's palettes are **attached to NSColorPanel**, so they appear in its
  Palettes tab.

**Artwork**

- Open **PNG / JPEG / WebP / SVG**, or **browse a folder** — every image beside
  the one you opened is one arrow key (or ⌘[ / ⌘]) away.
- Place the source on a square canvas (200–1000 px) with drag, magnify and
  snapping to the canvas centre and edges — each axis snapping independently,
  with a visible guide when one fires.
- **Cover** or **Fit** framing. Changing the canvas size rescales the framing
  rather than re-cropping it.
- **Build steps that stack**: a blank canvas to start from, **Invert** (RGB
  only — a transparent pixel stays transparent), a **centred square**,
  **type**, and a **mask**.
- **Type**, set in any installed font through the system font panel, sized and
  positioned as fractions of the canvas so it scales with the output rather
  than being stranded at a point size. It exports as **outlines, not as a font
  reference** — an SVG that says `font-family` is a different picture on a
  machine without that font, and this one is not.
- A **blank canvas carries a vector form**, so a composition built from
  nothing — type, a square, a mask — saves as a real SVG with no pixels
  involved.
- A **mask** — disc, rounded rectangle or chamfer, the latter two with an
  adjustable amount — inscribed either in the **canvas** or in the **artwork's**
  own bounds. The latter matters for a source that does not reach the canvas
  edges: inscribed in the canvas it is only clipped at its corners, inscribed in
  the artwork it becomes a mask *of the artwork*. At full amount a rounded
  rectangle *is* the disc, so the control runs continuously from square to
  circle. Corners can be left transparent, filled white, filled with a colour,
  or run as a radial gradient from the rim outward.
- A **grid** (thirds, centre, the inscribed circle) and a **Source / Result
  rail**, so what every control changed is visible beside what it changed.
- A **preview backdrop** — checker, grey, black, white, or a colour picked from
  the image or from anywhere on screen — so alpha can be judged against the
  background the artwork will sit on. It is never written to the file.
- Save as PNG, or **as SVG** when the source is vector and every step has a
  vector form. Or overwrite the original — but only ever a PNG.
- **Batch** one recipe over a folder, or over every release **ndisc** has
  published, with a **preview contact sheet** and a **dry run**. It never
  writes over your originals, and refuses an output folder that would make the
  next run eat its own output.
- Undo and redo the whole edit history (⌘Z / ⇧⌘Z).

Output is always PNG. Not a preference: the disc mask needs an alpha channel.

## Testing

`make test` runs the automated suite. Everything below it needs a human, because
it is about gestures, dialogs and what the screen actually shows — and because
the bugs found here so far have all been in that gap.

### Covered automatically (111 tests — 84 swift-testing, 27 XCTest)

| Area | What is asserted |
|---|---|
| Disc mask | Transparent / white / solid / gradient corners; gradient runs rim→corner; a non-square source is covered, not letterboxed |
| Placement | Cover and Fit centring and scale; snapping to centre and edges; each axis independent; rescaling a canvas does not re-crop |
| Drag | A slow drag escapes a snap zone; a small one is held by it; translation is divided by the view scale; a zero scale is refused |
| Build steps | Invert leaves alpha alone; a stamped square is centred, opaque and clamped; the square has a vector form and is drawn over the artwork |
| Type | The block centres on its point; size scales with the canvas; tracking widens about the centre; a second line stacks and the *block* stays centred; the colour is exact where coverage is full; the vector form is paths and names no font; both backends agree on where a glyph sits; a blank canvas can be saved as SVG; a missing font is reported rather than substituted silently |
| Colour | HEX / RGB / HSL forms; `.gpl` reads named, unnamed and space-named swatches and round-trips; `.clr` round-trips through NSColorList; CSS uses swatch names; the JSON is the GTK app's shape |
| Store | History and pins are recency-deduped and capped; a rename follows its pin and refuses a collision; a removed palette is unpinned; every field survives a file it has never seen |
| Quantising | Dominant colours come back most-used first; transparent pixels are not colours; the representative is a colour the image contains |
| SVG | Declared colours, not pixels; `none` and `url(#…)` are not colours; fonts, text and structure; a `style=""` is read; a malformed file errors |
| Batch | The destination mirrors the source tree; discovery recurses, filters and skips dot-dirs; a file found twice is written once; a manifest with no root falls back to what its releases share, or is refused; a whole run writes the right file and leaves the original byte-identical |
| Guards | Output may not equal, nest inside, or contain the source; Overwrite refuses anything but a PNG |
| File I/O | A PNG round-trips with its alpha corners intact |

Ported tests keep the GTK app's original names and expected pixel values, so the
two apps stay honest where they still claim to do the same thing. **When this
app diverges on purpose, delete the test rather than weaken it** — a loosened
assertion hides a regression; a deleted one records a decision.

### Verified so far

**2026-11-03, type.** The raster and vector backends were rendered to the same
400px square and compared pixel for pixel, the SVG through **librsvg** rather
than this app's own WebKit — a wholly independent renderer, with no font
installed, which is the point of exporting outlines.

- **98.8% of pixels are byte-identical.** The 1.2% that differ are the glyphs'
  own one-pixel perimeter; adding a disc mask adds ~1,500 more, which is its
  circumference. Whole-image RMSE is 2.8%, and that figure is carried almost
  entirely by a few hundred edge pixels swinging between black and white.
- **They are aligned, not merely similar.** Comparing at every one-pixel
  offset, (0, 0) is the minimum at 2.29% and each neighbour is roughly double
  it (4.7–6.5%). A sub-pixel disagreement in the layout would not look like
  that. Both backends read their positions out of the same `layoutText`, and
  this is the measurement that says so.



The checklist above is a template — its boxes stay empty and get re-run. This is
the record of what has actually been exercised on real files.

**2026-09-23 (later):** tooltips appear on hover throughout, wrapped to a
sensible width. Getting there needed three mechanisms and a window flag — see
the tooltip notes in `CLAUDE.md` before touching them, because the two that
failed both read as correct.

**2026-09-23:** the mask shapes and the amount slider, the vector refusal on a
gradient over a non-circular mask, and the backdrop (including that it stays out
of saved files) were all exercised by hand and behave.

**2026-09-22, v0.1.0, macOS 27:**

- PNG and SVG both open, drag and snap as expected. The SVG case also confirms
  WKWebView rendering inside the real bundle, and that `make app`'s ad-hoc
  signature survived.
- Pinch-zoom, snap guides and the disc mask behave.
- Save writes a PNG.
- **Overwrite replaces a PNG in place**, on a copy saved for the purpose. The
  written file was measured afterwards: 400×400 as chosen, corners genuinely at
  `alpha=0`, so alpha survives end to end — checked against the file rather than
  trusted from the writer.
- **Disc geometry measured on that output**: the alpha boundary sits at distance
  200.0 from the centre of a 400 canvas — exactly the radius — with the
  one-pixel ramp visible either side of it. It is a true circle.
- **Resampling quality, measured against a direct render of the same SVG at the
  same size.** 4.04% RMSE with the original fixed-raster-plus-nearest path,
  1.63% with area-averaged downscaling, 1.24% once the SVG is also re-rendered
  at the size it is drawn at — which is the WebKit-vs-librsvg floor, so the
  resampling error is gone rather than merely reduced. Worst-case cost
  (2048→400) is 15.3 ms, so the live preview is still the output image.

**Not yet exercised, in rough order of how much it matters:**

- Changing canvas size mid-edit and confirming the framing is kept, not re-cropped.
- JPEG and WebP sources; a corrupt file producing a readable error.
- Menu shortcuts, tooltips, window resize.

### A thing worth knowing about the mask

By default a mask is inscribed in the **canvas**. Give it a source that does not
fill the canvas — an icon with a grid margin, anything placed with Fit — and the
shape only grazes the artwork's four corners, which reads as a shallow chamfer
rather than a record. That is correct, and measurably a circle; it just is not
what the eye expects.

**Fit to Artwork** is the answer: it inscribes the mask in the square bounding
whatever is actually drawn. On the suite's own icon, whose art fills 80.5% of
its tile, that is a region of 322px on a 400px canvas — and the result is a disc
of the icon rather than a barely-nicked square.

### Manual checklist

Run through this before calling a change done. Tick what you checked, and say
what you did not.

**Opening**

- [ ] A PNG opens and appears on the canvas.
- [ ] An SVG opens and renders — *not* blank. A blank SVG almost always means
      the bundle lost its ad-hoc signature; rebuild with `make app`.
- [ ] A JPEG and a WebP open.
- [ ] A corrupt or non-image file gives a readable error, not a crash.
- [ ] Opening a second image replaces the first cleanly.

**Placement**

- [ ] Drag moves the image and it tracks the cursor — no lag, no racing ahead.
- [ ] A **slow** drag through the centre escapes the snap zone. (This was broken
      in the first build and is the reason the drag tests exist.)
- [ ] Pinch-zoom works, and still works *during* a drag without fighting it.
- [ ] After a pinch, an SVG re-sharpens rather than staying soft (it is
      re-rendered at its new drawn size when the gesture ends).
- [ ] Drag stays smooth on a large source — the downscale filter runs per frame.
- [ ] Snap guides appear when an axis catches and vanish on release.
- [ ] One axis can be snapped while the other is free.
- [ ] Cover crops the long axis; Fit shows the whole image.
- [ ] Changing canvas size keeps the framing — the square grows, the picture
      does not move.
- [ ] Reset placement re-centres.

**Disc / label mask**

- [ ] The mask is a circle inscribed in the square, and clips the corners.
- [ ] Rounded and chamfer shapes clip as expected, and the amount slider moves them.
- [ ] Fit to Artwork on an inset source produces a mask of the artwork, not of
      the canvas; Fit to Canvas restores the old behaviour.
- [ ] With Fit to Artwork and a gradient fill, the ramp still reaches its outer
      colour at the furthest canvas corner.
- [ ] A rounded mask at 100% is indistinguishable from the disc.
- [ ] With a gradient fill on a rounded or chamfer mask, the inspector says SVG
      is unavailable and names the step.
- [ ] Backdrop: checker, grey, black and white all apply, and none of them
      appears in a saved file.
- [ ] Backdrop from image samples the clicked pixel; a transparent pixel is refused.
- [ ] Backdrop from screen opens the system sampler.
- [ ] The backdrop choice survives quitting and reopening.
- [ ] Transparent corners read as the checkerboard, not as white.
- [ ] White, colour and gradient corners each render as chosen.
- [ ] The gradient runs from the rim outward, reaching the corner colour at the
      actual corner.
- [ ] Dragging still works with the mask on.

**Output — the part that touches user data**

- [ ] Save writes a PNG, and the source file is untouched.
- [ ] Alpha survives the file: reopen the saved PNG and the corners are still
      transparent.
- [ ] The saved pixel size matches the chosen canvas.
- [ ] Thin lines and curves in a shrunk image look smooth, not stepped or
      unevenly thickened.
- [ ] Overwrite is disabled for a JPEG, SVG and WebP source.
- [ ] Overwrite on a PNG replaces it in place, and the result reopens correctly.

**Colour**

- [ ] Pick from screen opens the system sampler, and the colour lands in the
      history and in all three readouts.
- [ ] Each of the three readouts copies in its own format, and switching
      format changes what a later Copy writes.
- [ ] A copied colour pastes into another app's colour well, not just as text.
- [ ] The Colours panel opens, this app's palettes appear in its Palettes tab,
      and dragging round the wheel does *not* fill the history. Keep adds one.
- [ ] The in-app eyedropper shows a readout under the pointer and picks on
      click; a transparent pixel is refused with a readable reason.
- [ ] History: 32 deep, a repeat moves to the front rather than duplicating,
      and "Save as palette" keeps all of them, not the visible ten.
- [ ] Palettes: import a `.gpl`, a `.json` and a `.clr`; import a macOS colour
      list by name; name a swatch; pin three and watch the fourth push one off.
- [ ] Export each of the four formats and reopen the file in something else.
- [ ] Install in `~/Library/Colors`, then find the palette in TextEdit's
      Colours panel.
- [ ] Palette from an image, and from an SVG — the SVG one should be the
      file's own hex values, with its fonts and text shown.

**Build steps and browsing**

- [ ] Invert inverts the colours and leaves transparent pixels transparent.
- [ ] A centred square stamps opaque, the slider moves it, and it covers
      transparent ground.
- [ ] Blank canvas starts from white, and Overwrite is off (there is nothing
      to overwrite). **Save As offers SVG** — it is a vector source now.
- [ ] Type appears, and the font panel changes the face.
- [ ] The nine-way position grid moves it; the two sliders reach between them.
- [ ] Changing the canvas size scales the type with it rather than leaving it
      the same number of pixels.
- [ ] A multi-line string stacks, and the *block* stays centred rather than
      the first line.
- [ ] An SVG saved with type opens in a browser and in a drawing app, on a
      machine without the font, and looks the same.
- [ ] The grid shows thirds, centre and the inscribed circle, and appears in
      no saved file.
- [ ] The Source / Result rail shows the file on the left and the canvas on
      the right, and both update.
- [ ] Browse a folder; ← and → (and ⌘[ / ⌘]) walk it and wrap at both ends.
- [ ] Opening a new image clears the build steps rather than applying them to it.

**Batch — the part that touches a lot of user data at once**

- [ ] The output folder being the source, inside it, or above it is each
      refused with its own reason, before anything is written.
- [ ] Preview renders the first twelve, including the failures.
- [ ] A dry run writes nothing and still reports a file that would fail.
- [ ] A real run mirrors the source tree, suffixes `-disc` only with a mask,
      writes PNG, and leaves every original untouched.
- [ ] Stop actually stops, and the summary says it did.
- [ ] With ndisc's manifest present, the published scope finds the releases
      and mirrors against the library root.
- [ ] An SVG in a batch renders rather than failing (it goes through WebKit,
      so this is the one that proves the loop serialises).

**Fit and finish**

- [ ] Tooltips appear on the toolbar, the inspector controls and the canvas.
- [ ] Controls highlight on hover at all. If nothing does, the window has lost
      `acceptsMouseMovedEvents` and tooltips will be dead too — same fault.
- [ ] Every icon-only control has a tooltip **that actually appears on hover**,
      and none renders blank. (`NCOVER_TRACE_HOVER=1` proves hover is reaching
      the app; only looking proves the tooltip is drawn.)
- [ ] The mask shape icons match what the mask actually does.
- [ ] The corner-fill swatches show the colours currently chosen.
- [ ] Menu shortcuts work: ⌘O, ⌘S, ⇧⌘S.
- [ ] The window resizes sensibly and the canvas stays square.
- [ ] Errors surface as an alert with readable text.

### Comparing against the GTK app

Both apps run on this Mac. For anything where they still claim to agree, render
the same source with the same recipe in each and compare the output files
directly — that is what makes the Linux app an oracle rather than a memory.

## Relationship to the GTK app

The Linux app came first and specified the behaviour. Where both still claim to
do the same thing, `Tests/NCoverKitTests` asserts it, keeping the original test
names and the original expected pixel values. That makes the GTK app a test
oracle rather than a dependency — and when this app diverges on purpose, the
test is deleted rather than weakened.

**Still only in the GTK app**, and deliberately:

- **Seeded sample files.** The GTK app writes four demo files on first run,
  each showing a different feature. Writing unrequested files into someone's
  home directory is a bigger decision on macOS than on Linux, and it is not
  one to make quietly in a parity pass — so it is a documented gap rather than
  a silent one.
- **The getting-started tips panel.** The same call: it exists to introduce
  the seeded samples.
- **A magnifier while picking.** The GTK app draws a crosshair and a zoomed
  preview under the cursor. Here the canvas shows a **readout** of the colour
  under the pointer instead, which answers the question a magnifier is
  actually for — *which* colour am I about to get — with less machinery.

**Only here**, because the platform has it: the system colour sampler
(the GTK app needs a separate X11 binary, and a portal on Wayland),
`NSColorPanel` with this app's palettes attached, `.clr` colour lists,
installing a palette into `~/Library/Colors`, and SVG output.

## Licence

MIT.
