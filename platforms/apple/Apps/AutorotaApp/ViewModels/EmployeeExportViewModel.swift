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
    var profile: String = "staff_schedule"
    var showShiftName: Bool = true
    var showTimes: Bool = true
    var showRole: Bool = true

    var isExporting = false
    var isLoading = false
    var error: String?

    let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = LiveAutorotaService()) {
        self.service = service

        // Read persisted defaults.
        let defaults = UserDefaults.standard
        format = defaults.string(forKey: "empExportDefaultFormat") ?? "csv"
        profile = defaults.string(forKey: "empExportDefaultProfile") ?? "staff_schedule"
        showShiftName = defaults.object(forKey: "empExportShowShiftName") as? Bool ?? true
        showTimes = defaults.object(forKey: "empExportShowTimes") as? Bool ?? true
        showRole = defaults.object(forKey: "empExportShowRole") as? Bool ?? true
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
        defaults.set(profile, forKey: "empExportDefaultProfile")
        defaults.set(showShiftName, forKey: "empExportShowShiftName")
        defaults.set(showTimes, forKey: "empExportShowTimes")
        defaults.set(showRole, forKey: "empExportShowRole")

        let config = FfiEmployeeExportConfig(
            employeeId: employeeId,
            startDate: exportStartDate,
            endDate: exportEndDate,
            format: format,
            profile: profile,
            showShiftName: showShiftName,
            showTimes: showTimes,
            showRole: showRole,
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
