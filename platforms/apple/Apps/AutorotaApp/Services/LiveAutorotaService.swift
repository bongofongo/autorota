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
    func listAllShiftHistory(startDate: String?, endDate: String?) async throws -> [FfiEmployeeShiftRecord] { try await listAllShiftHistoryAsync(startDate: startDate, endDate: endDate) }

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

    // Saves
    func createSave(rotaId: Int64) async throws -> Int64 {
        let id = try await createSaveAsync(rotaId: rotaId)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return id
    }
    func diffRota(rotaId: Int64) async throws -> [FfiShiftDiff] { try await diffRotaAsync(rotaId: rotaId) }
    func diffRotaDetailed(rotaId: Int64) async throws -> [FfiChangeDetail] {
        try await diffRotaDetailedAsync(rotaId: rotaId)
    }
    func listSaves(rotaId: Int64?) async throws -> [FfiSave] { try await listSavesAsync(rotaId: rotaId) }
    func getSaveDetail(saveId: Int64) async throws -> FfiSaveDetail? { try await getSaveDetailAsync(saveId: saveId) }
    func rotaHasSaves(rotaId: Int64) async throws -> Bool { try await rotaHasSavesAsync(rotaId: rotaId) }
    func diffSavesDetailed(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail] {
        try await diffSavesDetailedAsync(oldSaveId: oldSaveId, newSaveId: newSaveId)
    }
    func diffSaveVsPrevious(saveId: Int64) async throws -> [FfiChangeDetail] {
        try await diffSaveVsPreviousAsync(saveId: saveId)
    }
    func restoreToSave(saveId: Int64) async throws -> FfiRestoreResult {
        let result = try await restoreToSaveAsync(saveId: saveId)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        return result
    }
    func addSaveTag(saveId: Int64, tag: String) async throws {
        try await addSaveTagAsync(saveId: saveId, tag: tag)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }
    func removeSaveTag(saveId: Int64, tag: String) async throws {
        try await removeSaveTagAsync(saveId: saveId, tag: tag)
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    }

    func exportWeekSchedule(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult { try await exportWeekScheduleAsync(weekStart: weekStart, config: config) }
    func exportEmployeeSchedule(config: FfiEmployeeExportConfig) async throws -> FfiExportResult { try await exportEmployeeScheduleAsync(config: config) }

    // Availability Progress
    func listAvailabilityProgress(weekStart: String) async throws -> [FfiAvailabilityProgress] { try await listAvailabilityProgressAsync(weekStart: weekStart) }
    func setAvailabilityProgress(employeeId: Int64, weekStart: String, done: Bool) async throws { try await setAvailabilityProgressAsync(employeeId: employeeId, weekStart: weekStart, done: done) }
}
