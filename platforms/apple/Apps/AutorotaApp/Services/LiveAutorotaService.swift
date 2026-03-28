import AutorotaKit

/// Production implementation that delegates to the real AutorotaKit async wrappers.
struct LiveAutorotaService: AutorotaServiceProtocol {
    func listRoles() async throws -> [FfiRole] { try await listRolesAsync() }
    func createRole(name: String) async throws -> Int64 { try await createRoleAsync(name: name) }
    func updateRole(id: Int64, name: String) async throws { try await updateRoleAsync(id: id, name: name) }
    func deleteRole(id: Int64) async throws { try await deleteRoleAsync(id: id) }

    func listEmployees() async throws -> [FfiEmployee] { try await listEmployeesAsync() }
    func createEmployee(_ employee: FfiEmployee) async throws -> Int64 { try await createEmployeeAsync(employee) }
    func updateEmployee(_ employee: FfiEmployee) async throws { try await updateEmployeeAsync(employee) }
    func deleteEmployee(id: Int64) async throws { try await deleteEmployeeAsync(id: id) }

    func listShiftTemplates() async throws -> [FfiShiftTemplate] { try await listShiftTemplatesAsync() }
    func createShiftTemplate(_ template: FfiShiftTemplate) async throws -> Int64 { try await createShiftTemplateAsync(template) }
    func updateShiftTemplate(_ template: FfiShiftTemplate) async throws { try await updateShiftTemplateAsync(template) }
    func deleteShiftTemplate(id: Int64) async throws { try await deleteShiftTemplateAsync(id: id) }

    func getWeekSchedule(weekStart: String) async throws -> FfiWeekSchedule? { try await getWeekScheduleAsync(weekStart: weekStart) }
    func runSchedule(weekStart: String) async throws -> FfiScheduleResult { try await runScheduleAsync(weekStart: weekStart) }
    func materialiseWeek(weekStart: String) async throws -> Int64 { try await materialiseWeekAsync(weekStart: weekStart) }
    func createEmptyWeek(weekStart: String) async throws -> Int64 { try await createEmptyWeekAsync(weekStart: weekStart) }
    func deleteWeek(weekStart: String) async throws { try await deleteWeekAsync(weekStart: weekStart) }
    func finalizeRota(id: Int64) async throws { try await finalizeRotaAsync(id: id) }

    func createAssignment(_ assignment: FfiAssignment) async throws -> Int64 { try await createAssignmentAsync(assignment) }
    func updateAssignmentStatus(id: Int64, status: String) async throws { try await updateAssignmentStatusAsync(id: id, status: status) }
    func swapAssignments(idA: Int64, idB: Int64) async throws { try await swapAssignmentsAsync(idA: idA, idB: idB) }
    func deleteAssignment(id: Int64) async throws { try await deleteAssignmentAsync(id: id) }
    func moveAssignment(id: Int64, newShiftId: Int64) async throws { try await moveAssignmentAsync(id: id, newShiftId: newShiftId) }

    func deleteShift(id: Int64) async throws { try await deleteShiftAsync(id: id) }
    func updateShiftTimes(id: Int64, startTime: String, endTime: String) async throws { try await updateShiftTimesAsync(id: id, startTime: startTime, endTime: endTime) }
    func createAdHocShift(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String) async throws -> Int64 { try await createAdHocShiftAsync(rotaId: rotaId, date: date, startTime: startTime, endTime: endTime, requiredRole: requiredRole) }
    func listShiftsForRota(rotaId: Int64) async throws -> [FfiShift] { try await listShiftsForRotaAsync(rotaId: rotaId) }

    func listEmployeeShiftHistory(employeeId: Int64) async throws -> [FfiEmployeeShiftRecord] { try await listEmployeeShiftHistoryAsync(employeeId: employeeId) }

    func upsertEmployeeAvailabilityOverride(_ o: FfiEmployeeAvailabilityOverride) async throws -> Int64 { try await upsertEmployeeAvailabilityOverrideAsync(override_: o) }
    func getEmployeeAvailabilityOverride(employeeId: Int64, date: String) async throws -> FfiEmployeeAvailabilityOverride? { try await getEmployeeAvailabilityOverrideAsync(employeeId: employeeId, date: date) }
    func listEmployeeAvailabilityOverrides(employeeId: Int64) async throws -> [FfiEmployeeAvailabilityOverride] { try await listEmployeeAvailabilityOverridesAsync(employeeId: employeeId) }
    func listAllEmployeeAvailabilityOverrides() async throws -> [FfiEmployeeAvailabilityOverride] { try await listAllEmployeeAvailabilityOverridesAsync() }
    func deleteEmployeeAvailabilityOverride(id: Int64) async throws { try await deleteEmployeeAvailabilityOverrideAsync(id: id) }
    func upsertShiftTemplateOverride(_ o: FfiShiftTemplateOverride) async throws -> Int64 { try await upsertShiftTemplateOverrideAsync(override_: o) }
    func getShiftTemplateOverride(templateId: Int64, date: String) async throws -> FfiShiftTemplateOverride? { try await getShiftTemplateOverrideAsync(templateId: templateId, date: date) }
    func listShiftTemplateOverridesForTemplate(templateId: Int64) async throws -> [FfiShiftTemplateOverride] { try await listShiftTemplateOverridesForTemplateAsync(templateId: templateId) }
    func listAllShiftTemplateOverrides() async throws -> [FfiShiftTemplateOverride] { try await listAllShiftTemplateOverridesAsync() }
    func deleteShiftTemplateOverride(id: Int64) async throws { try await deleteShiftTemplateOverrideAsync(id: id) }
}
