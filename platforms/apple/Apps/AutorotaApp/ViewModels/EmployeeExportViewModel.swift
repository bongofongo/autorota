import Foundation
import Observation
import AutorotaKit

@Observable
final class EmployeeExportViewModel {

    enum DateMode: String, CaseIterable, Identifiable {
        case singleWeek = "Single Week"
        case dateRange = "Date Range"

        var id: String { rawValue }
    }

    // MARK: - State

    var employees: [FfiEmployee] = []
    var selectedEmployeeId: Int64?
    var dateMode: DateMode = .singleWeek
    var selectedWeekStart: String = currentWeekStart()
    var startDate: Date = Calendar.current.startOfDay(for: Date())
    var endDate: Date = Calendar.current.startOfDay(for: Date())

    var format: String = "csv"
    // Employee exports never include wage/cost data.
    let profile = "staff_schedule"

    var isExporting = false
    var isLoading = false
    var error: String?

    let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
        self.service = service

        // Read persisted defaults.
        let defaults = UserDefaults.standard
        format = defaults.string(forKey: "empExportDefaultFormat") ?? "csv"
    }

    // MARK: - Loading

    func loadEmployees() async {
        isLoading = true
        do {
            employees = try await service.listEmployees()
            if selectedEmployeeId == nil {
                selectedEmployeeId = employees.first?.id
            }
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
    }

    // MARK: - Export

    var canExport: Bool {
        selectedEmployeeId != nil && !isExporting
    }

    /// Computed start/end date strings depending on date mode.
    private var exportStartDate: String {
        switch dateMode {
        case .singleWeek:
            return selectedWeekStart
        case .dateRange:
            return Self.dateFormatter.string(from: startDate)
        }
    }

    private var exportEndDate: String {
        switch dateMode {
        case .singleWeek:
            // End of week = start + 6 days.
            guard let start = Self.dateFormatter.date(from: selectedWeekStart) else { return selectedWeekStart }
            let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
            return Self.dateFormatter.string(from: end)
        case .dateRange:
            return Self.dateFormatter.string(from: endDate)
        }
    }

    func performExport() async -> FfiExportResult? {
        guard let employeeId = selectedEmployeeId else { return nil }
        isExporting = true
        error = nil

        // Persist defaults.
        let defaults = UserDefaults.standard
        defaults.set(format, forKey: "empExportDefaultFormat")

        // Employee exports have a fixed shape: shift name + times.
        let config = FfiEmployeeExportConfig(
            employeeId: employeeId,
            startDate: exportStartDate,
            endDate: exportEndDate,
            format: format,
            profile: profile,
            showShiftName: true,
            showTimes: true,
            showRole: false,
            timezoneId: TimeZone.current.identifier
        )

        do {
            let result = try await service.exportEmployeeSchedule(config: config)
            isExporting = false
            return result
        } catch {
            self.error = userFacingMessage(error)
            isExporting = false
            return nil
        }
    }

    /// App-wide shared ISO formatter (POSIX locale; see AvailabilityWeekMath).
    private static let dateFormatter = AvailabilityWeekMath.isoFmt
}
