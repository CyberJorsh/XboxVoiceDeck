import SwiftUI

@main
struct XboxVoiceDeckApp: App {
    @StateObject private var model = DeckModel()
    var body: some Scene {
        WindowGroup { DeckView(model: model) }
            .commands {
                CommandGroup(replacing: .newItem) { }
            }
    }
}
