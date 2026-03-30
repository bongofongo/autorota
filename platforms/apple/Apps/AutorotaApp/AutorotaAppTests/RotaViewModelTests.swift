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
            minEmployees: 1, maxEmployees: 2
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
            rotaId: 1, weekStart: "2026-03-23", finalized: false,
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
            hourlyWage: nil, wageCurrency: nil, defaultAvailability: [], availability: [], deleted: false
        )
        let emp2 = FfiEmployee(
            id: 2, firstName: "Bob", lastName: "J", nickname: nil, displayName: "Bob J",
            roles: ["Barista"], startDate: "2025-01-01", targetWeeklyHours: 20,
            weeklyHoursDeviation: 5, maxDailyHours: 8, notes: nil, bankDetails: nil,
            hourlyWage: nil, wageCurrency: nil, defaultAvailability: [], availability: [], deleted: false
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

    @Test func runScheduleSetsWarnings() async {
        let mock = MockAutorotaService()
        let warning = FfiShortfallWarning(
            shiftId: 1, needed: 2, filled: 1, weekday: "Mon",
            startTime: "07:00", endTime: "12:00", requiredRole: "Barista"
        )
        mock.stubbedScheduleResult = FfiScheduleResult(assignments: [], warnings: [warning])
        mock.stubbedWeekSchedule = makeSchedule()
        let vm = RotaViewModel(service: mock)
        vm.selectedWeekStart = "2099-01-07" // future week bypasses confirmation gate

        await vm.runSchedule()

        #expect(vm.warnings.count == 1)
        #expect(vm.isScheduling == false)
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
