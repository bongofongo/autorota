import XCTest
import AutorotaKit

/// Shift-history read path through the FFI — backs the Shift History and
/// analytics pages. Scales with weeks × employees, so this is the query most
/// likely to degrade as real data accumulates.
final class HistoryPerfTests: XCTestCase {

    func testListAllShiftHistory500Employees() throws {
        try PerfHarness.freshSeededDb(employees: 500, label: "history")
        // Fill a scheduled week on top of the corpus's pinned assignments so
        // the history query has a realistic row count to chew on.
        _ = try runSchedule(weekStart: PerfHarness.nextSchedulableWeek())
        measure(metrics: [XCTClockMetric()]) {
            _ = try! listAllShiftHistory(startDate: nil, endDate: nil)
        }
    }
}
