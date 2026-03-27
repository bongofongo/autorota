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
                #if os(macOS)
                .frame(minWidth: 800, minHeight: 500)
                #endif
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
