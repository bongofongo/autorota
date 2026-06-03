import Foundation
import AutorotaKit

/// Why an assigned or candidate employee may not be able to work a shift.
///
/// Hard reasons (everything except `.maybe`) render a ⚠️ warning; `.maybe` is a
/// soft amber hint. These are computed app-side from data already loaded over
/// FFI — see `RotaViewModel.conflict(employeeId:shift:)`.
enum ConflictReason: Equatable {
    /// Already booked on another shift that overlaps in time. Carries a label
    /// for the clashing window, e.g. "12:00–16:00".
    case overlap(String)
    /// Weekly availability template resolves to `No` over the shift window.
    case noAvailability
    /// A date-specific *exception* override marks them unavailable that day.
    case exception
    /// A manual date-specific override resolves to `No` for the shift window.
    case dateOverride
    /// Soft hint: the window resolves to `Maybe`.
    case maybe

    /// True for everything except the soft `.maybe` hint.
    var isHard: Bool {
        if case .maybe = self { return false }
        return true
    }

    /// Short human reason shown next to the warning glyph.
    var label: String {
        switch self {
        case .overlap(let when): return "Already on \(when)"
        case .noAvailability:    return "No availability"
        case .exception:         return "Unavailable (exception)"
        case .dateOverride:      return "Unavailable (date override)"
        case .maybe:             return "Maybe available"
        }
    }
}

/// Worst-state lattice mirroring Rust `AvailabilityState` ordering
/// (`No` < `Maybe` < `Yes`); the *worst* state over a window is the minimum.
enum AvailWorst: Int {
    case no = 0
    case maybe = 1
    case yes = 2
}

/// Pure conflict-detection helpers. Mirrors the scheduler's eligibility logic
/// (`crates/autorota-core/src/models/availability.rs` `for_window`,
/// `scheduler/mod.rs` `has_time_overlap`) so the UI flags exactly what the
/// scheduler would reject.
enum ShiftConflict {

    // MARK: Time parsing

    /// Hour component (0–23) of an "HH:mm" string; nil if malformed. Matches
    /// Rust `Shift::start_hour/end_hour`, which truncate minutes.
    static func hour(of hhmm: String) -> Int? {
        Int(hhmm.prefix(2))
    }

    /// Minutes since midnight for an "HH:mm" string; nil if malformed.
    static func minutes(of hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    /// Map an availability state string to the worst-state lattice. Unknown /
    /// missing → `.maybe`, mirroring Rust `Availability::get`'s default.
    static func parseState(_ s: String) -> AvailWorst {
        switch s {
        case "No":  return .no
        case "Yes": return .yes
        default:    return .maybe
        }
    }

    // MARK: Availability window

    /// Hours covered by a shift window, handling overnight shifts exactly like
    /// Rust `for_window` (`end <= start` wraps midnight).
    static func windowHours(startHour: Int, endHour: Int) -> [Int] {
        if endHour > startHour {
            return Array(startHour..<endHour)
        } else {
            return Array(startHour..<24) + Array(0..<endHour)
        }
    }

    /// Worst availability state across a window, given a per-hour lookup that
    /// defaults to `.maybe`. Empty window → `.no` (mirrors Rust `unwrap_or(No)`).
    static func worst(startHour: Int, endHour: Int, stateAt: (Int) -> AvailWorst) -> AvailWorst {
        let hours = windowHours(startHour: startHour, endHour: endHour)
        guard let m = hours.map(stateAt).min(by: { $0.rawValue < $1.rawValue }) else { return .no }
        return m
    }

    // MARK: Conflict resolution

    /// Overlap against the employee's other bookings on the same date.
    /// (Same-day only; overnight overlap is a known follow-up.)
    static func overlapConflict(shift: FfiShiftInfo, employeeEntries: [FfiScheduleEntry]) -> ConflictReason? {
        guard let s = minutes(of: shift.startTime), let e = minutes(of: shift.endTime) else { return nil }
        for entry in employeeEntries where entry.shiftId != shift.id && entry.date == shift.date {
            guard let es = minutes(of: entry.startTime), let ee = minutes(of: entry.endTime) else { continue }
            if s < ee && es < e {
                return .overlap("\(entry.startTime)–\(entry.endTime)")
            }
        }
        return nil
    }

    /// Availability conflict for the shift's date/window. Uses the date-specific
    /// override when present (distinguishing `exception` vs manual), otherwise
    /// the weekly template. Returns nil when fully available (`Yes`).
    static func availabilityConflict(
        shift: FfiShiftInfo,
        weeklyState: (Int) -> AvailWorst,
        dateOverride: FfiEmployeeAvailabilityOverride?
    ) -> ConflictReason? {
        guard let sh = hour(of: shift.startTime), let eh = hour(of: shift.endTime) else { return nil }
        if let ovr = dateOverride {
            var map: [Int: AvailWorst] = [:]
            for slot in ovr.availability { map[Int(slot.hour)] = parseState(slot.state) }
            switch worst(startHour: sh, endHour: eh, stateAt: { map[$0] ?? .maybe }) {
            case .no:    return ovr.source == "exception" ? .exception : .dateOverride
            case .maybe: return .maybe
            case .yes:   return nil
            }
        } else {
            switch worst(startHour: sh, endHour: eh, stateAt: weeklyState) {
            case .no:    return .noAvailability
            case .maybe: return .maybe
            case .yes:   return nil
            }
        }
    }
}
