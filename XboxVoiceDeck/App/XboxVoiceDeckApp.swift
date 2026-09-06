import SwiftUI

@main
struct XboxVoiceDeckApp: App {
    @StateObject private var model: DeckModel
    init() {
        #if DEBUG
        _model = StateObject(wrappedValue: UITestFixture.makeModel(environment: ProcessInfo.processInfo.environment) ?? DeckModel())
        #else
        _model = StateObject(wrappedValue: DeckModel())
        #endif
    }
    var body: some Scene {
        Window("Xbox Voice Deck", id: "deck") { DeckView(model: model) }
            .defaultSize(width: 900, height: 680)
            .commands { DeckWindowCommands() }
    }
}

private struct DeckWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Show Xbox Voice Deck") { openWindow(id: "deck") }
                .keyboardShortcut("n", modifiers: .command)
        }
    }
}
