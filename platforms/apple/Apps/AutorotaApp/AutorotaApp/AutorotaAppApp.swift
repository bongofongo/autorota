import SwiftUI
import AutorotaKit

@main
struct AutorotaAppApp: App {

    init() {
        do {
            try autorotaInitDb()
        } catch {
            fatalError("Failed to initialise database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        #endif
    }
}
