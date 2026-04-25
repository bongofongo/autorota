import AutorotaKit
import Foundation

/// Decorator that wraps any `AutorotaServiceProtocol` and throws
/// `LicenseError.readOnly` on every mutation when the license gate is
/// read-only. Reads pass through unchanged.
///
/// Reads `LicenseGate.shared` (lock-protected, sync) at the moment of each
/// mutation. The gate is updated by `LicenseService` whenever `state` changes.
///
/// **When adding a new method to `AutorotaServiceProtocol`**: classify it as a
/// read or a mutation. Reads pass through; mutations call `try check()` first.
struct GatedAutorotaService: AutorotaServiceProtocol {
    let inner: AutorotaServiceProtocol
    private let gate: LicenseGate

    init(inner: AutorotaServiceProtocol = LiveAutorotaService(), gate: LicenseGate = .shared) {
        self.inner = inner
        self.gate = gate
    }

    private func check() throws {
        guard gate.allowsMutation else { throw LicenseError.readOnly }
    }

    // MARK: - Roles
    func listRoles() async throws -> [FfiRole] { try await inner.listRoles() }
    func createRole(name: String) async throws -> Int64 {
        try check(); return try await inner.createRole(name: name)
    }
    func updateRole(id: Int64, name: String) async throws {
        try check(); try await inner.updateRole(id: id, name: name)
    }
    func deleteRole(id: Int64) async throws {
        try check(); try await inner.deleteRole(id: id)
    }

    // MARK: - Employees
    func listEmployees() async throws -> [FfiEmployee] { try await inner.listEmployees() }
    func createEmployee(_ employee: FfiEmployee) async throws -> Int64 {
        try check(); return try await inner.createEmployee(employee)
    }
    func updateEmployee(_ employee: FfiEmployee) async throws {
        try check(); try await inner.updateEmployee(employee)
    }
    func deleteEmployee(id: Int64) async throws {
        try check(); try await inner.deleteEmployee(id: id)
    }

    // MARK: - Shift Templates
    func listShiftTemplates() async throws -> [FfiShiftTemplate] { try await inner.listShiftTemplates() }
    func createShiftTemplate(_ template: FfiShiftTemplate) async throws -> Int64 {
        try check(); return try await inner.createShiftTemplate(template)
    }
    func updateShiftTemplate(_ template: FfiShiftTemplate) async throws {
        try check(); try await inner.updateShiftTemplate(template)
    }
    func deleteShiftTemplate(id: Int64) async throws {
        try check(); try await inner.deleteShiftTemplate(id: id)
    }

    // MARK: - Schedule
    func getWeekSchedule(weekStart: String) async throws -> FfiWeekSchedule? {
        try await inner.getWeekSchedule(weekStart: weekStart)
    }
    func runSchedule(weekStart: String) async throws -> FfiScheduleResult {
        try check(); return try await inner.runSchedule(weekStart: weekStart)
    }
    func materialiseWeek(weekStart: String) async throws -> Int64 {
        try check(); return try await inner.materialiseWeek(weekStart: weekStart)
    }
    func createEmptyWeek(weekStart: String) async throws -> Int64 {
        try check(); return try await inner.createEmptyWeek(weekStart: weekStart)
    }
    func deleteWeek(weekStart: String) async throws {
        try check(); try await inner.deleteWeek(weekStart: weekStart)
    }

    // MARK: - Assignments
    func createAssignment(_ assignment: FfiAssignment) async throws -> Int64 {
        try check(); return try await inner.createAssignment(assignment)
    }
    func updateAssignmentStatus(id: Int64, status: String) async throws {
        try check(); try await inner.updateAssignmentStatus(id: id, status: status)
    }
    func swapAssignments(idA: Int64, idB: Int64) async throws {
        try check(); try await inner.swapAssignments(idA: idA, idB: idB)
    }
    func deleteAssignment(id: Int64) async throws {
        try check(); try await inner.deleteAssignment(id: id)
    }
    func moveAssignment(id: Int64, newShiftId: Int64) async throws {
        try check(); try await inner.moveAssignment(id: id, newShiftId: newShiftId)
    }

    // MARK: - Shifts
    func deleteShift(id: Int64) async throws {
        try check(); try await inner.deleteShift(id: id)
    }
    func updateShiftTimes(id: Int64, startTime: String, endTime: String) async throws {
        try check(); try await inner.updateShiftTimes(id: id, startTime: startTime, endTime: endTime)
    }
    func createAdHocShift(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String) async throws -> Int64 {
        try check()
        return try await inner.createAdHocShift(rotaId: rotaId, date: date, startTime: startTime, endTime: endTime, requiredRole: requiredRole)
    }
    func listShiftsForRota(rotaId: Int64) async throws -> [FfiShift] {
        try await inner.listShiftsForRota(rotaId: rotaId)
    }

    // MARK: - Shift History
    func listEmployeeShiftHistory(employeeId: Int64) async throws -> [FfiEmployeeShiftRecord] {
        try await inner.listEmployeeShiftHistory(employeeId: employeeId)
    }
    func listAllShiftHistory(startDate: String?, endDate: String?) async throws -> [FfiEmployeeShiftRecord] {
        try await inner.listAllShiftHistory(startDate: startDate, endDate: endDate)
    }

