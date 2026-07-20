import Foundation
import AutorotaKit

/// Shared fixture for FFI perf tests.
///
/// These tests measure real Rust work through the FFI, so the XCFramework must
/// be built in release mode with perf helpers: `make kit-perf-xcframework`.
/// If the test target fails to *link* with undefined `..._seed_perf_corpus`
/// symbols, that build step was skipped.
///
/// `initDb` uses a process-wide OnceLock, so the first fixture initializes and
/// every later one swaps the pool with `switchDb`.
enum PerfHarness {
    static let seed: UInt64 = 0xC0FFEE

    /// Monday of the rota week that `generate_corpus` builds (fixed in
    /// crates/autorota-core/src/testutil/corpus.rs).
    static let corpusWeek = "2026-04-20"

    /// Rota id `seed_corpus_into_pool` creates in a fresh database.
    static let corpusRotaId: Int64 = 1

    private static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutorotaKitPerfTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var dbCounter = 0

    /// Open a fresh database seeded with a deterministic corpus. The path is
    /// unique per call — reseeding an already-seeded database violates UNIQUE
    /// constraints (roles.name).
    static func freshSeededDb(employees: UInt32, label: String) throws {
        dbCounter += 1
        let path = tempDir
            .appendingPathComponent("\(label)-\(employees)-\(dbCounter).db").path
        do {
            try initDb(dbPath: path)
        } catch {
            // Pool already initialized (by an earlier fixture) — swap instead.
            try switchDb(dbPath: path)
        }
        try seedPerfCorpus(employees: employees, seed: seed)
    }

    /// First Monday strictly after today — `runSchedule` refuses current and
    /// past weeks, so the corpus week itself cannot be scheduled.
    static func nextSchedulableWeek() -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        let monday = cal.nextDate(
            after: cal.startOfDay(for: Date()),
            matching: DateComponents(weekday: 2),
            matchingPolicy: .nextTime
        )!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: monday)
    }

    /// Baseline CSV export config (staff schedule, employee-by-weekday).
    static func csvConfig() -> FfiExportConfig {
        FfiExportConfig(
            layout: "employee_by_weekday",
            format: "csv",
            profile: "staff_schedule",
            showShiftName: true,
            showTimes: true,
            showRole: true,
            pdfTemplate: nil,
            roleSections: nil,
            rowContent: nil
        )
    }

    /// Baseline PDF export config (weekly grid, manager report).
    static func pdfConfig() -> FfiExportConfig {
        FfiExportConfig(
            layout: "employee_by_weekday",
            format: "pdf",
            profile: "manager_report",
            showShiftName: true,
            showTimes: true,
            showRole: true,
            pdfTemplate: "weekly_grid",
            roleSections: nil,
            rowContent: nil
        )
    }
}
