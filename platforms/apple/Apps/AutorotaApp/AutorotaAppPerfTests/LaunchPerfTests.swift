import XCTest

/// Cold-launch perf for the AutorotaApp.
///
/// Each measure block re-launches the app process from scratch; XCTest
/// terminates and re-spawns the host between iterations of an
/// `XCTApplicationLaunchMetric`, so we cannot reuse a single XCUIApplication.
///
/// `--perf-seed-corpus 200` triggers `AutorotaAppApp` to open an ephemeral DB
/// and seed a deterministic 200-employee dataset before showing the UI. That
/// turns "cold launch" into a steady-state, reproducible measurement instead
/// of a first-launch onboarding flow.
final class LaunchPerfTests: XCTestCase {

    /// True cold launch: process spawned fresh, all init paths run, UI shown.
    func testColdLaunch_200Employees() {
        let app = XCUIApplication()
        app.launchArguments += ["--perf-seed-corpus", "200"]
        measure(metrics: [
            XCTApplicationLaunchMetric(),
            XCTMemoryMetric(application: app),
        ]) {
            app.launch()
        }
    }

    /// Warm launch: time to first responsive state. Useful baseline for
    /// resume-from-background timings even though XCUITest reports it via
    /// the same launch metric.
    func testWarmLaunch_200Employees() {
        let app = XCUIApplication()
        app.launchArguments += ["--perf-seed-corpus", "200"]
        measure(metrics: [
            XCTApplicationLaunchMetric(waitUntilResponsive: true),
        ]) {
            app.launch()
        }
    }

    /// Sanity: same scenario at 50 employees so we can spot whether a
    /// regression is data-volume-driven or universal.
    func testColdLaunch_50Employees() {
        let app = XCUIApplication()
        app.launchArguments += ["--perf-seed-corpus", "50"]
        measure(metrics: [
            XCTApplicationLaunchMetric(),
            XCTMemoryMetric(application: app),
        ]) {
            app.launch()
        }
    }
}
