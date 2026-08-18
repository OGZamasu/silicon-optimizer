import SwiftUI

/// Application entry point.
///
/// `MenuBarExtra` is declared first because the menu bar is the app's real home — the window is
/// opened on demand. `LSUIElement` in Info.plist keeps it out of the Dock and Cmd+Tab by default;
/// `MainWindow` promotes the app to a regular activation policy for as long as it is open, so it
/// is reachable there too while it's actually showing something (image generation, downloads).
public struct SiliconOptimizerApp: App {

    @State private var model = AppModel()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Silicon Optimizer", id: MainWindow.identifier) {
            MainWindow()
                .environment(model)
                .task { model.start() }   // idempotent; the menu bar label may have run it first
        }
        .defaultSize(width: 1080, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updates.checkForUpdates() }
                    .disabled(!model.updates.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    model.newConversation()
                    model.selectedTab = .chat
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Unload Model") {
                    Task { await model.unload() }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.loadedModel == nil)
            }
        }
    }
}
