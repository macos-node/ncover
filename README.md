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

## What it does (v1)

- Open **PNG / JPEG / WebP / SVG**.
- Place the source on a square canvas (200–1000 px) with drag, magnify and
  snapping to the canvas centre and edges — each axis snapping independently,
  with a visible guide when one fires.
- **Cover** or **Fit** framing. Changing the canvas size rescales the framing
  rather than re-cropping it.
- A **disc / label mask**, with the corners left transparent, filled white,
  filled with a colour, or run as a radial gradient from the rim outward.
- Save as PNG, or overwrite the original — but only ever a PNG.

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

**2026-09-22, v0.1.0, macOS 27:**

- PNG and SVG both open, drag and snap as expected. The SVG case also confirms
  WKWebView rendering inside the real bundle, and that `make app`'s ad-hoc
  signature survived.
- Pinch-zoom, snap guides and the disc mask behave.
- Save writes a PNG.

**Not yet exercised, in rough order of how much it matters:**

- **Overwrite.** The one path that replaces a user's file in place. Guarded in
  code and covered by a unit test, but never run against a real PNG.
- **Alpha survival end to end** — reopening a saved PNG and confirming the
  corners are still transparent, rather than trusting the writer.
- Changing canvas size mid-edit and confirming the framing is kept, not re-cropped.
- JPEG and WebP sources; a corrupt file producing a readable error.
- Menu shortcuts, tooltips, window resize.

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
- [ ] Snap guides appear when an axis catches and vanish on release.
- [ ] One axis can be snapped while the other is free.
- [ ] Cover crops the long axis; Fit shows the whole image.
- [ ] Changing canvas size keeps the framing — the square grows, the picture
      does not move.
- [ ] Reset placement re-centres.

**Disc / label mask**

- [ ] The mask is a circle inscribed in the square, and clips the corners.
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
- [ ] Overwrite is disabled for a JPEG, SVG and WebP source.
- [ ] Overwrite on a PNG replaces it in place, and the result reopens correctly.

**Fit and finish**

- [ ] Tooltips appear on the toolbar, the inspector controls and the canvas.
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
