import SwiftUI

@main
struct NCoverApp: App {
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
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save as PNG…") { model.saveAs() }
                    .keyboardShortcut("s")
                    .disabled(model.preview == nil)
                Button("Overwrite Original") { model.overwrite() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canOverwrite)
            }
        }
    }
}
