import Foundation
import Observation
import AutorotaKit
import TipKit
import os

private extension Logger {
    /// Logger for week-arithmetic fallbacks in the rota view model.
    static let weekPicker = Logger(
        subsystem: "com.toadmountain.autorota",
        category: "rota.week-picker"
    )
}

/// Shared, locale-fixed formatters and calendar for the rota view model.
/// `DateFormatter`/`Calendar` allocation is expensive and these are pure
/// (fixed format + POSIX locale), so they're hoisted out of the hot render
/// path where day headers and labels would otherwise allocate one per call.
private enum RotaDateFmt {
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static let shortMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    static let year: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()
    static let calendar = Calendar(identifier: .iso8601)
}

enum WeekCategory {
    case past, current, future
}

@MainActor
@Observable
final class RotaViewModel {

    var schedule: FfiWeekSchedule? {
        didSet { rebuildDerivedCaches() }
    }
    var isLoading = false
    var isScheduling = false
    var error: String?
    var warnings: [FfiShortfallWarning] = []

    var selectedWeekStart: String = currentWeekStart()

    // Generate confirmation (shown when Generate is tapped on a past/current week with no schedule)
    var showGenerateConfirmation = false

    // Delete schedule confirmation
    var showDeleteScheduleConfirmation = false

    // Regenerate confirmation (shown when Regenerate is tapped on a future week
    // that already has a schedule — confirms wiping it before rebuilding).
    var showRegenerateConfirmation = false

    // Edit mode
    var isEditMode = false
    var employees: [FfiEmployee] = []
    var roles: [FfiRole] = []

    // Conflict-detection caches, refreshed on every schedule load so the editor
    // and grid can flag unavailable/double-booked assignments without entering
    // edit mode. See `conflict(employeeId:shift:)`.
    private var employeesById: [Int64: FfiEmployee] = [:]
    private var availabilityOverridesByKey: [String: FfiEmployeeAvailabilityOverride] = [:]

    // Derived display caches, rebuilt once per `loadSchedule` (see
    // `rebuildDerivedCaches`) so the grid body does dictionary lookups instead
    // of grouping/filtering/conflict-checking on every SwiftUI render.
    private(set) var shiftsByDay: [(weekday: String, shifts: [FfiShiftInfo])] = []
    private var shiftsByWeekday: [String: [FfiShiftInfo]] = [:]
    private var entriesByShift: [Int64: [FfiScheduleEntry]] = [:]
    private var conflictByAssignmentId: [Int64: ConflictReason?] = [:]
    /// Today's ISO date, snapshotted per load so past/today checks don't
    /// re-format `Date()` per render.
    private var todayISO: String = ""

    // Swap
    var swapSourceAssignmentId: Int64?
    var swapSourceShiftId: Int64?

    // Past-week edit confirmation. Set true once the user confirms editing a
    // past rota; gates edits only for `weekCategory == .past`. Resets on
    // edit-mode exit and week changes.
    var pastUnlocked = false

    /// Tracks whether any mutations have occurred since the last save.
    var isDirty = false

    let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
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
        // Only show the spinner on a genuine cold load (no schedule on screen).
        // A reload that already has content swaps data underneath the live grid
        // with no teardown/spinner flash — the source of the mutation/tab-switch
        // stutter.
        let isColdLoad = (schedule == nil)
        if isColdLoad { isLoading = true }
        error = nil

        // Fetch the schedule and the conflict-detection data concurrently
        // rather than four sequential FFI round-trips. The conflict data is
        // best-effort (`try?`): a failure leaves that cache as-is.
        async let scheduleResult = service.getWeekSchedule(weekStart: selectedWeekStart)
        async let empsResult = service.listEmployees()
        async let overridesResult = service.listAllEmployeeAvailabilityOverrides()
        async let rolesResult = service.listRoles()

