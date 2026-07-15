#if DEBUG
import AutorotaKit
import Foundation
import Observation

/// Debug-only loader for the "default" sample dataset. A stripped-down sibling
/// of `DemoModeController`: it swaps the app onto a throwaway seeded database
/// (`sample-debug.sqlite`), lifts the license gate so the sample is fully
/// usable, and swaps back + deletes the file on unload — the user's real data
/// is never touched. No guided tour, no step engine.
///
/// The only entry point is `DebugSampleSection`, which is itself `#if DEBUG`,
/// so nothing here ships in release builds.
@MainActor
@Observable
final class SampleDataController {
    /// Whether the sample database is currently swapped in.
    private(set) var isLoaded = false
    /// Set when load/unload hits an FFI error; surfaced as an alert.
    var lastError: String?

    private let syncEngine: AutorotaSyncEngine
    /// Whether iCloud sync was running before we paused it, so unload restores
    /// the prior state rather than unconditionally starting it.
    private var wasSyncRunningBeforeLoad = false

    init(syncEngine: AutorotaSyncEngine) {
        self.syncEngine = syncEngine
    }

    /// Pause sync → switch onto a fresh sample DB → seed it → lift the license
    /// gate → broadcast a full reload so every ViewModel refetches.
    func load() {
        guard !isLoaded else { return }
        do {
            wasSyncRunningBeforeLoad = syncEngine.isRunning
            syncEngine.stop()
            Self.removeSampleDatabaseFiles()
            try autorotaSwitchDb(to: autorotaSampleDBURL().path)
            try autorotaSeedSampleDebugDb(weekStart: weekStart(weeksFromNow: 0))
            LicenseGate.shared.setDemoActive(true)
            isLoaded = true
            // Payload-less post = "reload everything".
            NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        } catch {
            // Entering failed partway — put the app back on the real DB.
            lastError = error.localizedDescription
            try? autorotaSwitchDb(to: (try? autorotaDefaultDBURL().path) ?? "")
            LicenseGate.shared.setDemoActive(false)
            if wasSyncRunningBeforeLoad {
                Task { await syncEngine.start() }
            }
        }
    }

    /// Switch back to the real DB → drop the license gate → restore sync →
    /// broadcast a full reload → delete the throwaway sample file.
    func unload() {
        guard isLoaded else { return }
        do {
            try autorotaSwitchDb(to: autorotaDefaultDBURL().path)
        } catch {
            // The old pool is closed even when connect fails; recovery is an
            // app relaunch (which boots the real DB).
            lastError = error.localizedDescription
        }
        LicenseGate.shared.setDemoActive(false)
        isLoaded = false
        if wasSyncRunningBeforeLoad {
            Task { await syncEngine.start() }
        }
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        Self.removeSampleDatabaseFiles()
    }

    /// Delete the sample database (and WAL/SHM siblings). Called on unload and
    /// from app launch so a mid-sample crash never leaves a stale swapped-in DB.
    static func removeSampleDatabaseFiles() {
        guard let base = try? autorotaSampleDBURL() else { return }
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: base.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
#endif
