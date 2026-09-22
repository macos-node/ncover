# n.cover (macOS) — notes for Claude

SwiftUI app for building cover / label artwork. Swift 6 · SwiftUI · Core
Graphics · WebKit. See [`README.md`](README.md) for the feature tour.

## This is not the GTK app, and not a port of it

[`xjmzx/ncover`](https://github.com/xjmzx/ncover) is the GTK4/Linux app. This is
a **separate app with the same name and purpose**, written natively for macOS.
They share no code, by decision: the two are expected to develop differently,
and a shared core is exactly the coupling that would prevent that.

It is also **not part of the Tauri `n.*` suite** — no webview shell, no React,
no Nostr surface, no keyring, no database. It is adjacent to the suite: the same
brand and colour language, and (once batch lands) a reader of what `ndisc`
publishes. Reaching for a suite pattern — `tauri build`, `make dev`, design
tokens as CSS variables — will waste time here.

## Build and verify

```
make app     # build n.cover.app
make run     # build and launch
make test    # 17 ported rule tests
```

## The shape: a composition, not a pipeline

A **`Composition`** is a *source* plus an ordered list of **`Operation`**s. Two
backends consume that same list:

- **`renderRaster`** — always available, and what the preview shows, so what is
  on screen is what a PNG export writes.
- **`renderVector`** — available when the source is an SVG *and* every operation
  in the list has a vector form. Returns `nil` otherwise, and
  `Composition.vectorRefusal` gives the reason in words meant for a person
  ("step 3, Invert, has no vector form").

This is the thing to understand before changing anything. Adding a capability
means **adding an `Operation` case and answering `hasVectorForm` honestly** — it
does not mean touching a pipeline. Answering that property wrong is the one way
to corrupt output silently: claim a vector form you have not written and SVG
export will quietly drop the step.

Undo is a stack of `Composition` values, so no operation needs a hand-written
inverse. Every edit goes through `AppModel.mutate`; anything that bypasses it is
a bug, because it will not be undoable.

**Rasterising an SVG in order to write an SVG is pure loss** — that is why the
vector backend exists. A vector source has no native resolution, so every pixel
the raster path produces is a decision that did not need making.

The UI currently edits a fixed shape of the list (one placement, one optional
mask). That is a UI limitation, not a model one: arbitrary stacking needs no
backend changes.

## Traps specific to this repo

- **`AppDelegate` sets `acceptsMouseMovedEvents` on every window, and must
  keep doing so.** It defaults to *false*, and a SwiftUI app assembled outside
  Xcode has nobody to set it. The result is a window where clicking and
  dragging work perfectly — those are `mouseDown`/`mouseDragged` — while
  everything riding on passive tracking is silently dead: no hover highlight on
  any control, and **no tooltips**, because AppKit's tooltip manager waits for
  the pointer to come to rest and never learns that it has. One flag, both
  symptoms, and nothing about it shows up in a build, a test, or a reading of
  the code.
- **A destructive control does not rely on a tooltip.** Overwrite carries a
  visible label. It also no longer uses a U-turn arrow, which sat next to undo
  and redo and read as "revert" — close to the opposite of what it does.
- **Use `.tip()`, not `.help()`, for anything outside the toolbar.** SwiftUI's
  `.help()` does not set `NSView.toolTip` for ordinary controls — verified in a
  minimal app containing nothing else, so it is not something about this app's
  `Form` or split view. It compiles, it reads correctly, and no tooltip ever
  appears. Only toolbar items work, because they bridge to real
  `NSToolbarItemViewer`s. `.tip()` attaches the tooltip to an AppKit view whose
  `hitTest` returns nil, so clicks still reach the control beneath.
  **Verify with `NCOVER_DUMP_TOOLTIPS=1 n.cover.app/Contents/MacOS/ncover`**,
  which prints every view carrying a toolTip — this class of bug is invisible to
  the tests and to reading the code.
- **An icon-only control keeps both a `.tip()` and an `.accessibilityLabel`.**
  Dropping the visible word is only an improvement while the meaning is still
  recoverable; an unlabelled glyph with a tooltip that does not appear is worse
  than the word it replaced. And a `systemName` that does not
  resolve renders as **nothing at all** — silently — so new symbols get checked
  against `NSImage(systemSymbolName:)` rather than trusted. The mask shapes use
  symbols that *are* the shapes (`circle.fill`, `app.fill`, `octagon.fill`); a
  chamfer really is an octagon.
- **The backdrop is preview-only and must stay that way.** It exists so alpha
  can be judged against the background the artwork will sit on, which only
  works if it never reaches a renderer. Anything that composites it into
  `renderRaster` or `renderVector` is a data bug, not a feature.
- **A gradient fill has no vector form on a non-circular mask**, and
  `hasVectorForm` says so. An SVG `radialGradient` follows the rim only when
  the rim is a circle; the raster backend's ramp is distance-field based and
  follows any shape. Rather than export a near-miss, the composition refuses
  and names the step. This is the pattern for every future operation: answer
  `hasVectorForm` **honestly**, because claiming a form you have not written
  makes SVG export drop the step silently.
- **`Mask` is a signed distance function, not a shape.** Coverage, the corner
  gradient and the vector clip path are all derived from it, so a new shape is a
  new `signedDistance` case plus its two SVG forms — roughly five lines, with the
  antialiased rim and the gradient following for free. `discTemplate` survives as
  a thin wrapper over `applyMask(.disc,)` **on purpose**: it keeps the tests
  ported from the GTK app pointed at the path they were written against, so if
  generalising ever moves the disc by a pixel, they say so.
- **An outer fill must be clipped to the INVERSE of the mask.** In the raster
  backend the `(1 - coverage)` term says this implicitly. In SVG it has to be
  said out loud, as an even-odd path of canvas-minus-shape. A plain filled rect
  behind the artwork looks almost right and is wrong: it also shows through
  every transparent pixel *inside* the mask.
- **Both backends normalise the gradient to the furthest drawn pixel centre**,
  and a test ties the two together numerically. Change one without the other and
  an exported SVG stops matching the screen.

- **No `.xcodeproj`, on purpose.** SwiftPM builds the binary; the Makefile
  assembles the bundle around it. A generated `pbxproj` is neither readable nor
  diffable. Do not "helpfully" add one.
- **The bundle must be ad-hoc signed.** `make app` runs `codesign --sign -`. An
  unsigned bundle has its WKWebView helper processes refused on recent macOS,
  and the failure mode is quiet: **every SVG renders blank**, with no error.
- **`Raster` is non-premultiplied RGBA8, and that is load-bearing.** The
  inherited rules are defined on exact bytes. `CGBitmapContext` cannot produce
  non-premultiplied output at all, so `Raster.load` draws into a premultiplied
  context and un-premultiplies on the way in. Skip that and every antialiased
  edge darkens the moment it passes through the disc mask. `CGImage` (unlike
  `CGBitmapContext`) *does* accept non-premultiplied alpha, so the write path is
  direct.
- **Pixels are composed by hand, not by Core Graphics.** Nearest-neighbour
  sampling, a one-pixel coverage ramp at the rim, and a gradient normalised to
  the furthest pixel *centre* rather than the abstract corner. Drawing through
  CG would add antialiasing and premultiplication we do not control and the port
  would drift from its specification silently.
- **Two resamplers, and the direction picks which.** `compose` area-averages
  when shrinking and stays nearest-neighbour when enlarging. That split is
  deliberate: the GTK app's rule that *"a colour tool must not invent colours"*
  is right for colour sampling and for pixel-exact enlargement, and was doing
  real harm on the way down — a 2048px raster reaching a 400px canvas kept one
  pixel in twenty-six, which thickened thin rules unevenly and hardened curves.
  Measured against a direct render: 4.04% RMSE before, 1.63% after. **Do not
  "simplify" these back into one path.** The downscale averages in
  *premultiplied* space, too — averaging straight RGBA lets transparent pixels
  drag their meaningless colour in, and every output here is alpha-edged.
- **An SVG is re-rendered at the size it is drawn at, not resampled.** A vector
  source has no native resolution, so resampling one is just an admission that
  it was rendered wrong. `refreshSVGRaster()` re-rasterises on canvas-size
  change, framing change and the end of a zoom — and **never on drag, because
  dragging cannot change the scale**. That is what keeps it off the per-frame
  path while leaving preview and output the same image. With both fixes the
  error against a direct render falls to 1.24%, which is the WebKit-vs-librsvg
  floor; the resampling component is gone.
- **SVG goes through WKWebView, and that has three consequences.** It is
  asynchronous and main-actor bound, so a future batch must serialise through it
  rather than fan out. It renders at the *backing scale* — ask for 1024 and a
  Retina display returns 2048². And it is not librsvg: measured against it on
  the suite's own Figma exports, RMSE ~1% with mean alpha agreeing to four
  decimals, i.e. identical masks and silhouette, different antialiasing. Text-
  heavy SVGs are the untested area, since font resolution differs.
- **The GTK app is the oracle, not a dependency.** `Tests/NCoverKitTests` keeps
  the original Rust test names and expected pixel values. When this app diverges
  on purpose, **delete the test rather than weaken it** — a loosened assertion
  hides a regression, a deleted one records a decision.
- **Overwrite replaces the original in place**, and is one toolbar button from
  Save. `guardOverwrite` refuses anything but a PNG, because we save PNG and
  overwriting a JPEG under its own name would silently re-encode it. Treat any
  change near the write path as touching user data.
- **Output is always PNG.** Not a preference — the disc / label mask needs an
  alpha channel.

## Not here

Machine-local paths, server addresses, credentials and per-box ops belong in a
machine-local `CLAUDE.md`, never in this file. **Treat this repo as public.**
