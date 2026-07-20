import AutorotaKit
import CloudKit
import OSLog
import SwiftUI

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
        let dbSignpost = PerfSignposts.poster.beginInterval("dbInit")
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
        PerfSignposts.poster.endInterval("dbInit", dbSignpost)
        _dbInitOutcome = State(initialValue: initOutcome)

        ExportSettingsMigration.run()

        // Demo mode never survives a relaunch: boot always inits the real DB
        // above, so a stale demo file is just dead weight (or a crash relic).
        DemoModeController.removeDemoDatabaseFiles()
        #if DEBUG
        // Same for the debug sample database.
        SampleDataController.removeSampleDatabaseFiles()
        #endif

        // Seam for swapping Mock ↔ Live without rebuilding env wiring.
        let backend: LicenseBackend = LiveLicenseBackend()
        _licenseService = State(initialValue: LicenseService(backend: backend))

        // Boot animation: only for users who have already completed
        // onboarding (i.e. picked a plan) — a first boot goes straight to
        // the onboarding flow instead. Captured once here so the flag can't
        // flip mid-boot (checkFirstLaunchSync may set the UserDefaults key
        // a couple of seconds in when sync hydrates existing data).
        // (Never in the perf harness: LaunchPerfTests measures real boot
        // time, and the perf branch above pre-sets hasCompletedOnboarding.)
        #if PERF_HELPERS
        let perfHarnessActive = Self.perfMode != nil
        #else
        let perfHarnessActive = false
        #endif
        // Snapshot once (same rationale as playBootAnimation below):
        // checkFirstLaunchSync may flip the UserDefaults key mid-boot.
        let onboardedSnapshot = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        onboardedAtBoot = onboardedSnapshot
        _playBootAnimation = State(initialValue:
            !perfHarnessActive
                && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                && onboardedSnapshot
        )

        let engine = AutorotaSyncEngine()
        _syncEngine = State(initialValue: engine)
        _demoController = State(
            initialValue: DemoModeController(environment: .live(syncEngine: engine))
        )
        #if DEBUG
        _sampleController = State(initialValue: SampleDataController(syncEngine: engine))
        #endif
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
    #if DEBUG
    @State private var sampleController: SampleDataController
    #endif
    @State private var spotlightModel = TutorialSpotlightModel()
    @State private var syncPrompt = SyncPromptCoordinator()
    @State private var syncCheckComplete = false
    /// Snapshot of `hasCompletedOnboarding` at boot. For onboarded users the
    /// first-launch sync question is already answered locally, so the paint
    /// gate is released immediately and `checkFirstLaunchSync` runs behind it.
    private let onboardedAtBoot: Bool
    @State private var dbInitOutcome: DBInitOutcome
    /// Whether this boot shows `LoadingScreenView` (set once in `init`).
    @State private var playBootAnimation: Bool
    @State private var bootAnimationDone = false

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    private var selectedPalette: AccessibilityPalette {
        AccessibilityPalette.palette(for: ColorBlindnessMode(rawValue: colorBlindnessMode) ?? .none)
    }

    /// The app content mounts only when data loading is done AND (when the
    /// boot animation plays) the animation has finished — the user never
    /// sees a half-loaded rota.
    private var appIsReady: Bool {
        syncCheckComplete && (bootAnimationDone || !playBootAnimation)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch dbInitOutcome {
                case .failed(let message):
                    DatabaseRecoveryView(errorMessage: message)
                case .ok, .recovered:
                    ZStack {
                        if appIsReady {
                            ContentView()
                                .transition(.opacity)
                        } else if playBootAnimation {
                            LoadingScreenView {
                                PerfSignposts.poster.emitEvent("bootAnimationDone")
                                bootAnimationDone = true
                            }
                            .transition(.opacity)
                        } else {
                            // First boot (no plan chosen yet): onboarding
                            // handles the wait, keep the plain spinner.
                            ProgressView("Loading...")
                        }
                    }
                    .animation(.easeInOut(duration: 0.35), value: appIsReady)
                }
            }
            .environment(exchangeRateService)
            .environment(syncEngine)
            .environment(localeManager)
            .environment(licenseService)
            .environment(demoController)
            #if DEBUG
            .environment(sampleController)
            #endif
            .environment(spotlightModel)
            .environment(syncPrompt)
            .environment(\.locale, localeManager.effectiveLocale)
            .environment(\.accessibilityPalette, selectedPalette)
            .task {
                // Kick off the first week's data fetch immediately — it runs
                // while the boot animation (or perf-mode launch) proceeds, and
                // RotaViewModel's cold load adopts the result. Runs in perf
                // mode too so the harness measures the production path.
                RotaLoadPrefetcher.shared.start(
                    service: GatedAutorotaService(),
                    weekStart: currentWeekStart()
                )
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
                PerfSignposts.poster.emitEvent("licenseRefreshed")
                // Rates are display-only and the service loads a cached copy
                // in init — never let this network fetch (no timeout) gate
                // first paint.
                Task { await exchangeRateService.fetchRates() }
                // Onboarded users have nothing to wait for: the sync check
                // only decides whether to show onboarding for fresh installs
                // with existing cloud data. Release the paint gate now and
                // let the (idempotent) check run behind the content. License
                // refresh above must stay awaited — ContentView shows
                // onboarding on `license.state == .unset`.
                if onboardedAtBoot {
                    syncCheckComplete = true
                    PerfSignposts.poster.emitEvent("syncCheckComplete")
                }
                await checkFirstLaunchSync()
                if !onboardedAtBoot {
                    PerfSignposts.poster.emitEvent("syncCheckComplete")
                }
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
                // The user chose "start fresh", but the iCloud data still
                // exists — keep the plan page's start-from-iCloud escape
                // hatch alive (row only, no popup).
                if await checkCloudZone() == .exists {
                    wireSyncPromptActions()
                    syncPrompt.markCloudDataAvailable()
                }
                return
            }

            // First launch.
            let localCount = (try? countEmployees()) ?? 0
            let zoneState = await checkCloudZone()

            switch zoneState {
            case .exists where localCount == 0:
                // Existing iCloud data: hand the decision to the tier-pick
                // page (the only place the prompt may appear — never over
                // a demo run). Defer `sync_initialized` until the user
                // chooses, otherwise a decline would orphan iCloud data.
                wireSyncPromptActions()
                syncCheckComplete = true
                syncPrompt.markPending()
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

    private func wireSyncPromptActions() {
        syncPrompt.onAccept = { [syncEngine] in
            Task { await syncEngine.start() }
            // Takes precedence over any earlier `sync_disabled` — the
            // initialized check runs first on subsequent launches.
            try? setSyncMetadata(key: "sync_initialized", value: "true")
        }
        syncPrompt.onDecline = {
            try? setSyncMetadata(key: "sync_disabled", value: "true")
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
