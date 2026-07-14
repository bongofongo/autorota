import Foundation
import AutorotaKit

/// Shared week-math for date-aware availability editing: maps a week's ISO
/// Monday into per-date context, merges default availability with stored
/// overrides, and persists grid edits as per-date employee availability
/// overrides (preserving exception classification, tagging fresh rows as
/// "manual"). Also hosts the app-wide canonical weekday order and cached
/// date/time formatters.
enum AvailabilityWeekMath {

    /// Canonical weekday display order (ISO week: Monday first).
    static let weekdayOrder = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Index of each weekday in `weekdayOrder` (Mon=0 … Sun=6).
    static let weekdayIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: weekdayOrder.enumerated().map { ($1, $0) }
    )

    /// Shared cached "yyyy-MM-dd" formatter (POSIX locale).
    static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Shared cached "HH:mm" formatter (POSIX locale) for shift times.
    static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func weekDays(from weekStartIso: String) -> [(weekday: String, date: Date, iso: String)] {
        guard let monday = isoFmt.date(from: weekStartIso) else { return [] }
        let cal = Calendar(identifier: .iso8601)
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: monday)!
            return (weekdayOrder[i], d, isoFmt.string(from: d))
        }
    }

    static func dayNumber(for date: Date) -> String {
        String(Calendar(identifier: .iso8601).component(.day, from: date))
    }

    static func merge(
        days: [(weekday: String, date: Date, iso: String)],
        overrides: [String: FfiEmployeeAvailabilityOverride],
        defaultAvailability: [AvailabilitySlot]
    ) -> [AvailabilitySlot] {
        var out: [AvailabilitySlot] = []
        for (wd, _, iso) in days {
            if let ovr = overrides[iso] {
                for s in ovr.availability {
                    out.append(AvailabilitySlot(weekday: wd, hour: s.hour, state: s.state))
                }
            } else {
                for s in defaultAvailability where s.weekday == wd {
                    out.append(s)
                }
            }
        }
        return out
    }

    static func persistWeekEdits(
        newSlots: [AvailabilitySlot],
        days: [(weekday: String, date: Date, iso: String)],
        overrideByIso: [String: FfiEmployeeAvailabilityOverride],
        defaultAvailability: [AvailabilitySlot],
        employeeId: Int64,
        overrideVM: OverrideViewModel
    ) async {
        for (wd, _, iso) in days {
            let newDay = newSlots
                .filter { $0.weekday == wd }
                .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
                .sorted { $0.hour < $1.hour }
            let defaultDay = defaultAvailability
                .filter { $0.weekday == wd }
                .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
                .sorted { $0.hour < $1.hour }
            let existing = overrideByIso[iso]

            if newDay == defaultDay {
                // Matches default template. Silently delete stale *manual*
                // overrides, but leave explicit exceptions alone — users
                // classify those via the Exceptions UI.
                if let ex = existing, ex.source != "exception" {
                    await overrideVM.deleteEmployeeOverride(id: ex.id)
                }
                continue
            }

            let currentStored = existing?.availability.sorted { $0.hour < $1.hour } ?? defaultDay
            if newDay == currentStored { continue }

            let source = existing?.source ?? "manual"
            let ovr = FfiEmployeeAvailabilityOverride(
                id: existing?.id ?? 0,
                employeeId: employeeId,
                date: iso,
                availability: newDay,
                notes: existing?.notes,
                source: source
            )
            await overrideVM.upsertEmployeeOverride(ovr)
        }
    }
}
