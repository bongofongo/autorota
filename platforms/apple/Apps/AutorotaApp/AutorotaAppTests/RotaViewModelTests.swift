import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("RotaViewModel")
struct RotaViewModelTests {

    // MARK: - Helpers

    private func makeShiftInfo(id: Int64 = 1, weekday: String = "Mon", start: String = "07:00", end: String = "12:00") -> FfiShiftInfo {
        FfiShiftInfo(
            id: id, date: "2026-03-23", weekday: weekday,
            startTime: start, endTime: end, requiredRole: "Barista",
            minEmployees: 1, maxEmployees: 2, roleRequirements: []
        )
    }

    private func makeEntry(assignmentId: Int64, shiftId: Int64, weekday: String = "Mon", employeeId: Int64 = 1) -> FfiScheduleEntry {
        FfiScheduleEntry(
            assignmentId: assignmentId, shiftId: shiftId, date: "2026-03-23",
            weekday: weekday, startTime: "07:00", endTime: "12:00",
            requiredRole: "Barista", employeeId: employeeId,
            employeeName: "Alice", status: "Proposed", maxEmployees: 2
        )
    }

    private func makeSchedule(shifts: [FfiShiftInfo] = [], entries: [FfiScheduleEntry] = []) -> FfiWeekSchedule {
        FfiWeekSchedule(
            rotaId: 1, weekStart: "2026-03-23",
            hasSaves: false,
            entries: entries, shifts: shifts
        )
    }

    // MARK: - Week category

