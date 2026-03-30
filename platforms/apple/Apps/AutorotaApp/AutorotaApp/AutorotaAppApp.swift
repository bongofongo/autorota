import AutorotaKit
import CloudKit
import SwiftUI

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
    @State private var syncEngine = AutorotaSyncEngine()
    @State private var showSyncPrompt = false
    @State private var syncCheckComplete = false

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if syncCheckComplete {
                    ContentView()
                } else {
                    ProgressView("Loading...")
                }
            }
            .sheet(isPresented: $showSyncPrompt) {
                SyncPromptView(
                    onAccept: {
                        showSyncPrompt = false
                        Task { await syncEngine.start() }
                        do {
                            try setSyncMetadata(key: "sync_initialized", value: "true")
                        } catch {}
                    },
                    onDecline: {
                        showSyncPrompt = false
                        do {
                            try setSyncMetadata(key: "sync_disabled", value: "true")
                        } catch {}
                    }
                )
                .interactiveDismissDisabled()
            }
            .environment(exchangeRateService)
            .environment(syncEngine)
            .task {
                await exchangeRateService.fetchRates()
                await checkFirstLaunchSync()
            }
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

    private func checkFirstLaunchSync() async {
        do {
            let initialized = try getSyncMetadata(key: "sync_initialized")
            let disabled = try getSyncMetadata(key: "sync_disabled")

            if initialized != nil {
                await syncEngine.start()
                syncCheckComplete = true
                return
            }

            if disabled != nil {
                syncCheckComplete = true
                return
            }

            // First launch: check if cloud data exists
            let localCount = try countEmployees()
            let hasCloudData = await checkCloudZoneExists()

            if hasCloudData && localCount == 0 {
                syncCheckComplete = true
                showSyncPrompt = true
            } else {
                await syncEngine.start()
                try setSyncMetadata(key: "sync_initialized", value: "true")
                syncCheckComplete = true
            }
        } catch {
            syncCheckComplete = true
        }
    }

    private func checkCloudZoneExists() async -> Bool {
        let container = CKContainer(identifier: "iCloud.com.toadmountain.autorota")
        let database = container.privateCloudDatabase
        do {
            let zoneID = SyncRecordMapper.zoneID
            _ = try await database.recordZone(for: zoneID)
            return true
        } catch {
            return false
        }
    }
}
