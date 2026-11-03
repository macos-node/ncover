import AppKit
import SwiftUI

/// Turns on mouse-moved events for every window.
///
/// `NSWindow.acceptsMouseMovedEvents` defaults to **false**, and a SwiftUI app
/// assembled outside Xcode gets no one setting it. The result is a window where
/// clicking and dragging work perfectly — those are `mouseDown`/`mouseDragged`
/// — while everything that rides on passive tracking is silently dead: no
/// hover highlight on any control, and no tooltips, because AppKit's tooltip
/// manager waits for the pointer to come to rest and never learns that it has.
///
/// One flag, both symptoms. Nothing about it shows up in a build, a test or a
/// reading of the code.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        enableMouseMoved()
        // Windows can arrive after launch, so catch them as they come up too.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.enableMouseMoved() } }
    }

    private func enableMouseMoved() {
        for w in NSApp.windows { w.acceptsMouseMovedEvents = true }
    }
}

@main
struct NCoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("n.cover", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.open() }.keyboardShortcut("o")
                Button("Browse Folder…") { model.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Blank Canvas") { model.blankCanvas() }
                    .keyboardShortcut("n")
                Divider()
                // Walking the folder has a menu home as well as the arrow
                // keys, because a shortcut nobody can find is a shortcut
                // nobody uses — and the arrows only work with the canvas
                // focused, which is not discoverable either.
                Button("Previous Image") { model.step(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.folderCount < 2)
                Button("Next Image") { model.step(1) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(model.folderCount < 2)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandMenu("Colour") {
                Button("Pick from Screen…") { model.pickFromScreen() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Show Colours…") { model.showColorPanel() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Copy Colour") { model.copyCurrent() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(model.current == nil)
                Button("Import Palette…") { model.importPalette() }
                Divider()
                Button("Batch…") { model.showBatch = true }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save As…") { model.saveAs() }
                    .keyboardShortcut("s")
                    .disabled(model.preview == nil)
                Button("Overwrite Original") { model.overwrite() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canOverwrite)
            }
        }
    }
}
