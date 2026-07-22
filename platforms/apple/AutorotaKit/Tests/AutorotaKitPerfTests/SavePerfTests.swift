import XCTest
import AutorotaKit

/// Save-snapshot pipeline through the FFI: snapshot creation and diff-vs-previous
/// on the seeded corpus rota at 200 employees.
final class SavePerfTests: XCTestCase {

    override func setUpWithError() throws {
        try PerfHarness.freshSeededDb(employees: 200, label: "save")
    }

    func testCreateSave200Employees() {
        // Storage metric: every save writes a snapshot — excessive logical
        // writes show up as battery drain and I/O stalls on device.
        measure(metrics: [XCTClockMetric(), XCTStorageMetric()]) {
            _ = try! createSave(rotaId: PerfHarness.corpusRotaId)
        }
    }

    func testDiffSaveVsPrevious200Employees() throws {
        // Two snapshots so the diff has a previous to compare against; the
        // measured call is a pure read.
        _ = try createSave(rotaId: PerfHarness.corpusRotaId)
        let saveId = try createSave(rotaId: PerfHarness.corpusRotaId)
        measure(metrics: [XCTClockMetric()]) {
            _ = try! diffSaveVsPrevious(saveId: saveId)
        }
    }
}
