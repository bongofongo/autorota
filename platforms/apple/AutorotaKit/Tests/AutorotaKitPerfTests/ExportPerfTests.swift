import XCTest
import AutorotaKit

/// Export pipeline through the FFI: CSV serialization and PDF rendering of the
/// seeded corpus week at 200 employees.
final class ExportPerfTests: XCTestCase {

    override func setUpWithError() throws {
        try PerfHarness.freshSeededDb(employees: 200, label: "export")
    }

    func testExportWeekCsv200Employees() {
        measure(metrics: [XCTClockMetric()]) {
            _ = try! exportWeekSchedule(
                weekStart: PerfHarness.corpusWeek,
                config: PerfHarness.csvConfig()
            )
        }
    }

    func testExportPreviewPdf200Employees() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = try! exportPreviewFull(config: PerfHarness.pdfConfig())
        }
    }
}
