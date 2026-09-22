import AppKit
import Foundation
import WebKit

/// SVG -> pixels, via WebKit.
///
/// Core Graphics has no public SVG rasteriser, so this is the one place the
/// macOS build cannot simply mirror what the GTK app does with librsvg.
/// Measured against librsvg on the suite's own Figma exports (masks, outlined
/// lettering): RMSE ~1%, and mean alpha agreeing to four decimals — the
/// silhouette and masks are identical and the difference is antialiasing.
///
/// Two things to know before using it anywhere else:
///
///  1. **It is asynchronous and main-actor bound.** Fine for opening one file.
///     A future batch over a discography must serialise through here rather
///     than fan out, which is a real design constraint, not a detail.
///  2. **It renders at the backing scale.** A 1024 request on a Retina display
///     returns 2048². We ask for the logical size and report what we got, so
///     the caller decides whether that is free resolution or a resize.
@MainActor
public final class SVGRasterizer: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let side: Int
    private var done: ((Result<Raster, Error>) -> Void)?
    private static var live: [SVGRasterizer] = []

    public init(side: Int) {
        self.side = side
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: side, height: side), configuration: cfg)
        super.init()
        // Transparent backing. Without this every snapshot arrives composited on
        // white, and the alpha corners the disc mask depends on are gone.
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
    }

    public static func rasterize(_ url: URL, side: Int) async throws -> Raster {
        let r = SVGRasterizer(side: side)
        live.append(r)                      // keep alive across the navigation
        defer { live.removeAll { $0 === r } }
        return try await r.run(url)
    }

    private func run(_ url: URL) async throws -> Raster {
        let text = try String(contentsOf: url, encoding: .utf8)
        let html = """
        <!doctype html><meta charset="utf-8">
        <style>html,body{margin:0;padding:0;background:transparent}
        svg{width:\(side)px;height:\(side)px;display:block}</style>
        \(text)
        """
        return try await withCheckedThrowingContinuation { cont in
            self.done = { cont.resume(with: $0) }
            web.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        }
    }

    public func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        // One runloop turn so layout and any mask resolution settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.snap() }
    }

    public func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        done?(.failure(e)); done = nil
    }

    private func snap() {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x: 0, y: 0, width: side, height: side)
        cfg.afterScreenUpdates = true
        web.takeSnapshot(with: cfg) { [weak self] img, err in
            guard let self else { return }
            if let err { self.done?(.failure(err)); self.done = nil; return }
            guard let img,
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.done?(.failure(ImageError.cannotDecode("svg"))); self.done = nil; return
            }
            self.done?(Result { try Raster(cgImage: cg) })
            self.done = nil
        }
    }
}
