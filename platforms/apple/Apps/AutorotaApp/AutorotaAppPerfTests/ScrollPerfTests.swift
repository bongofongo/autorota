import XCTest

// Scroll signpost metrics exist on iOS only — this whole suite is
// iOS-simulator territory (swift-perf-ios); the macOS test build still
// compiles this target, so it must be gated out there.
#if os(iOS)

/// Scroll smoothness on the 500-employee list — hitches are the jank users
/// actually feel. `XCTOSSignpostMetric.scrollDecelerationMetric` reports hitch
/// time ratio (ms of hitch per second of scrolling) for the fling; the
/// dragging metric covers the finger-down phase.
///
/// Relies on the `employees.list` identifier (EmployeeListView). On iPhone the
/// native TabView renders the tab bar, so the tab is addressed by its localized
/// title ("Employees" — perf sims run English); `tab.employees` identifiers
/// only exist in the iPad narrow-window FloatingTabBar.
final class ScrollPerfTests: XCTestCase {

    func testEmployeeListScroll_500Employees() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--perf-seed-corpus", "500"]
        app.launch()

        let employeesTab = app.tabBars.buttons["Employees"]
        XCTAssertTrue(
            employeesTab.waitForExistence(timeout: 10),
            "Employees tab never appeared — is it in the default tab config?"
        )
        employeesTab.tap()

        let list = app.collectionViews["employees.list"].firstMatch
        XCTAssertTrue(
            list.waitForExistence(timeout: 10),
            "employees.list never appeared after tapping the Employees tab"
        )

        measure(metrics: [
            XCTOSSignpostMetric.scrollDecelerationMetric,
            XCTOSSignpostMetric.scrollDraggingMetric,
        ]) {
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .fast)
            list.swipeDown(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
    }
}

#endif
