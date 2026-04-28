import XCTest

/// Times week prev/next navigation on a 200-employee corpus. Captures the
/// SwiftUI render + RotaViewModel reload after each tap.
///
/// Relies on `accessibilityIdentifier`s applied in `RotaView.WeekPickerView`:
/// `rota.prevWeek`, `rota.nextWeek`, `rota.weekTitle`.
final class WeekNavigationPerfTests: XCTestCase {

    func testWeekNavigation_200Employees() {
        let app = XCUIApplication()
        app.launchArguments += ["--perf-seed-corpus", "200"]
        app.launch()

        let title = app.staticTexts.matching(identifier: "rota.weekTitle").firstMatch
        XCTAssertTrue(
            title.waitForExistence(timeout: 10),
            "rota.weekTitle never appeared — perf-mode launch arg may not have taken effect"
        )

        let nextWeek = app.buttons["rota.nextWeek"]
        let prevWeek = app.buttons["rota.prevWeek"]
        XCTAssertTrue(nextWeek.exists)
        XCTAssertTrue(prevWeek.exists)

        // Each iteration: bounce forward then back so we land on the same week
        // and don't drift the dataset over many runs.
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(application: app),
            XCTMemoryMetric(application: app),
        ]) {
            nextWeek.tap()
            _ = title.waitForExistence(timeout: 2)
            prevWeek.tap()
            _ = title.waitForExistence(timeout: 2)
        }
    }
}
