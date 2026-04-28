import XCTest

/// Times the first render of the rota grid against a populated 200-employee
/// dataset. The launch arg ensures the DB is seeded before the UI appears, so
/// `waitForExistence` measures pure render time, not first-load fetching.
final class RotaRenderPerfTests: XCTestCase {

    func testFirstRotaRender_200Employees() {
        let app = XCUIApplication()
        app.launchArguments += ["--perf-seed-corpus", "200"]

        measure(metrics: [
            XCTClockMetric(),
            XCTMemoryMetric(application: app),
        ]) {
            app.launch()
            let title = app.staticTexts.matching(identifier: "rota.weekTitle").firstMatch
            _ = title.waitForExistence(timeout: 10)
            app.terminate()
        }
    }

    /// First render at 500 employees — exposes whether grid building scales.
    func testFirstRotaRender_500Employees() {
        let app = XCUIApplication()
        app.launchArguments += ["--perf-seed-corpus", "500"]

        measure(metrics: [
            XCTClockMetric(),
            XCTMemoryMetric(application: app),
        ]) {
            app.launch()
            let title = app.staticTexts.matching(identifier: "rota.weekTitle").firstMatch
            _ = title.waitForExistence(timeout: 15)
            app.terminate()
        }
    }
}
