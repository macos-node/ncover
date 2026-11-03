# n.cover (macOS) — notes for Claude

SwiftUI app for building cover / label artwork. Swift 6 · SwiftUI · Core
Graphics · WebKit. See [`README.md`](README.md) for the feature tour.

## This is not the GTK app, and not a port of it

[`xjmzx/ncover`](https://github.com/xjmzx/ncover) is the GTK4/Linux app. This is
a **separate app with the same name and purpose**, written natively for macOS.
They share no code, by decision: the two are expected to develop differently,
and a shared core is exactly the coupling that would prevent that.

It has **two halves, and they are not the same shape.** Colour (picking,
history, palettes) is values and files; artwork is a composition and two
renderers. The window has a sidebar because of that, not for decoration — and
the only place they meet is that a pick off the canvas is a pick, and a palette
can be made from the open document.

It is also **not part of the Tauri `n.*` suite** — no webview shell, no React,
no Nostr surface, no keyring, no database. It is adjacent to the suite: the same
brand and colour language, and (once batch lands) a reader of what `ndisc`
publishes. Reaching for a suite pattern — `tauri build`, `make dev`, design
tokens as CSS variables — will waste time here.

## Build and verify

```
make app     # build n.cover.app
make dmg     # disk image, verified by mounting it
make run     # build and launch
make test    # the rule tests (95: 68 swift-testing, 27 XCTest)
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

- **The icon master is uncropped, and must stay that way.** `icon.svg` is the
  Figma export shared with the GTK sibling: a 1024 canvas with the art in an
  824 square, which is Apple's icon grid. The **Linux** build crops that margin
  away to fill 89% of the tile, the way Yaru's icons do — doing the same here
  would make n.cover oversized next to every other app in the Dock. `make icon`
  therefore renders the master as-is.
- **`ncover.icns` is committed**, so `make app` needs no `rsvg-convert`. Run
  `make icon` after changing the art. Check the result with alpha intact —
  `sips` flattens onto white, which hides a lost transparent margin completely.

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
- **Use `.tip()`, not `.help()`, for anything outside the toolbar, and do not
  try to simplify it back.** Getting a tooltip to appear here took three
  mechanisms, and the two that failed both looked correct:
  1. SwiftUI's `.help()` never sets `NSView.toolTip` for ordinary controls —
     verified in a minimal app containing nothing else, so it is not this app's
     `Form` or split view. Only toolbar items work, because they bridge to real
     `NSToolbarItemViewer`s. That is why `.help()` survives in the toolbar.
  2. Setting `NSView.toolTip` on an overlay *did* attach it — the views were
     present, correctly sized and not hidden — and still nothing appeared.
     `NSToolTipManager` hit-tests its way to the view, and the overlay returned
     nil from `hitTest` so that clicks could reach the control beneath. **The
     thing that made it harmless made it invisible.**

  `.tip()` therefore owns the whole mechanism: `.onHover` to trigger, a 0.5s
  delay so it does not flash while the pointer passes through, and a borderless
  panel to present — a panel rather than a SwiftUI overlay, because a tooltip
  inside a `Form` would be clipped by it. Its only remaining dependency is
  `.onHover` firing, which needs the window flag above.

  Two presentation details that were wrong first time: `NSTextField.sizeToFit()`
  **ignores** `preferredMaxLayoutWidth`, so a long tip came out as one line
  spanning the window — constrain the width and ask `sizeThatFits` for the
  height. And keep the canvas tip to one line, because that one fires whenever
  the pointer rests anywhere on the artwork.

  Trace hover with `NCOVER_TRACE_HOVER=1`. It writes to **stderr on purpose**:
  `print` is fully buffered when redirected to a file, and a version using it
  came back empty while tooltips were working — a diagnostic that lies is worse
  than no diagnostic.
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
- **A mask is inscribed in a `MaskRegion`, not in the canvas.** `.canvas` is
  the inherited behaviour and the surprising one — a source that does not reach
  the canvas edges is only clipped at its corners. `.artwork` inscribes it in
  the square bounding whatever is *currently drawn*, which is computed from the
  canvas **at that point in the operation list**, not from the source and not
  from the placement. The vector backend has to ask the raster fold for the
  same answer, which is why it renders the prefix of the list; export is not a
  hot path and correctness beats inferring bounds from geometry.
  With an off-centre region the four canvas corners stop being equivalent, so
  the gradient normalisation takes the largest rather than assuming symmetry.
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

## Traps in the colour half

- **`.clr` is not decoration — it is the reason the colour half is worth
  having on a Mac.** A Mac already has colour lists: the Colours panel's
  palette tab is a list of them, and `~/Library/Colors` is where they live. An
  app that reads `.gpl` but not `.clr` is asking its user to convert their own
  files to talk to it. Keep `installColorList` and keep the "import a macOS
  colour list" menu: between them they are the difference between a palette
  feature and a palette *silo*.
- **`NSColorList` is a dictionary, so two swatches under one key become one.**
  `writeColorList` suffixes a duplicate rather than losing it, and an unnamed
  swatch is keyed by its own hex — which the reader then drops again, because
  a key that *is* the colour carries no information and would come back as a
  name nobody typed.
- **The colour panel must not feed the history.** `NSColorPanel`'s action
  fires continuously while you drag across the wheel; routing that into
  `remember` fills all 32 slots with the path the cursor took and buries every
  colour you actually chose. The panel moves `current` only, and a Keep button
  says when a panel colour is a pick. The same reasoning is why the backdrop
  has its own screen-picker entry point: a viewing condition is not a pick.
- **Every `ColorPicker` in the app opens the same shared `NSColorPanel`**, so
  the palettes are attached app-wide (`syncPalettesToColorPanel`, called once
  the window is up and again whenever the palettes themselves change — not on
  every colour picked, which `touch` also fires on). Attaching only when the
  Colour view opened the panel left them missing from exactly the wells that
  wanted them. Attaching a name that is already attached replaces it; a
  **renamed or deleted** palette has to be detached by hand, which is what
  `attachedLists` is for.
- **`ColorPanelBridge` is target/action, and that is not a style choice.**
  `NSColorPanel` is one of the oldest classes in AppKit and has never grown a
  publisher. One shared instance, because the panel is a singleton and two
  listeners would double every change.
- **The store's JSON is shared with the GTK app**, deliberately: `Swatch`
  encodes flat (`r`,`g`,`b`,`name`) and `Palette` is `{name, colors}`, which is
  what that app writes. Changing either shape breaks interchange in a way no
  test here would notice unless it is the one that pins the shape — which is
  why `testJSONIsTheSharedShape` exists.
- **Every field in `ColorData` is optional on the way in.** The file is read
  by two apps and by older versions of this one; a missing key is normal. And
  a *corrupt* file starts empty rather than refusing to launch, without
  overwriting the broken one — there is nothing the user could do at launch,
  and the file is still there to look at.
- **Palette identity is the name.** The pinned list stores names and an export
  is called after one, so `ColorData.add` keeps them unique and `rename`
  *refuses* a collision rather than silently suffixing: renaming to "Brand 2"
  when the user typed "Brand" is worse than doing nothing.
- **A palette from a raster is a summary and must be called one.** A PNG does
  not declare its colours. `dominantColors` answers "what is most of this
  picture made of", and its representative is the **mean of each bin**, not the
  bin centre, so every colour it returns is one the image contains. For an SVG
  the app reads the *declared* fills and stops instead — that is a different
  claim and a stronger one, and the UI says which it is making.
- **`inspectSVG` refuses external entities**, and should keep doing so. It
  parses a file someone opened; an SVG that can fetch a URL or read a local
  file while being inspected is a vulnerability, not a feature.
- **Ties in `inspectSVG`'s output are broken by name**, where the GTK app's
  `HashMap` left them arbitrary. That is the one place the two deliberately
  differ, and only where the GTK side had no answer.

## Traps in type

- **`layoutText` is the only place a glyph's position is decided**, and both
  backends read out of it — the raster one draws those glyphs, the vector one
  turns the same ones into paths. That is why they cannot drift. Measured
  against librsvg: 98.8% of pixels byte-identical, and at every one-pixel
  offset the unshifted comparison is the minimum by roughly a factor of two,
  which is what *aligned* looks like as opposed to *similar*.
- **Type exports as outlines, never as `<text font-family="…">`.** The font
  reference is smaller and stays editable, and it renders as a different
  picture — or not at all — on a machine without the font. This app already
  refuses to export a near-miss; type is where a near-miss is most visible.
  The cost is a bigger file and no re-editing in Illustrator, and that is the
  right trade for artwork.
- **Glyphs go through Core Graphics, and that is the one deliberate exception
  to "pixels are composed by hand".** Type *must* be antialiased; hinting and
  subpixel positioning are precisely what a text renderer is for, and
  hand-rasterising outlines to avoid CG would be reimplementing it badly. The
  layer comes back un-premultiplied, the same as `Raster.load`, and is
  composited in straight alpha — skip that and every letter's edge darkens the
  moment it passes through the disc mask.
- **`setShouldSmoothFonts(false)`.** Subpixel antialiasing bakes the
  background's colour into the edge pixels, and this layer's background is
  nothing at all, so it produces coloured fringes on transparency.
- **Sizes and positions are fractions of the canvas, not points.** Changing
  the output size then scales the type with it, which is what the rest of the
  app already does with framing. Points would leave the same lettering
  stranded in the corner of a 1000px square.
- **The block is measured first-ascent to last-descent**, not as *n* line
  heights. Any other way leaves a single line off-centre by the font's own
  internal leading, which reads as a mistake because it is one.
- **Core Text never fails to give you a font**, it substitutes — so
  `fontIsAvailable` has to ask, comparing both the PostScript and the family
  name (a family resolving to a face is a match, not a substitution).
- **Glyph paths use `fill-rule="nonzero"`.** That is what a counter is wound
  for: the hole in an "o" goes the other way round. Even-odd would also punch
  a hole wherever two letters overlap.
- **The blank canvas carries a vector source**, and that is what made type
  worth having. Without it a composition built from nothing was refused for
  "the source is not an SVG" even though every step in it had a vector form.
  A white square *is* expressible as a white square; saying otherwise was
  never honest, it was only never asked.

## Traps in batch

- **The runner is `@MainActor` throughout, and must stay that way.** An SVG
  source goes through `WKWebView`, which is asynchronous and main-actor bound,
  so a batch has to **serialise** through the rasteriser. Fanning out over a
  `TaskGroup` is the obvious optimisation and it does not work.
- **`guardBatch` refuses three arrangements, not two**: output equal to the
  source, output inside it, and the source inside the output. The third
  overwrites nothing, which is why it is easy to argue for — and it still has
  a run write over the folder its own inputs sit in.
- **`batchDest` builds from string components on purpose.**
  `URL(fileURLWithPath:)` resolves a *relative* path against the process's
  current directory, so building one from a relpath silently drags the cwd
  into every output path. A test caught this; keep it.
- **A preview must show its failures.** A contact sheet that quietly omits the
  files that would fail is a preview that lies about what the run will do.
- **Each result row carries its reason.** "31 failed" is unactionable and
  sends you guessing at the tool from the outside.
- **ndisc's manifest is at `~/.local/share/ndisc-suite/published.json` on
  macOS too**, not Application Support. That is ndisc's own decision, made so
  every app in the suite resolves it identically; this app follows it rather
  than being idiomatic alone. `libraryRoot` is optional in the v2 shape, so a
  missing one falls back to what the releases share — and releases with only
  `/` in common are refused, because mirroring against the root of the disk is
  not mirroring.

## Releasing

- **`make dmg` mounts the image it just wrote and verifies the app inside
  it.** Not theatre: a bundle whose ad-hoc signature did not survive the copy
  renders every SVG blank, with no error, and a release is the worst place to
  learn that. `ditto`, not `cp -R`, for the same reason.
- **The workflow refuses a tag whose version disagrees with `Info.plist`.**
  The two are bumped by different hands — `make version` writes the plist,
  `git tag` names the release — and a release whose app reports a different
  version from its own filename is the kind of thing nobody notices until
  somebody files a bug against the wrong build.

## Not here

Machine-local paths, server addresses, credentials and per-box ops belong in a
machine-local `CLAUDE.md`, never in this file. **Treat this repo as public.**
