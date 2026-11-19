# n.cover (macOS) — notes for Claude

SwiftUI app for building cover / label artwork. Swift 6 · SwiftUI · Core
Graphics · WebKit. See [`README.md`](README.md) for the feature tour.

## This is not the GTK app, and not a port of it

[`xjmzx/ncover`](https://github.com/xjmzx/ncover) is the GTK4/Linux app. This is
a **separate app with the same name and purpose**, written natively for macOS.
They share no code, by decision: the two are expected to develop differently,
and a shared core is exactly the coupling that would prevent that.

Features still cross, as behaviour and decisions rather than source.
[`docs/gtk-parity-plan.md`](docs/gtk-parity-plan.md) is the plan for what comes
*from* there — the cover review loop: JPEG in the write path, the Cap / Square /
Pad jobs, ndisc's Export list as a scope, and the review grid. Its mirror,
`docs/macos-parity-plan.md` in that repo, is what went the other way. Read the
plan before adding to batch, and keep its "Not yet on either side" list honest:
building one of those here first is a divergence, not progress.

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
make test    # the rule tests (176: 147 swift-testing, 29 XCTest; two are opt-in)
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
- **Overwrite replaces the original in place, in its own format**, and is one
  toolbar button from Save. A PNG stays a PNG; a JPEG stays a JPEG at quality
  92. It used to refuse anything but a PNG, which was right while PNG was all
  the write layer could encode — re-encoding a JPEG under its own name changes
  the file's kind behind the user's back. `guardOverwrite` now carries the rule
  that replaced it, which is about alpha, not extension. Treat any change near
  the write path as touching user data: the target is usually a cover inside
  someone's music library.
- **A JPEG's dropped alpha is BLACK, not white, and nothing says so.**
  `cgImage()` carries non-premultiplied alpha, ImageIO's JPEG encoder drops
  that channel and keeps the RGB bytes, and `Raster.load` zeroes RGB wherever
  alpha is 0. So writing a masked render as a JPEG stores its transparent
  corners as black, with no error from any layer. This is the JPEG equivalent
  of answering `hasVectorForm` dishonestly, and it is why `write(to:as:alpha:)`
  makes the caller choose:
  - `JPEGAlpha.refuse` — Overwrite. A transparent result is refused rather
    than flattened onto a colour nobody chose.
  - `JPEGAlpha.discard` — batch's keep-format jobs. A JPEG source had no alpha
    to lose, so the channel is simply not written (`opaqueCGImage` re-reads the
    fourth byte as padding: no copy, nothing composited, nothing invented).

  Both are deliberate and the GTK sibling has the same split. Do not
  "simplify" them into one policy, and do not give `alpha:` a permissive
  default.
- **`replaceFile` writes beside the original and renames over it.** An encoder
  that fails midway through the target leaves a half-written cover in a music
  library; a sibling temp plus `replaceItemAt` cannot. A test stages the
  failure (a refused JPEG) and checks the original is byte-equal with no temp
  left behind.
- **Cover / Fit output is always PNG.** Not a preference — the disc / label
  mask needs an alpha channel. Cap, Square and Pad are the exception: they
  tidy a file rather than frame one, so they keep its format. **Save offers
  PNG, JPEG, and SVG where the document can** — the JPEG there is a deliberate
  departure from the GTK sibling, whose Save is PNG-only and whose backlog
  still calls this "its own change". The alpha rule is the same one Overwrite
  uses: a render with transparency is refused, not flattened, so a disc mask
  cannot be written as black.
- **`imageSize(of:)` reads the header, and that is a measured claim.** On this
  Mac's library: 37 covers, 0.023 s from headers (0.63 ms each) against 1.526 s
  decoding them, 65× — with every answer equal to the decode's. A survey that
  decided "already square" or "within the cap" by decoding would be unusable at
  library scale. The timing test is off unless `NCOVER_LIBRARY` names a real
  folder, like the GTK side's ignored real-catalogue tests.

## Places, and what was deliberately not ported

- **The window carries the version** (`navigationSubtitle`), read from the
  bundle rather than written out — the GTK sibling puts it in its title bar
  and the rest of the suite in a chip. A version string typed twice is a
  version string that disagrees with itself.
- **`docs/gtk-parity-plan.md` has a table of where the two layouts differ.**
  They are the same features in each platform's idiom, not a backlog: GTK has
  a header switch and a compact control column, this app a sidebar and
  grouped `Form` sections. What is shared is the vocabulary — the same jobs,
  the same scopes in the same order, the same counts in the same words — so
  someone who knows one can use the other. Read that table before "fixing" a
  difference.

- **Batch is a place in the sidebar, not a sheet**, and that was forced by
  the review grid: the route the grid builds — pick a cover, fix it in the
  editor, come back — closed the sheet every time, and a modal you keep
  closing is not where a job you are working through belongs. The sidebar is
  this app's own idiom for what GTK does with a header switch, so `AppSection`
  gained `.batch` and `.help` rather than this app growing a page switcher of
  its own.
- **`AppModel.section` holds the current place**, not a `@State` in
  `ContentView`, because Batch has to be able to send you to the editor.
- **Overwrite asks.** It wrote immediately until phase E, which was wrong for
  the one control that replaces a file this app did not create, usually inside
  a music library. The question says what it will *write* — the original's
  size, the result's size, and "JPEG at quality 92" — not only what it will
  destroy. `Cancel` takes the cancel role so Esc and ⌘. are the safe way out,
  and `destructive` is what makes the other button red **on the system's**
  terms rather than a colour picked here.
- **Both column toggles live in the toolbar, not in the inspector.** The rail
  toggle used to sit inside the inspector, so hiding the inspector hid the
  only way to get the rail back. Both are remembered (`ColorData.rail`,
  `.inspector`).
- **`ColorData.tips` is the GTK sibling's key name on purpose.** Its
  `AppData.tips` means the same thing and began the same way — a
  getting-started panel, before it became a page — and defaults TRUE there and
  here. The two apps write their own files (`n.cover/data.json` versus
  `ncover/data.json`), but the *shape* is deliberately shared, and a key that
  means one thing in one app and something else in the other is how that stops
  being true. A test pins the default coming back true from a file that has
  never heard of the key.
- **The monochrome accent treatment was NOT ported, deliberately.** GTK 0.4.0
  inverts the chosen segment of a switch (light on dark) and makes its green
  buttons light-on-dark, taking the colours from its theme. On macOS a
  segmented control is tinted with the **system accent colour**, which the user
  chooses in System Settings and every other app on their Mac honours.
  Repainting it here would not be parity with the sibling's intent — which was
  to match its own platform — it would be the opposite. The one place GTK
  keeps colour is Overwrite staying red, and that is exactly what the
  `destructive` button role does here.

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
- **The size slider is logarithmic, and that is not a flourish.** The useful
  range is a hundredfold — a 2% credit line to a letterform at 200% bleeding
  off every edge — and on a linear slider the first tenth of the travel covers
  everything from invisible to a caption. Equal travel is equal *ratio*, and
  the 0.2 default landing exactly halfway is the check that the range is
  centred on the sizes people set rather than on a round number. The readout
  shows the resulting **points** beside the percentage, because that is what a
  size is known by even when the model is a ratio.
- **The range runs past 100% on purpose.** Type larger than the square it is
  cropped by is a deliberate thing to draw, so it is not clamped to "fits".
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

## Template and background

- **`.template` is a placement that draws nothing**, and the ghost on the
  canvas is drawn by `CanvasView`, not by a renderer. That is deliberate and
  it is the same category as the grid and the snap guides: the rule "the
  preview is what a PNG export writes" is about the **file**, and a guide that
  reached `renderRaster` would be a data bug exactly like the backdrop would.
- **It carries a placement so the gestures keep working.** `Composition.placement`
  and `setPlacement` handle either case, and `setSourceIsTemplate` converts
  one into the other in place — so toggling it does not lose where you put the
  source, and setting a placement does not silently un-template it.
- **A raster template does not block SVG output**, and this is the point of
  the whole thing. `vectorRefusal` asks whether the source is *drawn* before
  it cares what format it is: a scan used as a guide contributes nothing to
  the output, so it has no say in whether the output can be vector. A raster
  source that is actually placed still refuses, and a test pins both halves.
- **`.background` composites UNDER what is already drawn**, whatever its
  position in the list, which is why it can sit late enough for a mask to clip
  it without painting over the artwork. In SVG that means the `<rect>` is
  **prepended** to the body — document order is paint order, and appending it
  would cover everything.
- **The background is written to the file; the backdrop is not.** Two things
  that look alike in the inspector and are opposites: one is part of the
  picture, the other is a viewing condition. Keep the labels and tooltips
  saying so.

## Traps in batch

- **The runner is `@MainActor` throughout, and must stay that way.** An SVG
  source goes through `WKWebView`, which is asynchronous and main-actor bound,
  so a batch has to **serialise** through the rasteriser. Fanning out over a
  `TaskGroup` is the obvious optimisation and it does not work.
- **`guardBatch` refuses three arrangements, not two**: output equal to the
  source, output inside it, and the source inside the output. The third
  overwrites nothing, which is why it is easy to argue for — and it still has
  a run write over the folder its own inputs sit in.
- **Output names are planned for the whole run, not file by file.** `batchDest`
  answers for one file and cannot see a collision; `planDests` plans the lot.
  Every output is a PNG named after its source, so a release holding both
  `cover.jpg` and `cover.png` planned one `cover.png` and the second write
  replaced the first — with both reported as written, and a dry run unable to
  show it, because each file renders perfectly well on its own. Colliding
  sources now keep their extension in the name (`cover-jpg.png`); everything
  else keeps the plain name, so a library with no collisions is unchanged.
  **The run must index the plan positionally** (`zip`, not a lookup by
  relative path) — a lookup by name is exactly what cannot tell two sources
  apart here.
- **`batchDest` builds from string components on purpose.**
  `URL(fileURLWithPath:)` resolves a *relative* path against the process's
  current directory, so building one from a relpath silently drags the cwd
  into every output path. A test caught this; keep it.
- **The survey and the run must agree.** `surveyBatch` and `findImages` do
  the same de-duplication in the same order, because the number on the button
  is a promise about how many of someone's files are about to be touched. A
  test ties the two counts together; keep it.
- **Surveying decodes nothing**, which is what makes it cheap enough to keep
  current while the filter is being typed — and a filter whose effect you
  cannot see is a guess. It still runs off the main actor, because a library
  of a few thousand releases is a few thousand `contentsOfDirectory` calls.
- **The manifest's artist and title are carried into the scope** (`names`).
  Throwing them away and showing folder paths would be a much worse answer to
  "what will this touch" — and the folder often does not match the record, as
  a compilation filed under Various Artists shows.
- **The grid replaced the four auto-samples and the twelve-thumbnail
  preview**, and it replaced them because it is both of those done properly:
  always current, every file rather than the first few, and under a
  keep-format job **only the files the run would change** — so its length is
  the Run button's count. `sampleKey` still gathers every input into one
  value, and now drives the survey and the plan together, so no change can
  leave a stale count or a stale picture beside the controls that no longer
  made it. (The old rule it embodied still holds: a preview you have to press
  is one you can forget to press, and forgetting it is how a folder of covers
  comes out as discs.)
- **The grid and the Files list are one array under one selection** (`plan`,
  `selected`). That is why their numbers agree and why selecting in either
  moves the other. Never give either view a list of its own.
- **Thumbnails render lazily, per cell, through the run's own `renderOne`.**
  A plan is thousands of files and a whole-library Cover scope is ~2,400
  full-canvas renders, so nothing renders until a cell appears; the cell's
  `.task` goes away with it when it scrolls off. At most `thumbWorkers` run at
  once — an SVG serialises through the main actor regardless, because
  WKWebView.
- **A thumbnail carries the generation it was rendered under.** `planGeneration`
  is bumped on every rebuild and a finished render is dropped if it no longer
  matches: drawing it would put the *previous* recipe's picture under the
  current one's label, which is worse than an empty cell.
- **`sizeChangeInWords` takes the job rather than inferring from the two
  sizes.** A padded image that is then capped comes out *smaller* than it went
  in (1000 × 500 → padded to 1000² → capped to 400²), and a reader working
  from the sizes alone calls that a crop — the opposite of what happened. A
  test caught this; it is the kind of thing only a test catches.
- **The runner outlives the sheet.** `ContentView` owns it, not `BatchView`,
  because the intended route through the review loop *closes* the sheet: pick
  a cover in the grid, fix it in the editor, come back. A `@StateObject` in
  the sheet threw away the scope, the list and the output folder every time.
  The recount on the way back in is `AppModel.overwriteCount` inside the
  `.task` id — a count, not a flag, so two overwrites are two events.
- **The disc is off by default in batch.** `Recipe` has said "the disc is an
  option, not the point — resizing a folder of covers is a job on its own"
  since the beginning, and the batch sheet defaulted it on, which is the one
  place that sentence mattered. If a default here ever contradicts the type's
  own documentation again, the documentation is the one that is right.
- **A preview must show its failures.** A contact sheet that quietly omits the
  files that would fail is a preview that lies about what the run will do.
- **Each result row carries its reason.** "31 failed" is unactionable and
  sends you guessing at the tool from the outside.
- **The keep-format jobs are not framings, and must not become `Framing`
  cases.** Here `Framing` is the *editor's* placement intent — `resetFraming()`
  turns it into a `Placement` — and the canvas picker and the batch picker read
  the same type, so a `Framing.cap` would appear in the editor's control. The
  GTK sibling has no such sharing, which is why `Framing::Cap` is right there
  and wrong here. `BatchJob` is the batch-only type: `.frame(Framing)` for
  Cover and Fit, then `.cap`, `.square`, `.pad(PadFill)`, with `keepsFile` as
  the predicate the planner and the write path read.
- **A keep-format job must write nothing for a file it would not change.**
  That is the property that makes a run over a whole library reviewable rather
  than a leap, and it is also what keeps a JPEG from being re-encoded for no
  reason. `jobRender` answers `nil`, `batchRender` passes it on, and the runner
  reports `Outcome.skipped`. **Treating that `nil` as a failure would be
  reporting a lie** — nothing went wrong, nothing happened.
- **One arithmetic decides "would this change", and both callers ask it.**
  `jobResultSize` is asked by the survey (through `wouldChange`, from a header
  read) and by the render (from the decoded pixels). "Run (245 of 2,377 to
  shrink)" is a promise about how many of someone's files are about to be
  rewritten; two code paths answering it separately is how it stops being one.
  A test writes real files and checks the two answers agree per file.