        // Update the conflict-detection data first so that assigning `schedule`
        // (which rebuilds the derived caches via `didSet`) sees fresh employees
        // and availability overrides. Conflict data is best-effort (`try?`).
        if let emps = try? await empsResult {
            employees = emps
            employeesById = Dictionary(uniqueKeysWithValues: emps.map { ($0.id, $0) })
        }
        if let overrides = try? await overridesResult {
            availabilityOverridesByKey = Dictionary(
                overrides.map { ("\($0.employeeId)-\($0.date)", $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        if let loadedRoles = try? await rolesResult {
            roles = loadedRoles
        }
        do {
            schedule = try await scheduleResult
        } catch {
            self.error = userFacingMessage(error)
        }

        if isColdLoad { isLoading = false }
    }

    /// Rebuild the grouping / lookup / conflict caches from the freshly-loaded
    /// schedule + conflict data. Called once per `loadSchedule` so the grid
    /// body never groups, filters, or conflict-checks during a render pass.
    private func rebuildDerivedCaches() {
        todayISO = RotaDateFmt.iso.string(from: Date())

        guard let schedule else {
            shiftsByDay = []
            shiftsByWeekday = [:]
            entriesByShift = [:]
            conflictByAssignmentId = [:]
            return
        }

        // Entries grouped by shift.
        entriesByShift = Dictionary(grouping: schedule.entries, by: \.shiftId)

        // Shifts grouped + sorted by weekday for display.
        let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let grouped = Dictionary(grouping: schedule.shifts, by: \.weekday)
        var sortedByWeekday: [String: [FfiShiftInfo]] = [:]
        for (day, shifts) in grouped {
            sortedByWeekday[day] = shifts.sorted { $0.startTime < $1.startTime }
        }
        shiftsByWeekday = sortedByWeekday
        shiftsByDay = order.compactMap { day in
            guard let shifts = sortedByWeekday[day], !shifts.isEmpty else { return nil }
            return (weekday: day, shifts: shifts)
        }

        // Per-assignment conflict, computed once and keyed by assignment id.
        var conflicts: [Int64: ConflictReason?] = [:]
        for shift in schedule.shifts {
            for entry in entriesByShift[shift.id] ?? [] {
                conflicts[entry.assignmentId] = conflict(employeeId: entry.employeeId, shift: shift)
            }
        }
        conflictByAssignmentId = conflicts
    }

    // MARK: - Conflict detection

    /// The conflict (if any) for keeping or assigning `employeeId` on `shift`.
    /// Overlap with an existing booking takes priority; then availability
    /// (date override before weekly template); `.maybe` is the softest. nil
    /// means the employee can work the shift. Mirrors scheduler eligibility.
    func conflict(employeeId: Int64, shift: FfiShiftInfo) -> ConflictReason? {
        guard let schedule else { return nil }
        let otherEntries = schedule.entries.filter { $0.employeeId == employeeId }
        if let overlap = ShiftConflict.overlapConflict(shift: shift, employeeEntries: otherEntries) {
            return overlap
        }
        guard let emp = employeesById[employeeId] else { return nil }
        let weekday = shift.weekday
        var weekly: [Int: AvailWorst] = [:]
        for slot in emp.availability where slot.weekday == weekday {
            weekly[Int(slot.hour)] = ShiftConflict.parseState(slot.state)
        }
        let dateOverride = availabilityOverridesByKey["\(employeeId)-\(shift.date)"]
        return ShiftConflict.availabilityConflict(
            shift: shift,
            weeklyState: { weekly[$0] ?? .maybe },
            dateOverride: dateOverride
        )
    }

    /// Cached conflict for an assignment, precomputed in `rebuildDerivedCaches`.
    /// Used by the grid's `AssignmentRow` to avoid per-render conflict checks.
    func conflictForAssignment(_ assignmentId: Int64) -> ConflictReason? {
        conflictByAssignmentId[assignmentId] ?? nil
    }

    func runSchedule() async {
        // For past/current weeks with no existing schedule, let the user choose
        // how to create one rather than hitting the FFI guard with an error.
        if weekCategory != .future && schedule == nil {
            showGenerateConfirmation = true
            return
        }
        // Future week that already has a schedule: confirm before wiping it.
        // `service.runSchedule` re-materialises and re-assigns from scratch, so
        // this is a destructive regenerate.
        if schedule != nil && weekCategory == .future {
            showRegenerateConfirmation = true
            return
        }
        await performSchedule()
    }

    /// Confirmed wipe-and-regenerate for a future week. `run_schedule` already
    /// deletes the existing proposed assignments + shifts and re-materialises
    /// from templates, so no separate delete is needed.
    func confirmRegenerate() async {
        await performSchedule()
    }

    private func performSchedule() async {
        isScheduling = true
        error = nil
        warnings = []
        do {
            let result = try await service.runSchedule(weekStart: selectedWeekStart)
            warnings = result.warnings
            isDirty = true
            await loadSchedule()
            await AutorotaEvents.firstScheduleGenerated.donate()
        } catch {
            self.error = userFacingMessage(error)
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
            self.error = userFacingMessage(error)
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
            self.error = userFacingMessage(error)
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
            self.error = userFacingMessage(error)
        }
        isScheduling = false
    }

    // MARK: - Edit mode

    func enterEditMode() async {
        if schedule == nil {
            do {
                _ = try await service.materialiseWeek(weekStart: selectedWeekStart)
                isDirty = true
                await loadSchedule()
            } catch {
                self.error = userFacingMessage(error)
                return
            }
        }
        do {
            employees = try await service.listEmployees()
            roles = try await service.listRoles()
        } catch {
            self.error = userFacingMessage(error)
        }
        isEditMode = true
    }

    func exitEditMode() {
        isEditMode = false
        pastUnlocked = false
        cancelSwap()
        if isDirty {
            Task { await autoSave() }
        }
    }

    func resetModes() {
        isEditMode = false
        pastUnlocked = false
        showGenerateConfirmation = false
        showDeleteScheduleConfirmation = false
        showRegenerateConfirmation = false
        cancelSwap()
    }

    // MARK: - Auto-save

    /// Save the current rota state if changes exist.
    func autoSave() async {
        guard isDirty, let rotaId = schedule?.rotaId else { return }
        do {
            _ = try await service.createSave(rotaId: rotaId)
            isDirty = false
        } catch {
            // Non-fatal: save failed but user can continue editing
        }
    }

    // MARK: - Assignment actions

    func deleteAssignment(id: Int64) async {
        do {
            try await service.deleteAssignment(id: id)
            isDirty = true
            await loadSchedule()
        } catch {
            self.error = userFacingMessage(error)
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
            isDirty = true
            await loadSchedule()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    // MARK: - Shift actions

    func deleteShift(id: Int64) async {
        do {
            try await service.deleteShift(id: id)
            isDirty = true
            await loadSchedule()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func updateShiftTimes(id: Int64, startTime: String, endTime: String) async {
        do {
            try await service.updateShiftTimes(id: id, startTime: startTime, endTime: endTime)
            isDirty = true
            await loadSchedule()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func createAdHocShift(
        date: String,
        startTime: String,
        endTime: String,
        requiredRole: String,
        roleRequirements: [FfiRoleRequirement] = [],
        minEmployees: UInt32 = 1,
        maxEmployees: UInt32 = 1
    ) async {
        guard let rotaId = schedule?.rotaId else { return }
        do {
            let id = try await service.createAdHocShift(
                rotaId: rotaId, date: date, startTime: startTime,
                endTime: endTime, requiredRole: requiredRole,
                roleRequirements: roleRequirements
            )
            // Ad-hoc creation fixes capacity at 1/1; apply the requested
            // capacity + requirements in a follow-up update.
            if minEmployees != 1 || maxEmployees != 1 || !roleRequirements.isEmpty {
                try await service.updateShift(
                    id: id, minEmployees: minEmployees,
                    maxEmployees: maxEmployees, roleRequirements: roleRequirements
                )
            }
            isDirty = true
            await loadSchedule()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    /// Update a shift's capacity (min/max) and role requirements.
    func updateShift(
        id: Int64,
        minEmployees: UInt32,
        maxEmployees: UInt32,
        roleRequirements: [FfiRoleRequirement]
    ) async {
        do {
            try await service.updateShift(
                id: id, minEmployees: minEmployees,
                maxEmployees: maxEmployees, roleRequirements: roleRequirements
            )
            isDirty = true
            await loadSchedule()
        } catch {
            self.error = userFacingMessage(error)
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
            isDirty = true
            await loadSchedule()
        } catch {
            self.error = userFacingMessage(error)
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

    /// Today's ISO date. Uses the per-load snapshot when available, else
    /// formats `Date()` once (covers calls before the first load completes).
    private var currentTodayISO: String {
        todayISO.isEmpty ? RotaDateFmt.iso.string(from: Date()) : todayISO
    }

    func isShiftPast(_ shift: FfiShiftInfo) -> Bool {
        shift.date < currentTodayISO
    }

    func isShiftLocked(_ shift: FfiShiftInfo) -> Bool {
        weekCategory == .past && !pastUnlocked
    }

    /// Step the selected week forward/back by `weeks`, mutating `selectedWeekStart`.
    /// `cal.date(byAdding:)` only fails for arithmetically impossible additions
    /// (year overflow, etc.); treat that as "stay put" and log so the silent
    /// fallback is debuggable.
    func shiftWeek(by weeks: Int) {
        guard let date = RotaDateFmt.iso.date(from: selectedWeekStart) else { return }
        guard let shifted = RotaDateFmt.calendar.date(byAdding: .weekOfYear, value: weeks, to: date) else {
            Logger.weekPicker.warning(
                "cal.date(byAdding: .weekOfYear, value: \(weeks)) returned nil; staying on \(self.selectedWeekStart)"
            )
            return
        }
        selectedWeekStart = RotaDateFmt.iso.string(from: shifted)
    }

    /// Abbreviated day-of-month label for a weekday in the selected week, e.g. "Jun 1".
    func dayOfMonthLabel(_ weekday: String) -> String {
        let iso = dateForWeekday(weekday)
        guard let date = RotaDateFmt.iso.date(from: iso) else { return "" }
        return RotaDateFmt.shortMonthDay.string(from: date)
    }

    /// Date string for a weekday offset in the selected week (Mon=0, Tue=1, ..., Sun=6).
    func dateForWeekday(_ weekday: String) -> String {
        let offsets = ["Mon": 0, "Tue": 1, "Wed": 2, "Thu": 3, "Fri": 4, "Sat": 5, "Sun": 6]
        guard let offset = offsets[weekday] else { return selectedWeekStart }
        guard let monday = RotaDateFmt.iso.date(from: selectedWeekStart) else { return selectedWeekStart }
        guard let target = RotaDateFmt.calendar.date(byAdding: .day, value: offset, to: monday) else {
            return selectedWeekStart
        }
        return RotaDateFmt.iso.string(from: target)
    }

    func isDayPast(_ weekday: String) -> Bool {
        dateForWeekday(weekday) < currentTodayISO
    }

    func isDayLocked(_ weekday: String) -> Bool {
        weekCategory == .past && !pastUnlocked
    }

    func isDayToday(_ weekday: String) -> Bool {
        dateForWeekday(weekday) == currentTodayISO
    }

    // MARK: - Derived helpers

    /// Human-readable date range for the selected week, e.g. "Mar 23 – Mar 29, 2026".
    var weekDateRangeLabel: String {
        guard let monday = RotaDateFmt.iso.date(from: selectedWeekStart) else { return selectedWeekStart }
        guard let sunday = RotaDateFmt.calendar.date(byAdding: .day, value: 6, to: monday) else {
            return selectedWeekStart
        }
        return "\(RotaDateFmt.shortMonthDay.string(from: monday)) – \(RotaDateFmt.shortMonthDay.string(from: sunday)), \(RotaDateFmt.year.string(from: sunday))"
    }

    /// Concise date range for the nav-bar title, e.g. "Jun 8 – Jun 15" (no year).
    var weekDateRangeShort: String {
        guard let monday = RotaDateFmt.iso.date(from: selectedWeekStart) else { return selectedWeekStart }
        guard let sunday = RotaDateFmt.calendar.date(byAdding: .day, value: 6, to: monday) else {
            return selectedWeekStart
        }
        return "\(RotaDateFmt.shortMonthDay.string(from: monday)) – \(RotaDateFmt.shortMonthDay.string(from: sunday))"
    }

    /// Shifts for a weekday, from the cache rebuilt on load (O(1) lookup used
    /// by the grid instead of `shiftsByDay.first(where:)`).
    func shifts(on weekday: String) -> [FfiShiftInfo] {
        shiftsByWeekday[weekday] ?? []
    }

    /// All weekdays for the schedule (used by edit mode to show "Add Shift" for empty days).
    var allWeekdays: [String] {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    }

    /// Assignments for a specific shift, from the per-load cache.
    func assignments(for shiftId: Int64) -> [FfiScheduleEntry] {
        entriesByShift[shiftId] ?? []
    }

    /// Employees not yet assigned to the given shift.
    func availableEmployees(for shiftId: Int64) -> [FfiEmployee] {
        let assignedIds = Set(assignments(for: shiftId).map(\.employeeId))
        return employees.filter { !assignedIds.contains($0.id) }
    }

}
