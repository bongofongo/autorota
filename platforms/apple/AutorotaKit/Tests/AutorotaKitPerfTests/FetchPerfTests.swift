import XCTest
import AutorotaKit

/// Big-dataset read paths through the FFI at 500 employees — the queries the
/// service layer hits on every screen load.
final class FetchPerfTests: XCTestCase {

    override func setUpWithError() throws {
        try PerfHarness.freshSeededDb(employees: 500, label: "fetch")
    }

    func testGetWeekSchedule500Employees() {
        measure(metrics: [XCTClockMetric()]) {
            _ = try! getWeekSchedule(weekStart: PerfHarness.corpusWeek)
        }
    }

    func testListEmployees500Employees() {
        // Memory metric: 500 FfiEmployee structs cross the FFI per call — the
        // allocation cost lands on every Employees-tab load.
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = try! listEmployees()
        }
    }
}
