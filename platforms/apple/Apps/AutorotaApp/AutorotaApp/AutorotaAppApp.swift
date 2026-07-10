import AutorotaKit
import CloudKit
import SwiftUI
import TipKit

/// Result of the App's two-pass database init. `failed` short-circuits the
/// scene to show `DatabaseRecoveryView`; `recovered` lets the app boot
/// against a fresh DB (the user's prior local-only data is in a quarantined
/// `db.corrupt-<ts>.sqlite` sibling file).
enum DBInitOutcome {
    case ok
    case recovered(quarantinedTo: String, originalError: String)
    case failed(message: String)
}

@main
struct AutorotaAppApp: App {

    /// True when the process was launched with `--perf-seed-corpus <N>`.
    /// Disables iCloud sync, onboarding, and exchange-rate fetching so the
    /// XCUITest perf target measures a known dataset, not first-launch I/O.
    private static let perfMode: PerfModeConfig? = PerfModeConfig.fromLaunchArgs()

    init() {
        let initOutcome: DBInitOutcome
        do {
            #if PERF_HELPERS
            if let cfg = Self.perfMode {
                let tmp = NSTemporaryDirectory() + "autorota-perf-\(cfg.employees)-\(cfg.seed).db"
                try? FileManager.default.removeItem(atPath: tmp)
                try autorotaInitDb(at: tmp)
                try seedPerfCorpus(employees: UInt32(cfg.employees), seed: cfg.seed)
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                initOutcome = .ok
            } else {
                initOutcome = try Self.initDatabaseWithRecovery()
            }
            #else
            initOutcome = try Self.initDatabaseWithRecovery()
            #endif
        } catch {
            initOutcome = .failed(message: "\(error)")
        }
        _dbInitOutcome = State(initialValue: initOutcome)

        ExportSettingsMigration.run()

        // Demo mode never survives a relaunch: boot always inits the real DB
        // above, so a stale demo file is just dead weight (or a crash relic).
        DemoModeController.removeDemoDatabaseFiles()

        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
        // Seam for swapping Mock ↔ Live without rebuilding env wiring.
        let backend: LicenseBackend = LiveLicenseBackend()
        _licenseService = State(initialValue: LicenseService(backend: backend))

        let engine = AutorotaSyncEngine()
        _syncEngine = State(initialValue: engine)
        _demoController = State(
            initialValue: DemoModeController(environment: .live(syncEngine: engine))
        )
    }

    /// Two-pass DB init: try once, on failure quarantine the file and try
    /// again from a clean slate. Returns `.ok` on first-try success,
    /// `.recovered` if the second attempt succeeded (caller should warn the
    /// user about lost local data), and throws if both attempts failed.
    private static func initDatabaseWithRecovery() throws -> DBInitOutcome {
        do {
            try autorotaInitDb()
            return .ok
        } catch {
            // First attempt failed — likely a corrupt file or schema drift
            // that the migration runner couldn't reconcile. Quarantine and
            // retry once before surfacing an unrecoverable error.
            let dbURL = try autorotaDefaultDBURL()
            let quarantined = try autorotaQuarantineDatabase(at: dbURL)
            try autorotaInitDb()
            return .recovered(quarantinedTo: quarantined.path, originalError: "\(error)")
        }
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
    @State private var syncEngine: AutorotaSyncEngine
    @State private var localeManager = LocaleManager()
    @State private var licenseService: LicenseService
    @State private var demoController: DemoModeController
    @State private var showSyncPrompt = false
    @State private var syncCheckComplete = false
    @State private var dbInitOutcome: DBInitOutcome

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    private var selectedPalette: AccessibilityPalette {
        AccessibilityPalette.palette(for: ColorBlindnessMode(rawValue: colorBlindnessMode) ?? .none)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch dbInitOutcome {
                case .failed(let message):
                    DatabaseRecoveryView(errorMessage: message)
                case .ok, .recovered:
                    if syncCheckComplete {
                        ContentView()
                    } else {
                        ProgressView("Loading...")
                    }
                }
            }
            .sheet(isPresented: $showSyncPrompt) {
                SyncPromptView(
                    onAccept: {
                        showSyncPrompt = false
                        // User opted into existing iCloud data — slide deck
                        // is moot. Mark onboarding done and route the next
                        // OnboardingView render straight to TierPickView.
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        UserDefaults.standard.set(true, forKey: "pendingOnboardingTierOnly")
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
            .environment(demoController)
            .environment(\.locale, localeManager.effectiveLocale)
            .environment(\.accessibilityPalette, selectedPalette)
            .task {
                if inPerfMode {
                    // Perf harness needs an immediately-usable license too —
                    // ContentView gates onboarding on `state == .unset`.
                    licenseService.forceState(.purchased(tier: .localManager))
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
                // If sync hydrates real data on this device but
                // `hasCompletedOnboarding` is missing (fresh OS install with
                // an iCloud restore that didn't carry UserDefaults), skip
                // the slide deck. The user clearly knows the app.
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if let n = try? countEmployees(), n > 0 {
                        await MainActor.run {
                            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        }
                    }
                }
                return
            }

            if disabled != nil {
                syncCheckComplete = true
                return
            }

            // First launch.
            let localCount = (try? countEmployees()) ?? 0
            let zoneState = await checkCloudZone()

            switch zoneState {
            case .exists where localCount == 0:
                // Show the prompt; defer `sync_initialized` until the user
                // chooses, otherwise a decline would orphan iCloud data.
                syncCheckComplete = true
                showSyncPrompt = true
            case .exists, .missing:
                await syncEngine.start()
                try setSyncMetadata(key: "sync_initialized", value: "true")
                syncCheckComplete = true
            case .unknown:
                // Transient CloudKit error (network, throttling, timeout).
                // Don't persist `sync_initialized` — next launch retries.
                syncCheckComplete = true
            }
        } catch {
            syncCheckComplete = true
        }
    }

    private enum CloudZoneState { case exists, missing, unknown }

    private func checkCloudZone() async -> CloudZoneState {
        let container = CKContainer(identifier: "iCloud.com.toadmountain.autorota")
        let database = container.privateCloudDatabase
        let zoneID = SyncRecordMapper.zoneID
        do {
            _ = try await withTimeout(seconds: 5) {
                try await database.recordZone(for: zoneID)
            }
            return .exists
        } catch let ck as CKError where ck.code == .zoneNotFound || ck.code == .unknownItem {
            return .missing
        } catch {
            return .unknown
        }
    }
}

/// Bounded wait. Throws `TimeoutError` on expiry; cancels the operation task.
struct TimeoutError: Error {}

func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        guard let result = try await group.next() else {
            throw TimeoutError()
        }
        group.cancelAll()
        return result
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
