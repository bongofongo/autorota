import AutorotaKit
import CloudKit
import SwiftUI
import TipKit

@main
struct AutorotaAppApp: App {

    /// True when the process was launched with `--perf-seed-corpus <N>`.
    /// Disables iCloud sync, onboarding, and exchange-rate fetching so the
    /// XCUITest perf target measures a known dataset, not first-launch I/O.
    private static let perfMode: PerfModeConfig? = PerfModeConfig.fromLaunchArgs()

    init() {
        do {
            #if PERF_HELPERS
            if let cfg = Self.perfMode {
                let tmp = NSTemporaryDirectory() + "autorota-perf-\(cfg.employees)-\(cfg.seed).db"
                try? FileManager.default.removeItem(atPath: tmp)
                try autorotaInitDb(at: tmp)
                try seedPerfCorpus(employees: UInt32(cfg.employees), seed: cfg.seed)
            } else {
                try autorotaInitDb()
            }
            #else
            try autorotaInitDb()
            #endif
        } catch {
            fatalError("Failed to initialise database: \(error)")
        }
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
        // Seam for swapping Mock ↔ Live without rebuilding env wiring.
        let backend: LicenseBackend = LiveLicenseBackend()
        _licenseService = State(initialValue: LicenseService(backend: backend))
    }

    private var inPerfMode: Bool {
        #if PERF_HELPERS
        return Self.perfMode != nil
        #else
        return false
        #endif
    }

    @AppStorage("appAppearance") private var appearance: String = AppAppearance.system.rawValue
    @AppStorage("colorBlindnessMode") private var colorBlindnessMode: String = ColorBlindnessMode.none.rawValue
    @State private var exchangeRateService = ExchangeRateService()
    @State private var syncEngine = AutorotaSyncEngine()
    @State private var localeManager = LocaleManager()
    @State private var licenseService: LicenseService
    @State private var showSyncPrompt = false
    @State private var syncCheckComplete = false

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    private var selectedPalette: AccessibilityPalette {
        AccessibilityPalette.palette(for: ColorBlindnessMode(rawValue: colorBlindnessMode) ?? .none)
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
            .environment(localeManager)
            .environment(licenseService)
            .environment(\.locale, localeManager.effectiveLocale)
            .environment(\.accessibilityPalette, selectedPalette)
            .task {
                if inPerfMode {
                    syncCheckComplete = true
                    return
                }
                if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                    await licenseService.refresh()
                }
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
        // Skip sync when running in a test host process.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            syncCheckComplete = true
            return
        }

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

/// Parsed `--perf-seed-corpus <employees> [seed <hex>]` launch arguments. Only
/// honoured in builds that link the `seedPerfCorpus` symbol (XCFramework built
/// with `PERF_HELPERS=1`). Release builds simply ignore the flag because the
/// symbol resolution will fail at compile time on a vanilla XCFramework — this
/// type is wrapped in `#if canImport(...)` style indirectly via the call to
/// `seedPerfCorpus` which exists only in perf-helpers builds.
private struct PerfModeConfig {
    let employees: Int
    let seed: UInt64

    static func fromLaunchArgs() -> PerfModeConfig? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--perf-seed-corpus"),
              idx + 1 < args.count,
              let n = Int(args[idx + 1]), n > 0 else {
            return nil
        }
        var seed: UInt64 = 0xA070_C0FF_EE
        if let sIdx = args.firstIndex(of: "--perf-seed"), sIdx + 1 < args.count,
           let parsed = UInt64(args[sIdx + 1].replacingOccurrences(of: "0x", with: ""), radix: 16) {
            seed = parsed
        }
        return PerfModeConfig(employees: n, seed: seed)
    }
}
