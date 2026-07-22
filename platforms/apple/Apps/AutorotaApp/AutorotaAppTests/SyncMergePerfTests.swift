import XCTest
@testable import AutorotaApp

/// Perf coverage for the three-way sync merge — the hot loop `AutorotaSyncEngine`
/// runs per changed record during an iCloud sync.
///
/// Skipped unless AUTOROTA_PERF=1 so normal unit runs pay nothing. Run via
/// `make sync-merge-perf` (see docs/perf-runbook.md). XCTest (not Swift
/// Testing) because only XCTest has `measure`.
final class SyncMergePerfTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AUTOROTA_PERF"] == "1",
            "perf-only test; set AUTOROTA_PERF=1 to run"
        )
    }

    /// 500 synthetic employee-shaped records, each with conflicting local and
    /// server edits plus untouched fields — the worst realistic merge shape.
    private static let records: [(base: [String: Any], local: [String: Any], server: [String: Any])] = {
        (0..<500).map { i in
            let base: [String: Any] = [
                "first_name": "Employee\(i)",
                "last_name": "Smith",
                "nickname": NSNull(),
                "phone": "555-0\(String(format: "%03d", i))",
                "wage": 12.50,
                "currency": "GBP",
                "max_weekly_hours": 40,
                "availability_json": "{\"mon\":[1,1,1],\"tue\":[1,0,1]}",
            ]
            var local = base
            local["phone"] = "555-9\(String(format: "%03d", i))"
            local["wage"] = 13.00
            var server = base
            server["nickname"] = "Nick\(i)"
            server["max_weekly_hours"] = i % 3 == 0 ? 35 : 40
            return (base, local, server)
        }
    }()

    func testThreeWayMerge500Records() {
        let t0 = "2026-04-28T10:00:00Z"
        let t1 = "2026-04-28T11:00:00Z"
        measure(metrics: [XCTClockMetric()]) {
            for r in Self.records {
                _ = SyncConflictResolver.merge(
                    base: r.base,
                    local: r.local,
                    server: r.server,
                    localLastModified: t1,
                    serverLastModified: t0
                )
            }
        }
    }
}