    // MARK: - Overrides
    func upsertEmployeeAvailabilityOverride(_ o: FfiEmployeeAvailabilityOverride) async throws -> Int64 {
        try check(); return try await inner.upsertEmployeeAvailabilityOverride(o)
    }
    func getEmployeeAvailabilityOverride(employeeId: Int64, date: String) async throws -> FfiEmployeeAvailabilityOverride? {
        try await inner.getEmployeeAvailabilityOverride(employeeId: employeeId, date: date)
    }
    func listEmployeeAvailabilityOverrides(employeeId: Int64) async throws -> [FfiEmployeeAvailabilityOverride] {
        try await inner.listEmployeeAvailabilityOverrides(employeeId: employeeId)
    }
    func listAllEmployeeAvailabilityOverrides() async throws -> [FfiEmployeeAvailabilityOverride] {
        try await inner.listAllEmployeeAvailabilityOverrides()
    }
    func deleteEmployeeAvailabilityOverride(id: Int64) async throws {
        try check(); try await inner.deleteEmployeeAvailabilityOverride(id: id)
    }
    func upsertShiftTemplateOverride(_ o: FfiShiftTemplateOverride) async throws -> Int64 {
        try check(); return try await inner.upsertShiftTemplateOverride(o)
    }
    func getShiftTemplateOverride(templateId: Int64, date: String) async throws -> FfiShiftTemplateOverride? {
        try await inner.getShiftTemplateOverride(templateId: templateId, date: date)
    }
    func listShiftTemplateOverridesForTemplate(templateId: Int64) async throws -> [FfiShiftTemplateOverride] {
        try await inner.listShiftTemplateOverridesForTemplate(templateId: templateId)
    }
    func listAllShiftTemplateOverrides() async throws -> [FfiShiftTemplateOverride] {
        try await inner.listAllShiftTemplateOverrides()
    }
    func deleteShiftTemplateOverride(id: Int64) async throws {
        try check(); try await inner.deleteShiftTemplateOverride(id: id)
    }

    // MARK: - Saves
    func createSave(rotaId: Int64) async throws -> Int64 {
        try check(); return try await inner.createSave(rotaId: rotaId)
    }
    func diffRota(rotaId: Int64) async throws -> [FfiShiftDiff] {
        try await inner.diffRota(rotaId: rotaId)
    }
    func diffRotaDetailed(rotaId: Int64) async throws -> [FfiChangeDetail] {
        try await inner.diffRotaDetailed(rotaId: rotaId)
    }
    func listSaves(rotaId: Int64?) async throws -> [FfiSave] {
        try await inner.listSaves(rotaId: rotaId)
    }
    func getSaveDetail(saveId: Int64) async throws -> FfiSaveDetail? {
        try await inner.getSaveDetail(saveId: saveId)
    }
    func rotaHasSaves(rotaId: Int64) async throws -> Bool {
        try await inner.rotaHasSaves(rotaId: rotaId)
    }
    func diffSavesDetailed(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail] {
        try await inner.diffSavesDetailed(oldSaveId: oldSaveId, newSaveId: newSaveId)
    }
    func diffSaveVsPrevious(saveId: Int64) async throws -> [FfiChangeDetail] {
        try await inner.diffSaveVsPrevious(saveId: saveId)
    }
    func restoreToSave(saveId: Int64) async throws -> FfiRestoreResult {
        try check(); return try await inner.restoreToSave(saveId: saveId)
    }
    func addSaveTag(saveId: Int64, tag: String) async throws {
        try check(); try await inner.addSaveTag(saveId: saveId, tag: tag)
    }
    func removeSaveTag(saveId: Int64, tag: String) async throws {
        try check(); try await inner.removeSaveTag(saveId: saveId, tag: tag)
    }

    // MARK: - Export
    func exportWeekSchedule(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult {
        try await inner.exportWeekSchedule(weekStart: weekStart, config: config)
    }
    func exportEmployeeSchedule(config: FfiEmployeeExportConfig) async throws -> FfiExportResult {
        try await inner.exportEmployeeSchedule(config: config)
    }
    func exportEmployeeBundle(config: FfiEmployeeExportConfig) async throws -> [FfiExportResult] {
        try await inner.exportEmployeeBundle(config: config)
    }
    func exportPreviewFull(config: FfiExportConfig) async throws -> FfiExportResult {
        try await inner.exportPreviewFull(config: config)
    }
    func exportPreviewEmployee(config: FfiEmployeeExportConfig) async throws -> FfiExportResult {
        try await inner.exportPreviewEmployee(config: config)
    }

    // MARK: - Roster Import
    func parseRosterFile(bytes: Data, formatHint: String, strategy: String) async throws -> FfiParsedRoster {
        try await inner.parseRosterFile(bytes: bytes, formatHint: formatHint, strategy: strategy)
    }
    func applyRosterImport(rows: [FfiParsedEmployeeRow]) async throws -> FfiImportSummary {
        try check(); return try await inner.applyRosterImport(rows: rows)
    }

    // MARK: - Availability Progress
    func listAvailabilityProgress(weekStart: String) async throws -> [FfiAvailabilityProgress] {
        try await inner.listAvailabilityProgress(weekStart: weekStart)
    }
    func setAvailabilityProgress(employeeId: Int64, weekStart: String, done: Bool) async throws {
        try check(); try await inner.setAvailabilityProgress(employeeId: employeeId, weekStart: weekStart, done: done)
    }
}
