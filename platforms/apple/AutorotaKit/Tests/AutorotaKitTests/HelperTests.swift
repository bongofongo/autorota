import XCTest
@testable import AutorotaKit

final class HelperTests: XCTestCase {

    func testCurrentWeekStartReturnsMonday() {
        let dateStr = currentWeekStart()
        // Verify format: YYYY-MM-DD
        let parts = dateStr.split(separator: "-")
        XCTAssertEqual(parts.count, 3, "Expected YYYY-MM-DD format, got \(dateStr)")

        // Verify it's actually a Monday
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = fmt.date(from: dateStr) else {
            XCTFail("Could not parse date: \(dateStr)")
            return
        }
        let weekday = Calendar(identifier: .iso8601).component(.weekday, from: date)
        XCTAssertEqual(weekday, 2, "Expected Monday (weekday=2), got \(weekday)")
    }

    func testWeekStartOffset() {
        let thisWeek = currentWeekStart()
        let nextWeek = weekStart(weeksFromNow: 1)
        let prevWeek = weekStart(weeksFromNow: -1)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        guard let thisDate = fmt.date(from: thisWeek),
              let nextDate = fmt.date(from: nextWeek),
              let prevDate = fmt.date(from: prevWeek) else {
            XCTFail("Could not parse dates")
            return
        }

        let cal = Calendar(identifier: .iso8601)
        let daysToNext = cal.dateComponents([.day], from: thisDate, to: nextDate).day!
        let daysToPrev = cal.dateComponents([.day], from: thisDate, to: prevDate).day!

        XCTAssertEqual(daysToNext, 7, "Next week should be 7 days ahead")
        XCTAssertEqual(daysToPrev, -7, "Previous week should be 7 days behind")
    }

    func testEmptyAvailabilityReturnsEmptyList() {
        let slots = emptyAvailability()
        XCTAssertTrue(slots.isEmpty)
    }
}
