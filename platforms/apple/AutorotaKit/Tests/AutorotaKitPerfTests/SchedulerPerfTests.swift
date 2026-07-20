import XCTest
import AutorotaKit

/// Scheduler runtime through the FFI. Mirrors the criterion `scheduler` bench
/// (same corpus generator, same seed discipline), so the gap between these
/// numbers and `make bench-scheduler` is the FFI + SQLite round-trip overhead.
///
/// Each `measure` iteration re-runs the full pipeline: `runSchedule` deletes
/// proposed assignments, re-materialises shifts from templates, and schedules
/// the week from scratch.
final class SchedulerPerfTests: XCTestCase {

    private func measureSchedule(employees: UInt32) throws {
        try PerfHarness.freshSeededDb(employees: employees, label: "sched")
        let week = PerfHarness.nextSchedulableWeek()
        measure(metrics: [XCTClockMetric()]) {
            _ = try! runSchedule(weekStart: week)
        }
    }

    func testRunSchedule50Employees() throws {
        try measureSchedule(employees: 50)
    }

    func testRunSchedule200Employees() throws {
        try measureSchedule(employees: 200)
    }

    func testRunSchedule500Employees() throws {
        try measureSchedule(employees: 500)
    }
}
