# n.cover (macOS)

**n.cover** builds cover / label artwork: open a PNG or SVG, place it on a
square canvas, mask it into a disc, save a PNG.

This is the **native macOS app** — SwiftUI, Core Graphics, WebKit. It is a
sibling of [`xjmzx/ncover`](https://github.com/xjmzx/ncover), the GTK4 app for
Linux, not a port of it. The two share a purpose and a set of rules; they are
free to develop differently, and deliberately share no code.

## Build

```
make app     # build n.cover.app
make run     # build and launch
make test    # run the ported rule tests
make install # copy to ~/Applications
```

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



- Open **PNG / JPEG / WebP / SVG**.
- Place the source on a square canvas (200–1000 px) with drag, magnify and
  snapping to the canvas centre and edges — each axis snapping independently,
  with a visible guide when one fires.
- **Cover** or **Fit** framing. Changing the canvas size rescales the framing
  rather than re-cropping it.
- A **mask** — disc, rounded rectangle or chamfer, the latter two with an
  adjustable amount. At full amount a rounded rectangle *is* the disc, so the
  control runs continuously from square to circle. Corners can be left
  transparent, filled white, filled with a colour, or run as a radial gradient
  from the rim outward.
- A **preview backdrop** — checker, grey, black, white, or a colour picked from
  the image or from anywhere on screen — so alpha can be judged against the
  background the artwork will sit on. It is never written to the file.
- Save as PNG, or **as SVG** when the source is vector and every step has a
  vector form. Or overwrite the original — but only ever a PNG.
- Undo and redo the whole edit history (⌘Z / ⇧⌘Z).

Output is always PNG. Not a preference: the disc mask needs an alpha channel.

## Testing

`make test` runs the automated suite. Everything below it needs a human, because
it is about gestures, dialogs and what the screen actually shows — and because
the bugs found here so far have all been in that gap.

### Covered automatically (21 tests)

| Area | What is asserted |
|---|---|
| Disc mask | Transparent / white / solid / gradient corners; gradient runs rim→corner; a non-square source is covered, not letterboxed |
| Placement | Cover and Fit centring and scale; snapping to centre and edges; each axis independent; rescaling a canvas does not re-crop |
| Drag | A slow drag escapes a snap zone; a small one is held by it; translation is divided by the view scale; a zero scale is refused |
| Guards | Output may not equal or nest inside the source; Overwrite refuses anything but a PNG |
| File I/O | A PNG round-trips with its alpha corners intact |

Ported tests keep the GTK app's original names and expected pixel values, so the
two apps stay honest where they still claim to do the same thing. **When this
app diverges on purpose, delete the test rather than weaken it** — a loosened
assertion hides a regression; a deleted one records a decision.

### Verified so far

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

### A thing worth knowing about the disc

The disc is inscribed in the **canvas**, not fitted to the artwork. Give it a
source that does not fill the canvas — an icon with a grid margin, anything
placed with Fit — and the circle only grazes the artwork's four corners, which
reads as a shallow 45° chamfer rather than a record. That is correct behaviour
and measurably a circle; it just is not what the eye expects. For the classic
disc, the source has to reach the canvas edges.

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

Not yet here, and present in the GTK app: named palettes, colour history,
screen picking, batch over a folder or an ndisc-published discography.

## Licence

MIT.
