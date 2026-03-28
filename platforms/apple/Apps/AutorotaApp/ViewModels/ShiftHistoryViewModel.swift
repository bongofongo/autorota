import Foundation
import Observation
import AutorotaKit

@Observable
final class ShiftHistoryViewModel {

    var pastShifts: [FfiEmployeeShiftRecord] = []
    var currentWeekShifts: [FfiEmployeeShiftRecord] = []
    var plannedShifts: [FfiEmployeeShiftRecord] = []

    var currentWeekHours: Float = 0
    var totalHours: Float = 0

    struct WeekSummary: Identifiable {
        var id: String { weekStart }
        let weekStart: String
        let hours: Float
    }

    struct MonthSummary: Identifiable {
        var id: String { month }
        let month: String
        let hours: Float
    }

    var weeklyBreakdown: [WeekSummary] = []
    var monthlyBreakdown: [MonthSummary] = []

    var isLoading = false
    var error: String?

    private let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = LiveAutorotaService()) {
        self.service = service
    }

    func load(employeeId: Int64) async {
        isLoading = true
        error = nil
        do {
            let records = try await service.listEmployeeShiftHistory(employeeId: employeeId)
            categorise(records)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func categorise(_ records: [FfiEmployeeShiftRecord]) {
        let mondayStr = currentWeekStart()
        let cal = Calendar(identifier: .iso8601)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let monday = fmt.date(from: mondayStr)!
        let sunday = cal.date(byAdding: .day, value: 6, to: monday)!
        let sundayStr = fmt.string(from: sunday)

        var past: [FfiEmployeeShiftRecord] = []
        var current: [FfiEmployeeShiftRecord] = []
        var planned: [FfiEmployeeShiftRecord] = []

        for r in records {
            if r.date < mondayStr {
                past.append(r)
            } else if r.date <= sundayStr {
                current.append(r)
            } else {
                planned.append(r)
            }
        }

        pastShifts = past
        currentWeekShifts = current
        plannedShifts = planned

        currentWeekHours = current.reduce(0) { $0 + $1.durationHours }
        totalHours = past.reduce(0) { $0 + $1.durationHours }

        // Weekly breakdown — past shifts only (most recent first)
        var weekMap: [String: Float] = [:]
        for r in past { weekMap[r.weekStart, default: 0] += r.durationHours }
        weeklyBreakdown = weekMap.map { WeekSummary(weekStart: $0.key, hours: $0.value) }
            .sorted { $0.weekStart > $1.weekStart }

        // Monthly breakdown — past shifts only (most recent first)
        var monthMap: [String: Float] = [:]
        for r in past {
            let month = String(r.date.prefix(7))
            monthMap[month, default: 0] += r.durationHours
        }
        monthlyBreakdown = monthMap.map { MonthSummary(month: $0.key, hours: $0.value) }
            .sorted { $0.month > $1.month }
    }
}
