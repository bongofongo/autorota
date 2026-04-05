import AutorotaKit
import Foundation

extension Notification.Name {
    static let autorotaDataChanged = Notification.Name("autorotaDataChanged")
}

/// Production implementation that delegates to the real AutorotaKit async wrappers.
struct LiveAutorotaService: AutorotaServiceProtocol {
    func listRoles() async throws -> [FfiRole] { try await listRolesAsync() }
    func createRole(name: String) async throws -> Int64 {
        let id = try await createRoleAsync(name: name)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func updateRole(id: Int64, name: String) async throws {
        try await updateRoleAsync(id: id, name: name)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func deleteRole(id: Int64) async throws {
        try await deleteRoleAsync(id: id)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }

    func listEmployees() async throws -> [FfiEmployee] { try await listEmployeesAsync() }
    func createEmployee(_ employee: FfiEmployee) async throws -> Int64 {
        let id = try await createEmployeeAsync(employee)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func updateEmployee(_ employee: FfiEmployee) async throws {
        try await updateEmployeeAsync(employee)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func deleteEmployee(id: Int64) async throws {
        try await deleteEmployeeAsync(id: id)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }

    func listShiftTemplates() async throws -> [FfiShiftTemplate] { try await listShiftTemplatesAsync() }
    func createShiftTemplate(_ template: FfiShiftTemplate) async throws -> Int64 {
        let id = try await createShiftTemplateAsync(template)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func updateShiftTemplate(_ template: FfiShiftTemplate) async throws {
        try await updateShiftTemplateAsync(template)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func deleteShiftTemplate(id: Int64) async throws {
        try await deleteShiftTemplateAsync(id: id)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }

    func getWeekSchedule(weekStart: String) async throws -> FfiWeekSchedule? { try await getWeekScheduleAsync(weekStart: weekStart) }
    func runSchedule(weekStart: String) async throws -> FfiScheduleResult {
        let result = try await runScheduleAsync(weekStart: weekStart)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return result
    }
    func materialiseWeek(weekStart: String) async throws -> Int64 {
        let id = try await materialiseWeekAsync(weekStart: weekStart)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func createEmptyWeek(weekStart: String) async throws -> Int64 {
        let id = try await createEmptyWeekAsync(weekStart: weekStart)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func deleteWeek(weekStart: String) async throws {
        try await deleteWeekAsync(weekStart: weekStart)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func finalizeRota(id: Int64) async throws {
        try await finalizeRotaAsync(id: id)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }

    func createAssignment(_ assignment: FfiAssignment) async throws -> Int64 {
        let id = try await createAssignmentAsync(assignment)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func updateAssignmentStatus(id: Int64, status: String) async throws {
        try await updateAssignmentStatusAsync(id: id, status: status)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func swapAssignments(idA: Int64, idB: Int64) async throws {
        try await swapAssignmentsAsync(idA: idA, idB: idB)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func deleteAssignment(id: Int64) async throws {
        try await deleteAssignmentAsync(id: id)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func moveAssignment(id: Int64, newShiftId: Int64) async throws {
        try await moveAssignmentAsync(id: id, newShiftId: newShiftId)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }

    func deleteShift(id: Int64) async throws {
        try await deleteShiftAsync(id: id)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func updateShiftTimes(id: Int64, startTime: String, endTime: String) async throws {
        try await updateShiftTimesAsync(id: id, startTime: startTime, endTime: endTime)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func createAdHocShift(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String) async throws -> Int64 {
        let id = try await createAdHocShiftAsync(rotaId: rotaId, date: date, startTime: startTime, endTime: endTime, requiredRole: requiredRole)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func listShiftsForRota(rotaId: Int64) async throws -> [FfiShift] { try await listShiftsForRotaAsync(rotaId: rotaId) }

    func listEmployeeShiftHistory(employeeId: Int64) async throws -> [FfiEmployeeShiftRecord] { try await listEmployeeShiftHistoryAsync(employeeId: employeeId) }

    func upsertEmployeeAvailabilityOverride(_ o: FfiEmployeeAvailabilityOverride) async throws -> Int64 {
        let id = try await upsertEmployeeAvailabilityOverrideAsync(override_: o)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func getEmployeeAvailabilityOverride(employeeId: Int64, date: String) async throws -> FfiEmployeeAvailabilityOverride? { try await getEmployeeAvailabilityOverrideAsync(employeeId: employeeId, date: date) }
    func listEmployeeAvailabilityOverrides(employeeId: Int64) async throws -> [FfiEmployeeAvailabilityOverride] { try await listEmployeeAvailabilityOverridesAsync(employeeId: employeeId) }
    func listAllEmployeeAvailabilityOverrides() async throws -> [FfiEmployeeAvailabilityOverride] { try await listAllEmployeeAvailabilityOverridesAsync() }
    func deleteEmployeeAvailabilityOverride(id: Int64) async throws {
        try await deleteEmployeeAvailabilityOverrideAsync(id: id)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func upsertShiftTemplateOverride(_ o: FfiShiftTemplateOverride) async throws -> Int64 {
        let id = try await upsertShiftTemplateOverrideAsync(override_: o)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func getShiftTemplateOverride(templateId: Int64, date: String) async throws -> FfiShiftTemplateOverride? { try await getShiftTemplateOverrideAsync(templateId: templateId, date: date) }
    func listShiftTemplateOverridesForTemplate(templateId: Int64) async throws -> [FfiShiftTemplateOverride] { try await listShiftTemplateOverridesForTemplateAsync(templateId: templateId) }
    func listAllShiftTemplateOverrides() async throws -> [FfiShiftTemplateOverride] { try await listAllShiftTemplateOverridesAsync() }
    func deleteShiftTemplateOverride(id: Int64) async throws {
        try await deleteShiftTemplateOverrideAsync(id: id)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }

    // Staging & Commits
    func stageShifts(shiftIds: [Int64]) async throws {
        try await stageShiftsAsync(shiftIds: shiftIds)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func stageDay(rotaId: Int64, date: String) async throws {
        try await stageDayAsync(rotaId: rotaId, date: date)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func stageWeek(rotaId: Int64) async throws {
        try await stageWeekAsync(rotaId: rotaId)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func unstageShifts(shiftIds: [Int64]) async throws {
        try await unstageShiftsAsync(shiftIds: shiftIds)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func unstageDay(rotaId: Int64, date: String) async throws {
        try await unstageDayAsync(rotaId: rotaId, date: date)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func unstageWeek(rotaId: Int64) async throws {
        try await unstageWeekAsync(rotaId: rotaId)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func getStagingState(rotaId: Int64) async throws -> FfiStagingState { try await getStagingStateAsync(rotaId: rotaId) }
    func commitStagedShifts(rotaId: Int64) async throws -> Int64 {
        let id = try await commitStagedShiftsAsync(rotaId: rotaId)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func listCommits(rotaId: Int64?) async throws -> [FfiCommit] { try await listCommitsAsync(rotaId: rotaId) }
    func getCommitDetail(commitId: Int64) async throws -> FfiCommitDetail? { try await getCommitDetailAsync(commitId: commitId) }
    func rotaIsCommitted(rotaId: Int64) async throws -> Bool { try await rotaIsCommittedAsync(rotaId: rotaId) }

    func exportWeekSchedule(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult { try await exportWeekScheduleAsync(weekStart: weekStart, config: config) }
}
