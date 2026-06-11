import Foundation
import AutorotaKit

/// Abstraction over AutorotaKit async functions, enabling dependency injection
/// for ViewModels. The live implementation wraps real FFI calls; tests can
/// provide a mock that returns canned data without the XCFramework.
///
/// **When adding a new method**: classify it as a read or a mutation, then
/// update `GatedAutorotaService` accordingly. Mutations must call `try check()`
/// before delegating; reads pass through. Skipping that step lets writes
/// bypass the read-only license gate.
protocol AutorotaServiceProtocol: Sendable {
    // Roles
    func listRoles() async throws -> [FfiRole]
    func createRole(name: String) async throws -> Int64
    func updateRole(id: Int64, name: String) async throws
    func deleteRole(id: Int64) async throws

    // Employees
    func listEmployees() async throws -> [FfiEmployee]
    func createEmployee(_ employee: FfiEmployee) async throws -> Int64
    func updateEmployee(_ employee: FfiEmployee) async throws
    func deleteEmployee(id: Int64) async throws

    // Shift Templates
    func listShiftTemplates() async throws -> [FfiShiftTemplate]
    func createShiftTemplate(_ template: FfiShiftTemplate) async throws -> Int64
    func updateShiftTemplate(_ template: FfiShiftTemplate) async throws
    func deleteShiftTemplate(id: Int64) async throws

    // Schedule
    func getWeekSchedule(weekStart: String) async throws -> FfiWeekSchedule?
    func runSchedule(weekStart: String) async throws -> FfiScheduleResult
    func materialiseWeek(weekStart: String) async throws -> Int64
    func createEmptyWeek(weekStart: String) async throws -> Int64
    func deleteWeek(weekStart: String) async throws

    // Assignments
    func createAssignment(_ assignment: FfiAssignment) async throws -> Int64
    func updateAssignmentStatus(id: Int64, status: String) async throws
    func swapAssignments(idA: Int64, idB: Int64) async throws
    func deleteAssignment(id: Int64) async throws
    func moveAssignment(id: Int64, newShiftId: Int64) async throws

    // Shifts
    func deleteShift(id: Int64) async throws
    func updateShiftTimes(id: Int64, startTime: String, endTime: String) async throws
    func updateShift(id: Int64, minEmployees: UInt32, maxEmployees: UInt32, roleRequirements: [FfiRoleRequirement]) async throws
    func createAdHocShift(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String, roleRequirements: [FfiRoleRequirement]) async throws -> Int64
    func listShiftsForRota(rotaId: Int64) async throws -> [FfiShift]

    // Shift History
    func listEmployeeShiftHistory(employeeId: Int64) async throws -> [FfiEmployeeShiftRecord]
    func listAllShiftHistory(startDate: String?, endDate: String?) async throws -> [FfiEmployeeShiftRecord]

    // Overrides
    func upsertEmployeeAvailabilityOverride(_ o: FfiEmployeeAvailabilityOverride) async throws -> Int64
    func getEmployeeAvailabilityOverride(employeeId: Int64, date: String) async throws -> FfiEmployeeAvailabilityOverride?
    func listEmployeeAvailabilityOverrides(employeeId: Int64) async throws -> [FfiEmployeeAvailabilityOverride]
    func listAllEmployeeAvailabilityOverrides() async throws -> [FfiEmployeeAvailabilityOverride]
    func deleteEmployeeAvailabilityOverride(id: Int64) async throws
    func upsertShiftTemplateOverride(_ o: FfiShiftTemplateOverride) async throws -> Int64
    func getShiftTemplateOverride(templateId: Int64, date: String) async throws -> FfiShiftTemplateOverride?
    func listShiftTemplateOverridesForTemplate(templateId: Int64) async throws -> [FfiShiftTemplateOverride]
    func listAllShiftTemplateOverrides() async throws -> [FfiShiftTemplateOverride]
    func deleteShiftTemplateOverride(id: Int64) async throws

    // Saves
    func createSave(rotaId: Int64) async throws -> Int64
    func diffRota(rotaId: Int64) async throws -> [FfiShiftDiff]
    func diffRotaDetailed(rotaId: Int64) async throws -> [FfiChangeDetail]
    func listSaves(rotaId: Int64?) async throws -> [FfiSave]
    func getSaveDetail(saveId: Int64) async throws -> FfiSaveDetail?
    func rotaHasSaves(rotaId: Int64) async throws -> Bool
    func diffSavesDetailed(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail]
    func diffSaveVsPrevious(saveId: Int64) async throws -> [FfiChangeDetail]
    func restoreToSave(saveId: Int64) async throws -> FfiRestoreResult
    func addSaveTag(saveId: Int64, tag: String) async throws
    func removeSaveTag(saveId: Int64, tag: String) async throws

    // Export
    func exportWeekSchedule(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult
    func exportEmployeeSchedule(config: FfiEmployeeExportConfig) async throws -> FfiExportResult
    func exportEmployeeBundle(config: FfiEmployeeExportConfig) async throws -> [FfiExportResult]
    func exportPreviewFull(config: FfiExportConfig) async throws -> FfiExportResult
    func exportPreviewEmployee(config: FfiEmployeeExportConfig) async throws -> FfiExportResult

    // Roster Import
    func parseRosterFile(bytes: Data, formatHint: String, strategy: String) async throws -> FfiParsedRoster
    func applyRosterImport(rows: [FfiParsedEmployeeRow]) async throws -> FfiImportSummary

    // Data Bundle Exchange
    func exportDataBundle(sections: FfiBundleSections) async throws -> FfiExportResult
    func inspectDataBundle(bytes: Data) async throws -> FfiBundleInfo
    func importDataBundle(bytes: Data) async throws -> FfiBundleImportSummary

    // Availability Progress
    func listAvailabilityProgress(weekStart: String) async throws -> [FfiAvailabilityProgress]
    func setAvailabilityProgress(employeeId: Int64, weekStart: String, done: Bool) async throws
}
