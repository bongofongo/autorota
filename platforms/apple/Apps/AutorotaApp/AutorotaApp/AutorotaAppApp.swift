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

    @AppStorage("appAppearance") private var appearance: String = AppAppearance.system.rawValue
    @State private var exchangeRateService = ExchangeRateService()

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(exchangeRateService)
                .task { await exchangeRateService.fetchRates() }
                .preferredColorScheme(selectedAppearance.colorScheme)
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