- **Square and Pad leave an already-square image alone, however large.**
  Squaring is what they do; capping is Cap's job. This looks like an omission
  and is not: a Square run over a library of 2,000 square covers must write
  nothing at all.
- **A disc and a keep-format job are refused together** (`jobRefusal`), not
  silently reconciled. The file is a JPEG as often as not, and a JPEG has
  nowhere to put a disc's transparent corners. The toggle is disabled and
  `blocker` refuses, from the same function, so the two cannot disagree.
- **`planDests`' disambiguation is for the PNG family only.** A keep-format
  job's outputs are its sources' own names, so `cover.jpg` and `cover.png` in
  one release are already distinct — the clash that `planDests` exists for
  cannot arise there. The clash *check* still runs over both: it costs a
  dictionary, and it is what would notice if that reasoning ever stopped being
  true.
- **`areaResample` and `compose`'s downscale share one accumulator**
  (`areaAverage`). The premultiplied average and the divide-by-the-whole-box
  rule are subtle enough that a second copy would drift; a keep-format job
  shrinks a rectangle to a rectangle, which is the same filter with its own
  per-axis ratio and no placement.
- **Pad's edge fill averages in premultiplied space and keeps the mean
  alpha**, which is what gives a transparent logo transparent bars rather than
  grey ones. Each bar reads the row or column it sits against, so the two can
  differ — a sky at the top and a floor at the bottom.