    @Test func weekCategoryPast() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2020-01-06"
        #expect(vm.weekCategory == .past)
    }

    @Test func weekCategoryFuture() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2099-01-05"
        #expect(vm.weekCategory == .future)
    }

    @Test func weekCategoryCurrent() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = currentWeekStart()
        #expect(vm.weekCategory == .current)
    }

    // MARK: - shiftsByDay

    @Test func shiftsByDayGroupsAndSorts() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)

        let monEarly = makeShiftInfo(id: 1, weekday: "Mon", start: "07:00", end: "12:00")
        let monLate = makeShiftInfo(id: 2, weekday: "Mon", start: "14:00", end: "18:00")
        let wed = makeShiftInfo(id: 3, weekday: "Wed", start: "09:00", end: "15:00")

        vm.schedule = makeSchedule(shifts: [monLate, wed, monEarly])

        let grouped = vm.shiftsByDay
        #expect(grouped.count == 2)
        #expect(grouped[0].weekday == "Mon")
        #expect(grouped[0].shifts.count == 2)
        #expect(grouped[0].shifts[0].startTime == "07:00")
        #expect(grouped[1].weekday == "Wed")
    }

    @Test func shiftsByDayEmptySchedule() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.schedule = nil
        #expect(vm.shiftsByDay.isEmpty)
    }

    // MARK: - Assignments helper

    @Test func assignmentsForShiftFiltersCorrectly() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)

        let e1 = makeEntry(assignmentId: 10, shiftId: 1, employeeId: 1)
        let e2 = makeEntry(assignmentId: 11, shiftId: 1, employeeId: 2)
        let e3 = makeEntry(assignmentId: 12, shiftId: 2, employeeId: 3)

        vm.schedule = makeSchedule(entries: [e1, e2, e3])

        #expect(vm.assignments(for: 1).count == 2)
        #expect(vm.assignments(for: 2).count == 1)
        #expect(vm.assignments(for: 999).isEmpty)
    }

    // MARK: - Available employees

    @Test func availableEmployeesExcludesAssigned() async {
        let mock = MockAutorotaService()
        let emp1 = FfiEmployee(
            id: 1, firstName: "Alice", lastName: "S", nickname: nil, displayName: "Alice S",
            roles: ["Barista"], startDate: "2025-01-01", targetWeeklyHours: 20,
            weeklyHoursDeviation: 5, maxDailyHours: 8, notes: nil, bankDetails: nil,
            phone: nil, email: nil, preferredContact: nil, hourlyWage: nil, wageCurrency: nil, defaultAvailability: [], availability: [], deleted: false
        )
        let emp2 = FfiEmployee(
            id: 2, firstName: "Bob", lastName: "J", nickname: nil, displayName: "Bob J",
            roles: ["Barista"], startDate: "2025-01-01", targetWeeklyHours: 20,
            weeklyHoursDeviation: 5, maxDailyHours: 8, notes: nil, bankDetails: nil,
            phone: nil, email: nil, preferredContact: nil, hourlyWage: nil, wageCurrency: nil, defaultAvailability: [], availability: [], deleted: false
        )
        mock.stubbedEmployees = [emp1, emp2]
        let vm = RotaViewModel(service: mock)

        let entry = makeEntry(assignmentId: 10, shiftId: 1, employeeId: 1)
        vm.schedule = makeSchedule(entries: [entry])
        vm.employees = [emp1, emp2]

        let available = vm.availableEmployees(for: 1)
        #expect(available.count == 1)
        #expect(available[0].id == 2)
    }

    // MARK: - Conflict detection

    private func makeEmployee(id: Int64 = 1, availability: [AvailabilitySlot] = []) -> FfiEmployee {
        FfiEmployee(
            id: id, firstName: "Emp\(id)", lastName: "X", nickname: nil, displayName: "Emp\(id)",
            roles: ["Barista"], startDate: "2025-01-01", targetWeeklyHours: 20,
            weeklyHoursDeviation: 5, maxDailyHours: 8, notes: nil, bankDetails: nil,
            phone: nil, email: nil, preferredContact: nil, hourlyWage: nil, wageCurrency: nil,
            defaultAvailability: [], availability: availability, deleted: false
        )
    }

    /// Monday availability slots over the default shift window (07:00–12:00).
    private func monSlots(_ state: String, hours: ClosedRange<Int> = 7...11) -> [AvailabilitySlot] {
        hours.map { AvailabilitySlot(weekday: "Mon", hour: UInt8($0), state: state) }
    }

    private func makeOverride(employeeId: Int64 = 1, source: String, state: String, hours: ClosedRange<Int> = 7...11) -> FfiEmployeeAvailabilityOverride {
        FfiEmployeeAvailabilityOverride(
            id: 1, employeeId: employeeId, date: "2026-03-23",
            availability: hours.map { DayAvailabilitySlot(hour: UInt8($0), state: state) },
            notes: nil, source: source
        )
    }

    /// Build a VM whose conflict caches are populated via `loadSchedule`.
    private func loadedVM(_ mock: MockAutorotaService) async -> RotaViewModel {
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2026-03-23"
        await vm.loadSchedule()
        return vm
    }

    @Test func conflictOverlapWithExistingBooking() async {
        let mock = MockAutorotaService()
        mock.stubbedEmployees = [makeEmployee(id: 1, availability: monSlots("Yes"))]
        // Emp 1 is already booked on shift 1 (07:00–12:00).
        mock.stubbedWeekSchedule = makeSchedule(entries: [makeEntry(assignmentId: 10, shiftId: 1, employeeId: 1)])
        let vm = await loadedVM(mock)
        // Candidate shift 2 (10:00–14:00) overlaps the existing booking.
        let c = vm.conflict(employeeId: 1, shift: makeShiftInfo(id: 2, start: "10:00", end: "14:00"))
        #expect(c == .overlap("07:00–12:00"))
    }

    @Test func conflictWeeklyNoAvailability() async {
        let mock = MockAutorotaService()
        mock.stubbedEmployees = [makeEmployee(id: 1, availability: monSlots("No"))]
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = await loadedVM(mock)
        #expect(vm.conflict(employeeId: 1, shift: makeShiftInfo()) == .noAvailability)
    }

    @Test func conflictExceptionOverride() async {
        let mock = MockAutorotaService()
        mock.stubbedEmployees = [makeEmployee(id: 1, availability: monSlots("Yes"))]
        mock.stubbedWeekSchedule = makeSchedule()
        mock.stubbedAvailabilityOverrides = [makeOverride(source: "exception", state: "No")]
        let vm = await loadedVM(mock)
        #expect(vm.conflict(employeeId: 1, shift: makeShiftInfo()) == .exception)
    }

    @Test func conflictManualDateOverride() async {
        let mock = MockAutorotaService()
        mock.stubbedEmployees = [makeEmployee(id: 1, availability: monSlots("Yes"))]
        mock.stubbedWeekSchedule = makeSchedule()
        mock.stubbedAvailabilityOverrides = [makeOverride(source: "manual", state: "No")]
        let vm = await loadedVM(mock)
        #expect(vm.conflict(employeeId: 1, shift: makeShiftInfo()) == .dateOverride)
    }

    @Test func conflictMaybeIsSoft() async {
        let mock = MockAutorotaService()
        // Empty availability resolves to Maybe over the window.
        mock.stubbedEmployees = [makeEmployee(id: 1, availability: [])]
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = await loadedVM(mock)
        let c = vm.conflict(employeeId: 1, shift: makeShiftInfo())
        #expect(c == .maybe)
        #expect(c?.isHard == false)
    }

    @Test func conflictNoneWhenAvailable() async {
        let mock = MockAutorotaService()
        mock.stubbedEmployees = [makeEmployee(id: 1, availability: monSlots("Yes"))]
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = await loadedVM(mock)
        #expect(vm.conflict(employeeId: 1, shift: makeShiftInfo()) == nil)
    }

    // MARK: - Swap state machine

    @Test func swapSelectAndCancel() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)

        #expect(vm.hasSwapSource == false)

        vm.selectSwapSource(assignmentId: 10, shiftId: 1)
        #expect(vm.hasSwapSource == true)
        #expect(vm.isSwapSource(assignmentId: 10) == true)
        #expect(vm.isSwapSource(assignmentId: 99) == false)

        vm.cancelSwap()
        #expect(vm.hasSwapSource == false)
    }

    @Test func swapToggleDeselectsSameSource() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)

        vm.selectSwapSource(assignmentId: 10, shiftId: 1)
        vm.selectSwapSource(assignmentId: 10, shiftId: 1)
        #expect(vm.hasSwapSource == false)
    }

    @Test func isSwapTargetRequiresDifferentShift() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)

        vm.selectSwapSource(assignmentId: 10, shiftId: 1)

        let sameShift = makeEntry(assignmentId: 11, shiftId: 1)
        let diffShift = makeEntry(assignmentId: 12, shiftId: 2)

        #expect(vm.isSwapTarget(entry: sameShift) == false)
        #expect(vm.isSwapTarget(entry: diffShift) == true)
    }

    @Test func executeSwapCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = RotaViewModel(service: mock)

        vm.selectSwapSource(assignmentId: 10, shiftId: 1)
        await vm.executeSwap(targetAssignmentId: 20)

        #expect(mock.callLog.contains("swapAssignments:10:20"))
        #expect(vm.hasSwapSource == false)
    }

    // MARK: - Edit mode

    @Test func enterEditModeWithExistingSchedule() async {
        let mock = MockAutorotaService()
        mock.stubbedWeekSchedule = makeSchedule()
        mock.stubbedEmployees = []
        mock.stubbedRoles = [FfiRole(id: 1, name: "Barista")]
        let vm = RotaViewModel(service: mock)
        vm.schedule = makeSchedule()

        await vm.enterEditMode()

        #expect(vm.isEditMode == true)
        #expect(vm.roles.count == 1)
        #expect(!mock.callLog.contains("materialiseWeek"))
    }

    @Test func enterEditModeWithoutScheduleMaterialises() async {
        let mock = MockAutorotaService()
        mock.stubbedWeekSchedule = makeSchedule()
        mock.stubbedEmployees = []
        mock.stubbedRoles = []
        let vm = RotaViewModel(service: mock)

        await vm.enterEditMode()

        #expect(mock.callLog.contains { $0.hasPrefix("materialiseWeek") })
        #expect(vm.isEditMode == true)
    }

    @Test func exitEditModeResetsFlags() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.isEditMode = true
        vm.pastUnlocked = true

        vm.exitEditMode()

        #expect(vm.isEditMode == false)
        #expect(vm.pastUnlocked == false)
    }

    // MARK: - Loading

    @Test func loadScheduleSetsSchedule() async {
        let mock = MockAutorotaService()
        let sched = makeSchedule(shifts: [makeShiftInfo()])
        mock.stubbedWeekSchedule = sched
        let vm = RotaViewModel(service: mock)

        await vm.loadSchedule()

        #expect(vm.schedule != nil)
        #expect(vm.schedule?.shifts.count == 1)
        #expect(vm.isLoading == false)
    }

    @Test func loadScheduleErrorSetsError() async {
        let mock = MockAutorotaService()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let vm = RotaViewModel(service: mock)

        await vm.loadSchedule()

        #expect(vm.error == "boom")
    }

    @Test func runScheduleCompletesAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedScheduleResult = FfiScheduleResult(assignments: [], warnings: [])
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2099-01-07" // future week bypasses confirmation gate

        await vm.runSchedule()

        #expect(mock.callLog.contains { $0.hasPrefix("runSchedule") })
        #expect(vm.isScheduling == false)
    }

    // MARK: - Staffing issues

    /// min 2 / max 3 with one entry → one under-minimum warning, no note.
    @Test func staffingIssuesUnderMinimumIsWarning() async {
        let mock = MockAutorotaService()
        var shift = makeShiftInfo()
        shift.minEmployees = 2
        shift.maxEmployees = 3
        mock.stubbedWeekSchedule = makeSchedule(
            shifts: [shift],
            entries: [makeEntry(assignmentId: 1, shiftId: shift.id)]
        )
        let vm = await loadedVM(mock)

        #expect(vm.staffingWarnings.count == 1)
        #expect(vm.staffingNotes.isEmpty)
        let warning = vm.staffingWarnings[0]
        #expect(warning.filled == 1)
        #expect(warning.needed == 2)
        #expect(warning.role == nil)
    }

    /// min 1 / max 3 with two entries → note only (2/3 staffed).
    @Test func staffingIssuesBelowMaximumIsNote() async {
        let mock = MockAutorotaService()
        var shift = makeShiftInfo()
        shift.minEmployees = 1
        shift.maxEmployees = 3
        mock.stubbedWeekSchedule = makeSchedule(
            shifts: [shift],
            entries: [
                makeEntry(assignmentId: 1, shiftId: shift.id, employeeId: 1),
                makeEntry(assignmentId: 2, shiftId: shift.id, employeeId: 2),
            ]
        )
        let vm = await loadedVM(mock)

        #expect(vm.staffingWarnings.isEmpty)
        #expect(vm.staffingNotes.count == 1)
        let note = vm.staffingNotes[0]
        #expect(note.filled == 2)
        #expect(note.needed == 3)
    }

    /// Overall min met but a per-role minimum unmet → role warning; below
    /// max also yields a note. Employee 2 lacks the Barista role.
    @Test func staffingIssuesUnmetRoleMinimumIsWarning() async {
        let mock = MockAutorotaService()
        var shift = makeShiftInfo()
        shift.minEmployees = 2
        shift.maxEmployees = 3
        shift.roleRequirements = [FfiRoleRequirement(role: "Barista", minCount: 2)]
        mock.stubbedWeekSchedule = makeSchedule(
            shifts: [shift],
            entries: [
                makeEntry(assignmentId: 1, shiftId: shift.id, employeeId: 1),
                makeEntry(assignmentId: 2, shiftId: shift.id, employeeId: 2),
            ]
        )
        var barista = makeEmployee(id: 1)
        barista.roles = ["Barista"]
        var waiter = makeEmployee(id: 2)
        waiter.roles = ["Waiter"]
        mock.stubbedEmployees = [barista, waiter]
        let vm = await loadedVM(mock)

        #expect(vm.staffingWarnings.count == 1)
        let warning = vm.staffingWarnings[0]
        #expect(warning.role == "Barista")
        #expect(warning.filled == 1)
        #expect(warning.needed == 2)
        #expect(vm.staffingNotes.count == 1)
    }

    /// At max on every shift → no issues at all.
    @Test func staffingIssuesFullyStaffedIsEmpty() async {
        let mock = MockAutorotaService()
        var shift = makeShiftInfo()
        shift.minEmployees = 1
        shift.maxEmployees = 1
        mock.stubbedWeekSchedule = makeSchedule(
            shifts: [shift],
            entries: [makeEntry(assignmentId: 1, shiftId: shift.id)]
        )
        let vm = await loadedVM(mock)

        #expect(vm.hasStaffingIssues == false)
    }

    /// Warnings sort ahead of notes regardless of weekday order.
    @Test func staffingIssuesWarningsSortBeforeNotes() async {
        let mock = MockAutorotaService()
        var monNote = makeShiftInfo(id: 1, weekday: "Mon")
        monNote.minEmployees = 1
        monNote.maxEmployees = 2
        var friWarning = makeShiftInfo(id: 2, weekday: "Fri")
        friWarning.minEmployees = 1
        friWarning.maxEmployees = 1
        mock.stubbedWeekSchedule = makeSchedule(
            shifts: [monNote, friWarning],
            entries: [makeEntry(assignmentId: 1, shiftId: 1)]
        )
        let vm = await loadedVM(mock)

        #expect(vm.staffingIssues.count == 2)
        #expect(vm.staffingIssues[0].severity == .warning)
        #expect(vm.staffingIssues[0].shiftId == 2)
        #expect(vm.staffingIssues[1].severity == .note)
    }

    /// Focus requests carry the shift id, and repeat requests for the same
    /// shift are distinct values so the grid's onChange re-fires.
    @Test func requestShiftFocusProducesDistinctRequests() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)

        vm.requestShiftFocus(42)
        let first = vm.shiftFocusRequest
        #expect(first?.shiftId == 42)

        vm.requestShiftFocus(42)
        let second = vm.shiftFocusRequest
        #expect(second?.shiftId == 42)
        #expect(first != second)
    }

    /// Clearing the schedule clears the computed issues.
    @Test func staffingIssuesClearOnNilSchedule() async {
        let mock = MockAutorotaService()
        var shift = makeShiftInfo()
        shift.minEmployees = 2
        mock.stubbedWeekSchedule = makeSchedule(shifts: [shift])
        let vm = await loadedVM(mock)
        #expect(vm.hasStaffingIssues == true)

        vm.schedule = nil

        #expect(vm.hasStaffingIssues == false)
    }

    // MARK: - Generate confirmation dialog

    @Test func generateOnPastWeekWithoutScheduleShowsConfirmation() async {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2020-01-06" // past week
        vm.schedule = nil

        await vm.runSchedule()

        #expect(vm.showGenerateConfirmation == true)
        #expect(!mock.callLog.contains { $0.hasPrefix("runSchedule") })
    }

    @Test func generateOnCurrentWeekWithoutScheduleShowsConfirmation() async {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = currentWeekStart()
        vm.schedule = nil

        await vm.runSchedule()

        #expect(vm.showGenerateConfirmation == true)
        #expect(!mock.callLog.contains { $0.hasPrefix("runSchedule") })
    }

    @Test func generateOnFutureWeekRunsScheduleNormally() async {
        let mock = MockAutorotaService()
        mock.stubbedScheduleResult = FfiScheduleResult(assignments: [], warnings: [])
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2099-01-07" // future week

        await vm.runSchedule()

        #expect(vm.showGenerateConfirmation == false)
        #expect(mock.callLog.contains { $0.hasPrefix("runSchedule") })
    }

    @Test func generateOnPastWeekWithExistingScheduleRunsScheduleNormally() async {
        let mock = MockAutorotaService()
        mock.stubbedScheduleResult = FfiScheduleResult(assignments: [], warnings: [])
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2020-01-06" // past week
        vm.schedule = makeSchedule()         // schedule already exists

        await vm.runSchedule()

        #expect(vm.showGenerateConfirmation == false)
        #expect(mock.callLog.contains { $0.hasPrefix("runSchedule") })
    }

    @Test func createFromTemplateCallsMaterialiseWeekAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2020-01-06"

        await vm.createFromTemplate()

        #expect(mock.callLog.contains { $0.hasPrefix("materialiseWeek") })
        #expect(mock.callLog.contains { $0.hasPrefix("getWeekSchedule") })
        #expect(vm.schedule != nil)
        #expect(vm.isScheduling == false)
    }

    @Test func createEmptyCallsCreateEmptyWeekAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2020-01-06"

        await vm.createEmpty()

        #expect(mock.callLog.contains { $0.hasPrefix("createEmptyWeek") })
        #expect(mock.callLog.contains { $0.hasPrefix("getWeekSchedule") })
        #expect(vm.schedule != nil)
        #expect(vm.isScheduling == false)
    }

    @Test func createFromTemplateErrorSetsError() async {
        let mock = MockAutorotaService()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "template error"])
        let vm = RotaViewModel(service: mock)

        await vm.createFromTemplate()

        #expect(vm.error == "template error")
        #expect(vm.isScheduling == false)
    }

    @Test func createEmptyErrorSetsError() async {
        let mock = MockAutorotaService()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty error"])
        let vm = RotaViewModel(service: mock)

        await vm.createEmpty()

        #expect(vm.error == "empty error")
        #expect(vm.isScheduling == false)
    }

    @Test func resetModesResetsConfirmationFlag() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.showGenerateConfirmation = true

        vm.resetModes()

        #expect(vm.showGenerateConfirmation == false)
    }

    // MARK: - Delete schedule

    @Test func deleteScheduleCallsServiceClearsScheduleAndExitsEditMode() async {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2020-01-06"
        vm.schedule = makeSchedule()
        vm.isEditMode = true

        await vm.deleteSchedule()

        #expect(mock.callLog.contains { $0.hasPrefix("deleteWeek") })
        #expect(vm.schedule == nil)
        #expect(vm.isEditMode == false)
    }

    @Test func deleteScheduleErrorSetsError() async {
        let mock = MockAutorotaService()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "delete error"])
        let vm = RotaViewModel(service: mock)
        vm.schedule = makeSchedule()
        vm.isEditMode = true

        await vm.deleteSchedule()

        #expect(vm.error == "delete error")
        #expect(vm.isEditMode == true)
    }

    @Test func resetModesResetsDeleteConfirmationFlag() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        vm.showDeleteScheduleConfirmation = true

        vm.resetModes()

        #expect(vm.showDeleteScheduleConfirmation == false)
    }

    // MARK: - allWeekdays

    @Test func allWeekdaysIsComplete() {
        let mock = MockAutorotaService()
        let vm = RotaViewModel(service: mock)
        #expect(vm.allWeekdays == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    }
}
