import Foundation
import Observation
import AutorotaKit

enum WeekCategory {
    case past, current, future
}

@Observable
final class RotaViewModel {

    var schedule: FfiWeekSchedule?
    var isLoading = false
    var isScheduling = false
    var error: String?
    var warnings: [FfiShortfallWarning] = []

    var selectedWeekStart: String = currentWeekStart()

    // Generate confirmation (shown when Generate is tapped on a past/current week with no schedule)
    var showGenerateConfirmation = false

    // Delete schedule confirmation
    var showDeleteScheduleConfirmation = false

    // Edit mode
    var isEditMode = false
    var employees: [FfiEmployee] = []
    var roles: [FfiRole] = []

    // Swap
    var swapSourceAssignmentId: Int64?
    var swapSourceShiftId: Int64?

    // Past lock
    var pastUnlocked = false

    let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = LiveAutorotaService()) {
        self.service = service
    }

    // MARK: - Week category

    var weekCategory: WeekCategory {
        let current = currentWeekStart()
        if selectedWeekStart < current { return .past }
        if selectedWeekStart == current { return .current }
        return .future
    }

    /// Whether the selected week contains any past days.
    var weekHasPastDays: Bool {
        weekCategory == .past || weekCategory == .current
    }

    // MARK: - Loading

    func loadSchedule() async {
        isLoading = true
        error = nil
        do {
            schedule = try await service.getWeekSchedule(weekStart: selectedWeekStart)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func runSchedule() async {
        // For past/current weeks with no existing schedule, let the user choose
        // how to create one rather than hitting the FFI guard with an error.
        if weekCategory != .future && schedule == nil {
            showGenerateConfirmation = true
            return
        }
        isScheduling = true
        error = nil
        warnings = []
        do {
            let result = try await service.runSchedule(weekStart: selectedWeekStart)
            warnings = result.warnings
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
        isScheduling = false
    }

    /// Create a schedule for the current week by materialising all shifts from
    /// templates, leaving every shift unassigned. For past/current weeks only.
    func createFromTemplate() async {
        isScheduling = true
        error = nil
        do {
            _ = try await service.materialiseWeek(weekStart: selectedWeekStart)
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
        isScheduling = false
    }

    /// Delete the entire schedule for the selected week, including all shifts
    /// and assignments. Only available for past/current weeks in edit mode.
    func deleteSchedule() async {
        do {
            try await service.deleteWeek(weekStart: selectedWeekStart)
            schedule = nil
            exitEditMode()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Create a completely blank schedule for the current week with no shifts
    /// and no assignments. For past/current weeks only.
    func createEmpty() async {
        isScheduling = true
        error = nil
        do {
            _ = try await service.createEmptyWeek(weekStart: selectedWeekStart)
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
        isScheduling = false
    }

    // MARK: - Edit mode

    func enterEditMode() async {
        if schedule == nil {
            do {
                _ = try await service.materialiseWeek(weekStart: selectedWeekStart)
                await loadSchedule()
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        do {
            employees = try await service.listEmployees()
            roles = try await service.listRoles()
        } catch {
            self.error = error.localizedDescription
        }
        isEditMode = true
    }

    func exitEditMode() {
        isEditMode = false
        pastUnlocked = false
    }

    func resetModes() {
        isEditMode = false
        pastUnlocked = false
        showGenerateConfirmation = false
        showDeleteScheduleConfirmation = false
        cancelSwap()
    }

    // MARK: - Assignment actions

    func deleteAssignment(id: Int64) async {
        do {
            try await service.deleteAssignment(id: id)
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addEmployeeToShift(shiftId: Int64, employeeId: Int64) async {
        guard let rotaId = schedule?.rotaId else { return }
        do {
            let assignment = FfiAssignment(
                id: 0, rotaId: rotaId, shiftId: shiftId,
                employeeId: employeeId, status: "Overridden", employeeName: nil, hourlyWage: nil
            )
            _ = try await service.createAssignment(assignment)
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Shift actions

    func deleteShift(id: Int64) async {
        do {
            try await service.deleteShift(id: id)
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func updateShiftTimes(id: Int64, startTime: String, endTime: String) async {
        do {
            try await service.updateShiftTimes(id: id, startTime: startTime, endTime: endTime)
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createAdHocShift(date: String, startTime: String, endTime: String, requiredRole: String) async {
        guard let rotaId = schedule?.rotaId else { return }
        do {
            _ = try await service.createAdHocShift(
                rotaId: rotaId, date: date, startTime: startTime,
                endTime: endTime, requiredRole: requiredRole
            )
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Swap

    var hasSwapSource: Bool { swapSourceAssignmentId != nil }

    func selectSwapSource(assignmentId: Int64, shiftId: Int64) {
        if swapSourceAssignmentId == assignmentId {
            cancelSwap()
        } else {
            swapSourceAssignmentId = assignmentId
            swapSourceShiftId = shiftId
        }
    }

    func executeSwap(targetAssignmentId: Int64) async {
        guard let sourceId = swapSourceAssignmentId else { return }
        cancelSwap()
        do {
            try await service.swapAssignments(idA: sourceId, idB: targetAssignmentId)
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancelSwap() {
        swapSourceAssignmentId = nil
        swapSourceShiftId = nil
    }

    func isSwapSource(assignmentId: Int64) -> Bool {
        swapSourceAssignmentId == assignmentId
    }

    func isSwapTarget(entry: FfiScheduleEntry) -> Bool {
        guard let sourceShiftId = swapSourceShiftId else { return false }
        return entry.shiftId != sourceShiftId
    }

    // MARK: - Past lock

    func isShiftPast(_ shift: FfiShiftInfo) -> Bool {
        let today = isoDateString(from: Date())
        return shift.date < today
    }

    func isShiftLocked(_ shift: FfiShiftInfo) -> Bool {
        isShiftPast(shift) && !pastUnlocked
    }

    /// Date string for a weekday offset in the selected week (Mon=0, Tue=1, ..., Sun=6).
    func dateForWeekday(_ weekday: String) -> String {
        let offsets = ["Mon": 0, "Tue": 1, "Wed": 2, "Thu": 3, "Fri": 4, "Sat": 5, "Sun": 6]
        guard let offset = offsets[weekday] else { return selectedWeekStart }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let monday = fmt.date(from: selectedWeekStart) else { return selectedWeekStart }
        let cal = Calendar(identifier: .iso8601)
        let target = cal.date(byAdding: .day, value: offset, to: monday)!
        return fmt.string(from: target)
    }

    func isDayPast(_ weekday: String) -> Bool {
        let dayDate = dateForWeekday(weekday)
        let today = isoDateString(from: Date())
        return dayDate < today
    }

    func isDayLocked(_ weekday: String) -> Bool {
        isDayPast(weekday) && !pastUnlocked
    }

    // MARK: - Derived helpers

    /// Human-readable date range for the selected week, e.g. "Mar 23 – Mar 29, 2026".
    var weekDateRangeLabel: String {
        let parseFmt = DateFormatter()
        parseFmt.dateFormat = "yyyy-MM-dd"
        parseFmt.locale = Locale(identifier: "en_US_POSIX")
        guard let monday = parseFmt.date(from: selectedWeekStart) else { return selectedWeekStart }
        let cal = Calendar(identifier: .iso8601)
        let sunday = cal.date(byAdding: .day, value: 6, to: monday)!
        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "MMM d"
        let yearFmt = DateFormatter()
        yearFmt.dateFormat = "yyyy"
        return "\(displayFmt.string(from: monday)) – \(displayFmt.string(from: sunday)), \(yearFmt.string(from: sunday))"
    }

    /// Shifts grouped by weekday for display.
    var shiftsByDay: [(weekday: String, shifts: [FfiShiftInfo])] {
        guard let schedule else { return [] }
        let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let grouped = Dictionary(grouping: schedule.shifts, by: \.weekday)
        return order.compactMap { day in
            guard let shifts = grouped[day], !shifts.isEmpty else { return nil }
            return (weekday: day, shifts: shifts.sorted { $0.startTime < $1.startTime })
        }
    }

    /// All weekdays for the schedule (used by edit mode to show "Add Shift" for empty days).
    var allWeekdays: [String] {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    }

    /// Assignments for a specific shift.
    func assignments(for shiftId: Int64) -> [FfiScheduleEntry] {
        schedule?.entries.filter { $0.shiftId == shiftId } ?? []
    }

    /// Employees not yet assigned to the given shift.
    func availableEmployees(for shiftId: Int64) -> [FfiEmployee] {
        let assignedIds = Set(assignments(for: shiftId).map(\.employeeId))
        return employees.filter { !assignedIds.contains($0.id) }
    }

    // MARK: - Private helpers

    private func isoDateString(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }
}
