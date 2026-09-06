import SwiftUI

@main
struct XboxVoiceDeckApp: App {
    @StateObject private var model: DeckModel
    init() {
        #if DEBUG
        _model = StateObject(wrappedValue: UITestFixture.makeModel(arguments: ProcessInfo.processInfo.arguments) ?? DeckModel())
        #else
        _model = StateObject(wrappedValue: DeckModel())
        #endif
    }
    var body: some Scene {
        WindowGroup { DeckView(model: model) }
            .commands {
                CommandGroup(replacing: .newItem) { }
            }
    }
}