- **`BatchScope.images(under:needle:)` is the one place a root becomes
  files.** `findImages(in:)` (the run, the samples) and `surveyBatch` (the
  counts) both go through it, which is what keeps the button's number true.
  Do not walk a root anywhere else.
- **A list's "only this cover file" lives in the scope, not in a filter after
  the walk.** `BatchScope.only` maps a root to the single file it contributes,
  because ndisc's Export list names the exact cover its flags are about and a
  release folder usually holds back and inlay art too. A post-walk filter
  would let the survey and the run select different files, which is precisely
  the thing the survey exists to rule out.
- **Under a list the job is part of the scope.** `BatchScope.list(_:job:)`
  takes the job because the job picks the lines — Cap takes `ncover:cap`,
  Square and Pad `ncover:square` — so a Cap run and a Square run over one
  export are *different scopes*. The job is therefore in `sampleKey`; take it
  out and the survey will show the previous job's lines.
- **A line whose first column is not an absolute folder is skipped and
  counted, by line number.** ndisc writes "artist — title" there when a
  release has no folder at all, so this is a normal thing to meet, not a
  corrupt file. A list that quietly shrinks is worse than one that complains.
- **The second column is a cover only when it is one**: an image path *inside*
  that line's folder. A hand-made list may put a note there, and a path
  outside the folder must never be touched whatever it says.
