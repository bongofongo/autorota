import Foundation
import Observation
import AutorotaKit
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
    /// App-wide shared ISO formatter (see AvailabilityWeekMath).
    static let iso = AvailabilityWeekMath.isoFmt
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
    /// True once the first `loadSchedule` has completed (success or failure).
    /// The spinner gates on this rather than `schedule == nil`, so a week with
    /// no rota — where `schedule` stays nil across reloads — doesn't flash the
    /// "Loading schedule…" spinner every time the tab reappears. Only the very
    /// first cold load shows it.
    private var hasLoaded = false
    var isScheduling = false
    var error: String?

    var selectedWeekStart: String = currentWeekStart()
    /// Direction of the most recent week step (-1 toward the past, +1 toward
    /// the future); drives the edge the week-slide transition pushes from.
    private(set) var lastWeekStepDirection = 1
    /// Bumped by swipe-driven week changes so RotaView can fire a haptic tick.
    /// Lives here (not in view state) because the grid view's identity is
    /// reset on each week step, which would swallow a view-local trigger.
    var swipeFeedbackTick = 0

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
    /// Live staffing gaps for the loaded week, recomputed per `loadSchedule`
    /// (warnings = below min or per-role min unmet; notes = min met, below max).
    /// Drives the options-menu badge and the Warnings sheet.
    private(set) var staffingIssues: [StaffingIssue] = []
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
        // Only show the spinner on the first-ever load. Reloads (tab reappear,
        // week step, mutations) swap data underneath the live content with no
        // teardown/spinner flash — the source of the tab-switch stutter. Gating
        // on `!hasLoaded` rather than `schedule == nil` also covers weeks with
        // no rota, where `schedule` stays nil and would otherwise flash the
        // spinner on every reappear.
        let isColdLoad = !hasLoaded
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

        hasLoaded = true
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
            staffingIssues = []
            return
        }

        // Entries grouped by shift.
        entriesByShift = Dictionary(grouping: schedule.entries, by: \.shiftId)

        // Shifts grouped + sorted by weekday for display.
        let order = AvailabilityWeekMath.weekdayOrder
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

        staffingIssues = StaffingIssue.displaySort(
            schedule.shifts.flatMap { staffingIssues(for: $0) }
        )
    }

    // MARK: - Staffing issues

    /// Live staffing gaps for one shift. Per-role coverage mirrors the
    /// scheduler's `role_deficits`: an assigned employee counts toward every
    /// required role they hold.
    private func staffingIssues(for shift: FfiShiftInfo) -> [StaffingIssue] {
        let entries = entriesByShift[shift.id] ?? []
        let filled = entries.count
        var issues: [StaffingIssue] = []

        func issue(_ severity: StaffingIssue.Severity, role: String?, filled: Int, needed: Int) -> StaffingIssue {
            StaffingIssue(
                shiftId: shift.id, severity: severity, weekday: shift.weekday,
                date: shift.date, startTime: shift.startTime, endTime: shift.endTime,
                role: role, filled: filled, needed: needed
            )
        }

        if filled < Int(shift.minEmployees) {
            issues.append(issue(.warning, role: nil, filled: filled, needed: Int(shift.minEmployees)))
        }
        for req in shift.roleRequirements where req.minCount > 0 {
            let covered = entries.filter {
                employeesById[$0.employeeId]?.roles.contains(req.role) ?? false
            }.count
            if covered < Int(req.minCount) {
                issues.append(issue(.warning, role: req.role, filled: covered, needed: Int(req.minCount)))
            }
        }
        if filled >= Int(shift.minEmployees) && filled < Int(shift.maxEmployees) {
            issues.append(issue(.note, role: nil, filled: filled, needed: Int(shift.maxEmployees)))
        }
        return issues
    }

    var staffingWarnings: [StaffingIssue] { staffingIssues.filter { $0.severity == .warning } }
    var staffingNotes: [StaffingIssue] { staffingIssues.filter { $0.severity == .note } }
    var hasStaffingIssues: Bool { !staffingIssues.isEmpty }

    /// Pending scroll-to-shift + open-editor request, consumed by the grid.
    /// Set via `requestShiftFocus` after the warnings sheet dismisses.
    var shiftFocusRequest: ShiftFocusRequest?

    func requestShiftFocus(_ shiftId: Int64) {
        shiftFocusRequest = ShiftFocusRequest(shiftId: shiftId, token: UUID())
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
        do {
            _ = try await service.runSchedule(weekStart: selectedWeekStart)
            isDirty = true
            await loadSchedule()
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
        lastWeekStepDirection = weeks < 0 ? -1 : 1
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
        guard let offset = AvailabilityWeekMath.weekdayIndex[weekday] else { return selectedWeekStart }
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
        AvailabilityWeekMath.weekdayOrder
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
