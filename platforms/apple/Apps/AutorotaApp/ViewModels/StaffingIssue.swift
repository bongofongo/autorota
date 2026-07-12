import Foundation
import AutorotaKit

/// A staffing gap on a single shift, computed live from the loaded schedule
/// (not the scheduler's generation-time warnings, which go stale after manual
/// edits and don't survive restarts).
///
/// `.warning` — the shift is below its minimum headcount, or a per-role
/// minimum is unmet. `.note` — the minimum is met but there's still room
/// before the maximum.
struct StaffingIssue: Identifiable, Equatable {
    enum Severity {
        case warning, note
    }

    let shiftId: Int64
    let severity: Severity
    let weekday: String
    /// ISO date of the shift, for day-of-month labels.
    let date: String
    let startTime: String
    let endTime: String
    /// Role whose minimum fell short, or nil for an overall headcount issue.
    let role: String?
    let filled: Int
    /// Minimum headcount for warnings; maximum for notes.
    let needed: Int

    var id: String {
        "\(shiftId)-\(role ?? "*")-\(severity == .warning ? "w" : "n")"
    }
}

/// One-shot request to scroll the rota grid to a shift and open its editor
/// sheet. The token makes consecutive requests for the same shift distinct so
/// the grid's `onChange` re-fires.
struct ShiftFocusRequest: Equatable {
    let shiftId: Int64
    let token: UUID
}

extension StaffingIssue {
    /// Warnings before notes; within each severity, weekday order then start time.
    static func displaySort(_ issues: [StaffingIssue]) -> [StaffingIssue] {
        let dayOrder = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        func dayIndex(_ d: String) -> Int { dayOrder.firstIndex(of: d) ?? dayOrder.count }
        return issues.sorted { a, b in
            if a.severity != b.severity { return a.severity == .warning }
            if a.weekday != b.weekday { return dayIndex(a.weekday) < dayIndex(b.weekday) }
            if a.startTime != b.startTime { return a.startTime < b.startTime }
            // Overall headcount rows before per-role rows on the same shift.
            return (a.role ?? "") < (b.role ?? "")
        }
    }
}
