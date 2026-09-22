# Changelog

All notable changes to the macOS n.cover. Versions follow [semver](https://semver.org).

This is a sibling of [`xjmzx/ncover`](https://github.com/xjmzx/ncover), the
GTK4 app for Linux — same name and purpose, no shared code, free to diverge.
Their version numbers are independent.

## [Unreleased]

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

[Unreleased]: https://github.com/macos-node/ncover/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/macos-node/ncover/releases/tag/v0.1.0