- **`leftOut` counts in ndisc's own action order**, so the most upstream work
  reads first ("112 need a new source · 24 to review"). Those lines belong to
  a person or to ndisc; naming them is how a Cap run over 24 of 2,000 covers
  stops looking like a mistake.
- **A framing takes a list whole.** `.frame` has no `listAction`, so every
  line is in — "run Cover over these three releases" is a sensible request,
  not an oversight.
- **ndisc's manifest is at `~/.local/share/ndisc-suite/published.json` on
  macOS too**, not Application Support. That is ndisc's own decision, made so
  every app in the suite resolves it identically; this app follows it rather
  than being idiomatic alone. `libraryRoot` is optional in the v2 shape, so a
  missing one falls back to what the releases share — and releases with only
  `/` in common are refused, because mirroring against the root of the disk is
  not mirroring.

## Installing

- **`make install` goes to `/Applications`**, which is where a Mac keeps
  applications. It defaulted to `~/Applications` for a while, carried over
  from the Linux side of the suite where `PREFIX=$HOME/.local` is the
  convention — which is the exact reflex this file warns about at the top,
  committed in the Makefile. `/Applications` is group-writable by `admin` on
  a stock Mac, so it needs no sudo; the target checks and says what to do
  instead when it is not writable.
- **Two copies under one bundle identifier is the thing to avoid.** Launch
  Services will happily open either, and Finder will show whichever icon it
  cached — the stale-build trap. `install` warns when a copy is left in the
  other location, and `uninstall` unregisters what it removes.
- **`ditto`, not `cp -R`**, here as well as for the disk image: it is the copy
  documented to carry a bundle's signature, and an unsigned bundle renders
  every SVG blank without saying so.

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
