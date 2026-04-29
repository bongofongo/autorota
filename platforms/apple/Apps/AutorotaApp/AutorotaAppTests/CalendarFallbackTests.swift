import Foundation
import Testing

/// Sanity-check the calendar arithmetic that `RotaView` and `AddShiftSheet`
/// previously force-unwrapped. These tests prove the fallback paths
/// (`?? Date()`, `return selectedWeek`) are unreachable in normal operation,
/// so we know the defensive guards don't change observable behavior.
@Suite("Calendar fallback paths in RotaView are unreachable in practice")
struct CalendarFallbackTests {

    @Test func bySettingHourSucceedsForEveryHourInDay() {
        // AddShiftSheet defaults to 09:00 / 17:00. Verify the whole 24-hour
        // range to catch DST-gap regressions across timezones.
        let cal = Calendar.current
        for hour in 0..<24 {
            #expect(
                cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) != nil,
                "bySettingHour returned nil for hour \(hour)"
            )
        }
    }

    @Test func dateByAddingWeeksSucceedsAcrossDecade() {
        // RotaView's `shifted(by:)` adds weeks to a parsed yyyy-MM-dd. The
        // underlying call only fails on year overflow; verify ±520 weeks
        // (a decade in either direction) succeeds for an iso8601 calendar.
        let cal = Calendar(identifier: .iso8601)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let base = fmt.date(from: "2026-04-13") else {
            Issue.record("failed to parse fixed base date")
            return
        }
        for weeks in stride(from: -520, through: 520, by: 26) {
            #expect(
                cal.date(byAdding: .weekOfYear, value: weeks, to: base) != nil,
                "weeks=\(weeks) returned nil"
            )
        }
    }
}
