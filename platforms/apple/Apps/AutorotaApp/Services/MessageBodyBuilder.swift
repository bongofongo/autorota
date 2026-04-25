import Foundation
import AutorotaKit

/// Renders the per-employee rota into a markdown body that's safe to drop
/// into iMessage / SMS / WhatsApp / mail bodies. Sticks to the markdown
/// dialect WhatsApp understands (`*bold*`, `_italic_`, plain newlines) and
/// avoids `#` headings and tables.
enum MessageBodyBuilder {

    static func build(
        employee: FfiEmployee,
        weekStart: String,
        schedule: FfiWeekSchedule?,
        settings: BulkSendSettings = .current
    ) -> String {
        let entries = (schedule?.entries ?? [])
            .filter { $0.employeeId == employee.id }
            .sorted { ($0.date, $0.startTime) < ($1.date, $1.startTime) }

        var lines: [String] = []

        let prefix = settings.customPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty {
            lines.append(personalize(prefix, employee: employee))
        }

        if settings.weekHeader {
            lines.append("*Rota for week of \(prettyWeek(weekStart))*")
        }

        if settings.shiftLine {
            if entries.isEmpty {
                lines.append("_No shifts scheduled this week._")
            } else {
                if !lines.isEmpty { lines.append("") }
                for e in entries {
                    lines.append(shiftLine(e))
                }
            }
        }

        let suffix = settings.customSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(personalize(suffix, employee: employee))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func personalize(_ template: String, employee: FfiEmployee) -> String {
        template
            .replacingOccurrences(of: "{first_name}", with: employee.firstName)
            .replacingOccurrences(of: "{last_name}", with: employee.lastName)
            .replacingOccurrences(of: "{name}", with: employee.displayName)
    }

    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let weekFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    private static func prettyWeek(_ iso: String) -> String {
        guard let d = isoFmt.date(from: iso) else { return iso }
        return weekFmt.string(from: d)
    }

    private static func shiftLine(_ entry: FfiScheduleEntry) -> String {
        let dayLabel: String = {
            guard let d = isoFmt.date(from: entry.date) else { return entry.date }
            return dayFmt.string(from: d)
        }()
        let times = "\(entry.startTime)–\(entry.endTime)"
        if entry.requiredRole.isEmpty {
            return "\(dayLabel) · \(times)"
        }
        return "\(dayLabel) · \(times) · \(entry.requiredRole)"
    }
}
