import AppKit
import NCoverKit
import SwiftUI

// Walking a folder, and starting from nothing.
//
// Both are about where a composition's *source* comes from, which is the one
// thing the operation list does not describe.

extension AppModel {

    /// Every image beside the one that was opened, in name order, with the
    /// opened file's position in it.
    ///
    /// Name order, not Finder order: a dry run and a real run have to agree,
    /// and "the order the filesystem felt like" is not an order. The same rule
    /// the batch walker uses, for the same reason.
    func scanFolder(of url: URL) {
        let dir = url.deletingLastPathComponent()
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let images = all
            .filter { IMAGE_EXTS.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        folder = images
        folderIndex = images.firstIndex(of: url)
            ?? images.firstIndex { $0.lastPathComponent == url.lastPathComponent }
            ?? 0
    }

    /// Move through the folder. Wraps, because a folder is a ring when you are
    /// looking for one particular cover in it and a dead end is just a stop
    /// you have to notice.
    func step(_ by: Int) {
        guard folder.count > 1 else { return }
        let n = folder.count
        let next = ((folderIndex + by) % n + n) % n
        folderIndex = next
        Task { await load(folder[next], rescan: false) }
    }

    /// Open a folder and start at its first image.
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Browse a folder of artwork"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let probe = dir.appendingPathComponent("x")      // only its parent is used
        scanFolder(of: probe)
        guard let first = folder.first else {
            error = "No PNG, JPEG, WebP or SVG files in that folder."
            return
        }
        folderIndex = 0
        Task { await load(first, rescan: false) }
    }

    /// Start from a blank white square rather than a file.
    ///
    /// White because a record label is white far more often than not, and
    /// Invert reaches black from here in one click. There is no source URL, so
    /// Overwrite is off by construction — there is nothing to overwrite.
    func blankCanvas() {
        let size = doc?.canvas ?? data.canvas
        let raster = NCoverKit.blankCanvas(size)
        adoptSource(Source(raster: raster), url: nil, name: "blank \(size)×\(size)")
    }
}
