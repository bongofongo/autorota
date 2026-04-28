import Foundation
import Observation
import AutorotaKit

@Observable
final class AnalyticsViewModel {

    // MARK: - Date Range

    var startDate: Date
    var endDate: Date

    // MARK: - Loading State

    var isLoading = false
    var error: String?

    // MARK: - Summary

    var totalHours: Float = 0
    var totalCost: Float = 0
    var employeeCount: Int = 0
    var avgHoursPerEmployee: Float = 0

    // MARK: - Employee Summaries

    struct EmployeeSummary: Identifiable {
        let id: Int64
        let name: String
        var totalHours: Float
        var totalEarnings: Float
        var avgHoursPerWeek: Float
        var targetWeeklyHours: Float?
        var shiftCount: Int
    }

    enum EmployeeSortOrder: String, CaseIterable, Identifiable {
        case name = "Name"
        case hours = "Hours"
        case earnings = "Earnings"

        var id: String { rawValue }
    }

    var employeeSummaries: [EmployeeSummary] = []
    var employeeSortOrder: EmployeeSortOrder = .hours {
        didSet { sortEmployees() }
    }

    // MARK: - Role Breakdown

    struct RoleSummary: Identifiable {
        var id: String { role }
        let role: String
        var totalHours: Float
        var shiftCount: Int
    }

    var hoursByRole: [RoleSummary] = []

    // MARK: - Day of Week Distribution

    struct DayOfWeekSummary: Identifiable {
        var id: Int { dayIndex }
        let dayName: String
        let dayIndex: Int
        var totalHours: Float
        var shiftCount: Int
    }

    var hoursByDayOfWeek: [DayOfWeekSummary] = []

    // MARK: - Weekly Trends

    struct WeekTrend: Identifiable {
        var id: String { weekStart }
        let weekStart: String
        var totalHours: Float
        var totalCost: Float
    }

    var weeklyTrends: [WeekTrend] = []

    // MARK: - Init

    private let service: AutorotaServiceProtocol
    var exchangeRates: ExchangeRateService?
    var displayCurrency: String = "usd"

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
        self.service = service
        let cal = Calendar(identifier: .iso8601)
        let now = Date()
        let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        let sunday = cal.date(byAdding: .day, value: 6, to: monday) ?? now
        self.startDate = monday
        self.endDate = sunday
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        error = nil
        do {
            let (startStr, endStr) = effectiveDateRange()
            let records = try await service.listAllShiftHistory(startDate: startStr, endDate: endStr)
            let employees = try await service.listEmployees()
            computeAggregates(records, employees: employees)
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
    }

    // MARK: - Date Range Computation

    func effectiveDateRange() -> (start: String, end: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return (fmt.string(from: startDate), fmt.string(from: endDate))
    }

    // MARK: - Aggregation

    private func computeAggregates(_ records: [FfiEmployeeShiftRecord], employees: [FfiEmployee]) {
        let targetMap = Dictionary(uniqueKeysWithValues: employees.map { ($0.id, $0.targetWeeklyHours) })
        let wageCurrencyMap = Dictionary(uniqueKeysWithValues: employees.map { ($0.id, $0.wageCurrency ?? "usd") })

        // Helper to convert a shift cost from the employee's wage currency to display currency
        let convertCost: (Float?, Int64) -> Float = { cost, employeeId in
            guard let cost, let rates = self.exchangeRates else { return cost ?? 0 }
            let from = wageCurrencyMap[employeeId] ?? "usd"
            return rates.convert(cost, from: from, to: self.displayCurrency)
        }

        // Summary
        totalHours = records.reduce(0) { $0 + $1.durationHours }
        totalCost = records.reduce(0) { $0 + convertCost($1.shiftCost, $1.employeeId) }

        // Employee summaries
        let distinctWeeks = Set(records.map(\.weekStart)).count
        let weeksInRange = max(Float(distinctWeeks), 1)

        var empMap: [Int64: EmployeeSummary] = [:]
        for r in records {
            let name = r.employeeName ?? "Unknown"
            let cost = convertCost(r.shiftCost, r.employeeId)
            if var existing = empMap[r.employeeId] {
                existing.totalHours += r.durationHours
                existing.totalEarnings += cost
                existing.shiftCount += 1
                empMap[r.employeeId] = existing
            } else {
                empMap[r.employeeId] = EmployeeSummary(
                    id: r.employeeId,
                    name: name,
                    totalHours: r.durationHours,
                    totalEarnings: cost,
                    avgHoursPerWeek: 0,
                    targetWeeklyHours: targetMap[r.employeeId],
                    shiftCount: 1
                )
            }
        }
        for key in empMap.keys {
            guard var summary = empMap[key] else { continue }
            summary.avgHoursPerWeek = summary.totalHours / weeksInRange
            empMap[key] = summary
        }
        employeeSummaries = Array(empMap.values)
        sortEmployees()

        employeeCount = employeeSummaries.count
        avgHoursPerEmployee = employeeCount > 0 ? totalHours / Float(employeeCount) : 0

        // Role breakdown
        var roleMap: [String: RoleSummary] = [:]
        for r in records {
            if var existing = roleMap[r.requiredRole] {
                existing.totalHours += r.durationHours
                existing.shiftCount += 1
                roleMap[r.requiredRole] = existing
            } else {
                roleMap[r.requiredRole] = RoleSummary(role: r.requiredRole, totalHours: r.durationHours, shiftCount: 1)
            }
        }
        hoursByRole = roleMap.values.sorted { $0.totalHours > $1.totalHours }

        // Day of week distribution
        let dayOrder = ["Mon": 0, "Tue": 1, "Wed": 2, "Thu": 3, "Fri": 4, "Sat": 5, "Sun": 6]
        var dowMap: [String: DayOfWeekSummary] = [:]
        for r in records {
            if var existing = dowMap[r.weekday] {
                existing.totalHours += r.durationHours
                existing.shiftCount += 1
                dowMap[r.weekday] = existing
            } else {
                dowMap[r.weekday] = DayOfWeekSummary(
                    dayName: r.weekday,
                    dayIndex: dayOrder[r.weekday] ?? 0,
                    totalHours: r.durationHours,
                    shiftCount: 1
                )
            }
        }
        hoursByDayOfWeek = dowMap.values.sorted { $0.dayIndex < $1.dayIndex }

        // Weekly trends
        var weekMap: [String: WeekTrend] = [:]
        for r in records {
            let cost = convertCost(r.shiftCost, r.employeeId)
            if var existing = weekMap[r.weekStart] {
                existing.totalHours += r.durationHours
                existing.totalCost += cost
                weekMap[r.weekStart] = existing
            } else {
                weekMap[r.weekStart] = WeekTrend(weekStart: r.weekStart, totalHours: r.durationHours, totalCost: cost)
            }
        }
        weeklyTrends = weekMap.values.sorted { $0.weekStart < $1.weekStart }
    }

    private func sortEmployees() {
        switch employeeSortOrder {
        case .name:
            employeeSummaries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .hours:
            employeeSummaries.sort { $0.totalHours > $1.totalHours }
        case .earnings:
            employeeSummaries.sort { $0.totalEarnings > $1.totalEarnings }
        }
    }
}
