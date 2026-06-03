import Foundation
import AutorotaKit
@testable import AutorotaApp

/// Mirrors the validation codes surfaced by the Rust FFI via `FfiError.InvalidArgument`.
/// Raw values match the `as_code()` strings on the Rust `TagError` enum.
enum MockTagError: String, Error {
    case empty = "tag_empty"
    case tooLong = "tag_too_long"
    case containsSemicolon = "tag_has_semicolon"
    case duplicate = "tag_duplicate"
    case maxReached = "tag_max_reached"
}

/// Mock service that returns canned data and tracks method calls.
/// Tests can override the return values and inject errors.
final class MockAutorotaService: AutorotaServiceProtocol, @unchecked Sendable {

    // MARK: - Call tracking

    var callLog: [String] = []

    // MARK: - Canned data / overrides

    var stubbedRoles: [FfiRole] = []
    var stubbedEmployees: [FfiEmployee] = []
    var stubbedShiftTemplates: [FfiShiftTemplate] = []
    var stubbedWeekSchedule: FfiWeekSchedule? = nil
    var stubbedScheduleResult = FfiScheduleResult(assignments: [], warnings: [])
    var stubbedShifts: [FfiShift] = []
    var stubbedShiftHistory: [FfiEmployeeShiftRecord] = []
    var stubbedAvailabilityOverrides: [FfiEmployeeAvailabilityOverride] = []
    var errorToThrow: Error? = nil

    // MARK: - Roles

    func listRoles() async throws -> [FfiRole] {
        callLog.append("listRoles")
        if let e = errorToThrow { throw e }
        return stubbedRoles
    }

    func createRole(name: String) async throws -> Int64 {
        callLog.append("createRole:\(name)")
        if let e = errorToThrow { throw e }
        return 1
    }

    func updateRole(id: Int64, name: String) async throws {
        callLog.append("updateRole:\(id):\(name)")
        if let e = errorToThrow { throw e }
    }

    func deleteRole(id: Int64) async throws {
        callLog.append("deleteRole:\(id)")
        if let e = errorToThrow { throw e }
    }

    // MARK: - Employees

    func listEmployees() async throws -> [FfiEmployee] {
        callLog.append("listEmployees")
        if let e = errorToThrow { throw e }
        return stubbedEmployees
    }

    func createEmployee(_ employee: FfiEmployee) async throws -> Int64 {
        callLog.append("createEmployee:\(employee.firstName)")
        if let e = errorToThrow { throw e }
        return 1
    }

    func updateEmployee(_ employee: FfiEmployee) async throws {
        callLog.append("updateEmployee:\(employee.id)")
        if let e = errorToThrow { throw e }
    }

    func deleteEmployee(id: Int64) async throws {
        callLog.append("deleteEmployee:\(id)")
        if let e = errorToThrow { throw e }
    }

    // MARK: - Shift Templates

    func listShiftTemplates() async throws -> [FfiShiftTemplate] {
        callLog.append("listShiftTemplates")
        if let e = errorToThrow { throw e }
        return stubbedShiftTemplates
    }

    func createShiftTemplate(_ template: FfiShiftTemplate) async throws -> Int64 {
        callLog.append("createShiftTemplate:\(template.name)")
        if let e = errorToThrow { throw e }
        return 1
    }

    func updateShiftTemplate(_ template: FfiShiftTemplate) async throws {
        callLog.append("updateShiftTemplate:\(template.id)")
        if let e = errorToThrow { throw e }
    }

    func deleteShiftTemplate(id: Int64) async throws {
        callLog.append("deleteShiftTemplate:\(id)")
        if let e = errorToThrow { throw e }
    }

    // MARK: - Schedule

    func getWeekSchedule(weekStart: String) async throws -> FfiWeekSchedule? {
        callLog.append("getWeekSchedule:\(weekStart)")
        if let e = errorToThrow { throw e }
        return stubbedWeekSchedule
    }

    func runSchedule(weekStart: String) async throws -> FfiScheduleResult {
        callLog.append("runSchedule:\(weekStart)")
        if let e = errorToThrow { throw e }
        return stubbedScheduleResult
    }

    func materialiseWeek(weekStart: String) async throws -> Int64 {
        callLog.append("materialiseWeek:\(weekStart)")
        if let e = errorToThrow { throw e }
        return 1
    }

    func createEmptyWeek(weekStart: String) async throws -> Int64 {
        callLog.append("createEmptyWeek:\(weekStart)")
        if let e = errorToThrow { throw e }
        return 1
    }

    func deleteWeek(weekStart: String) async throws {
        callLog.append("deleteWeek:\(weekStart)")
        if let e = errorToThrow { throw e }
    }

    // MARK: - Assignments

    func createAssignment(_ assignment: FfiAssignment) async throws -> Int64 {
        callLog.append("createAssignment")
        if let e = errorToThrow { throw e }
        return 1
    }

    func updateAssignmentStatus(id: Int64, status: String) async throws {
        callLog.append("updateAssignmentStatus:\(id):\(status)")
        if let e = errorToThrow { throw e }
    }

    func swapAssignments(idA: Int64, idB: Int64) async throws {
        callLog.append("swapAssignments:\(idA):\(idB)")
        if let e = errorToThrow { throw e }
    }

    func deleteAssignment(id: Int64) async throws {
        callLog.append("deleteAssignment:\(id)")
        if let e = errorToThrow { throw e }
    }

    func moveAssignment(id: Int64, newShiftId: Int64) async throws {
        callLog.append("moveAssignment:\(id):\(newShiftId)")
        if let e = errorToThrow { throw e }
    }

    // MARK: - Shifts

    func deleteShift(id: Int64) async throws {
        callLog.append("deleteShift:\(id)")
        if let e = errorToThrow { throw e }
    }

    func updateShiftTimes(id: Int64, startTime: String, endTime: String) async throws {
        callLog.append("updateShiftTimes:\(id)")
        if let e = errorToThrow { throw e }
    }

    func updateShift(id: Int64, minEmployees: UInt32, maxEmployees: UInt32, roleRequirements: [FfiRoleRequirement]) async throws {
        callLog.append("updateShift:\(id):\(minEmployees)/\(maxEmployees):\(roleRequirements.map { "\($0.role)=\($0.minCount)" }.joined(separator: ","))")
        if let e = errorToThrow { throw e }
    }

    func createAdHocShift(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String, roleRequirements: [FfiRoleRequirement]) async throws -> Int64 {
        callLog.append("createAdHocShift:\(date)")
        if let e = errorToThrow { throw e }
        return 1
    }

    func listShiftsForRota(rotaId: Int64) async throws -> [FfiShift] {
        callLog.append("listShiftsForRota:\(rotaId)")
        if let e = errorToThrow { throw e }
        return stubbedShifts
    }

    // MARK: - Shift History

    func listEmployeeShiftHistory(employeeId: Int64) async throws -> [FfiEmployeeShiftRecord] {
        callLog.append("listEmployeeShiftHistory:\(employeeId)")
        if let e = errorToThrow { throw e }
        return stubbedShiftHistory
    }

    var stubbedAllShiftHistory: [FfiEmployeeShiftRecord] = []
    func listAllShiftHistory(startDate: String?, endDate: String?) async throws -> [FfiEmployeeShiftRecord] {
        callLog.append("listAllShiftHistory:\(startDate ?? "nil"):\(endDate ?? "nil")")
        if let e = errorToThrow { throw e }
        return stubbedAllShiftHistory
    }

    // MARK: - Overrides

    func upsertEmployeeAvailabilityOverride(_ o: FfiEmployeeAvailabilityOverride) async throws -> Int64 {
        callLog.append("upsertEmployeeAvailabilityOverride")
        if let e = errorToThrow { throw e }
        return 1
    }

    func getEmployeeAvailabilityOverride(employeeId: Int64, date: String) async throws -> FfiEmployeeAvailabilityOverride? {
        callLog.append("getEmployeeAvailabilityOverride:\(employeeId):\(date)")
        if let e = errorToThrow { throw e }
        return nil
    }

    func listEmployeeAvailabilityOverrides(employeeId: Int64) async throws -> [FfiEmployeeAvailabilityOverride] {
        callLog.append("listEmployeeAvailabilityOverrides:\(employeeId)")
        if let e = errorToThrow { throw e }
        return []
    }

    func listAllEmployeeAvailabilityOverrides() async throws -> [FfiEmployeeAvailabilityOverride] {
        callLog.append("listAllEmployeeAvailabilityOverrides")
        if let e = errorToThrow { throw e }
        return stubbedAvailabilityOverrides
    }

    func deleteEmployeeAvailabilityOverride(id: Int64) async throws {
        callLog.append("deleteEmployeeAvailabilityOverride:\(id)")
        if let e = errorToThrow { throw e }
    }

    func upsertShiftTemplateOverride(_ o: FfiShiftTemplateOverride) async throws -> Int64 {
        callLog.append("upsertShiftTemplateOverride")
        if let e = errorToThrow { throw e }
        return 1
    }

    func getShiftTemplateOverride(templateId: Int64, date: String) async throws -> FfiShiftTemplateOverride? {
        callLog.append("getShiftTemplateOverride:\(templateId):\(date)")
        if let e = errorToThrow { throw e }
        return nil
    }

    func listShiftTemplateOverridesForTemplate(templateId: Int64) async throws -> [FfiShiftTemplateOverride] {
        callLog.append("listShiftTemplateOverridesForTemplate:\(templateId)")
        if let e = errorToThrow { throw e }
        return []
    }

    func listAllShiftTemplateOverrides() async throws -> [FfiShiftTemplateOverride] {
        callLog.append("listAllShiftTemplateOverrides")
        if let e = errorToThrow { throw e }
        return []
    }

    func deleteShiftTemplateOverride(id: Int64) async throws {
        callLog.append("deleteShiftTemplateOverride:\(id)")
        if let e = errorToThrow { throw e }
    }

    // MARK: - Saves

    var stubbedSaves: [FfiSave] = []
    var stubbedSaveDetail: FfiSaveDetail? = nil
    var stubbedHasSaves = false
    var stubbedDiffResult: [FfiShiftDiff] = []
    var stubbedDetailedDiffResult: [FfiChangeDetail] = []
    var stubbedRestoreResult = FfiRestoreResult(
        rotaId: 1, shiftsRestored: 0, assignmentsRestored: 0, assignmentsSkipped: 0
    )

    func createSave(rotaId: Int64) async throws -> Int64 {
        callLog.append("createSave:\(rotaId)")
        if let e = errorToThrow { throw e }
        return 1
    }

    func diffRota(rotaId: Int64) async throws -> [FfiShiftDiff] {
        callLog.append("diffRota:\(rotaId)")
        if let e = errorToThrow { throw e }
        return stubbedDiffResult
    }

    func listSaves(rotaId: Int64?) async throws -> [FfiSave] {
        callLog.append("listSaves:\(String(describing: rotaId))")
        if let e = errorToThrow { throw e }
        return stubbedSaves
    }

    func getSaveDetail(saveId: Int64) async throws -> FfiSaveDetail? {
        callLog.append("getSaveDetail:\(saveId)")
        if let e = errorToThrow { throw e }
        return stubbedSaveDetail
    }

    func rotaHasSaves(rotaId: Int64) async throws -> Bool {
        callLog.append("rotaHasSaves:\(rotaId)")
        if let e = errorToThrow { throw e }
        return stubbedHasSaves
    }

    func diffRotaDetailed(rotaId: Int64) async throws -> [FfiChangeDetail] {
        callLog.append("diffRotaDetailed:\(rotaId)")
        if let e = errorToThrow { throw e }
        return stubbedDetailedDiffResult
    }

    func diffSavesDetailed(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail] {
        callLog.append("diffSavesDetailed:\(oldSaveId):\(newSaveId)")
        if let e = errorToThrow { throw e }
        return stubbedDetailedDiffResult
    }

    func diffSaveVsPrevious(saveId: Int64) async throws -> [FfiChangeDetail] {
        callLog.append("diffSaveVsPrevious:\(saveId)")
        if let e = errorToThrow { throw e }
        return stubbedDetailedDiffResult
    }

    func restoreToSave(saveId: Int64) async throws -> FfiRestoreResult {
        callLog.append("restoreToSave:\(saveId)")
        if let e = errorToThrow { throw e }
        return stubbedRestoreResult
    }

    /// In-memory tag store keyed by save id. Mirrors live constraints so
    /// tests can exercise validation and error branches.
    var stubbedTags: [Int64: [String]] = [:]

    /// Max tags per save — matches the Rust constant.
    static let tagMaxPerSave = 3
    /// Max characters per tag — matches the Rust constant.
    static let tagMaxLen = 15

    func addSaveTag(saveId: Int64, tag: String) async throws {
        callLog.append("addSaveTag:\(saveId):\(tag)")
        if let e = errorToThrow { throw e }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw MockTagError.empty
        }
        if trimmed.count > Self.tagMaxLen {
            throw MockTagError.tooLong
        }
        if trimmed.contains(";") {
            throw MockTagError.containsSemicolon
        }
        var existing = stubbedTags[saveId] ?? []
        if existing.count >= Self.tagMaxPerSave {
            throw MockTagError.maxReached
        }
        if existing.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            throw MockTagError.duplicate
        }
        existing.append(trimmed)
        stubbedTags[saveId] = existing
    }

    func removeSaveTag(saveId: Int64, tag: String) async throws {
        callLog.append("removeSaveTag:\(saveId):\(tag)")
        if let e = errorToThrow { throw e }
        let lower = tag.lowercased()
        stubbedTags[saveId] = (stubbedTags[saveId] ?? []).filter { $0.lowercased() != lower }
    }

    // MARK: - Export

    var stubbedExportResult = FfiExportResult(data: "mock,data\n", filename: "test.csv", mimeType: "text/csv")

    func exportWeekSchedule(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult {
        callLog.append("exportWeekSchedule:\(weekStart)")
        if let e = errorToThrow { throw e }
        return stubbedExportResult
    }

    func exportEmployeeSchedule(config: FfiEmployeeExportConfig) async throws -> FfiExportResult {
        callLog.append("exportEmployeeSchedule:\(config.employeeId)")
        if let e = errorToThrow { throw e }
        return stubbedExportResult
    }

    var stubbedBundleResults: [FfiExportResult] = [
        FfiExportResult(data: "%PDF-mock", filename: "schedule.pdf", mimeType: "application/pdf"),
        FfiExportResult(data: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", filename: "schedule.ics", mimeType: "text/calendar"),
        FfiExportResult(data: "# mock", filename: "schedule.md", mimeType: "text/markdown"),
        FfiExportResult(data: "UEsDBBQAAAAA", filename: "schedule.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
    ]

    func exportEmployeeBundle(config: FfiEmployeeExportConfig) async throws -> [FfiExportResult] {
        callLog.append("exportEmployeeBundle:\(config.employeeId)")
        if let e = errorToThrow { throw e }
        return stubbedBundleResults
    }

    func exportPreviewFull(config: FfiExportConfig) async throws -> FfiExportResult {
        callLog.append("exportPreviewFull:\(config.format)")
        if let e = errorToThrow { throw e }
        return stubbedExportResult
    }

    func exportPreviewEmployee(config: FfiEmployeeExportConfig) async throws -> FfiExportResult {
        callLog.append("exportPreviewEmployee:\(config.format)")
        if let e = errorToThrow { throw e }
        return stubbedExportResult
    }

    var stubbedParsedRoster = FfiParsedRoster(rows: [], warnings: [])
    var stubbedImportSummary = FfiImportSummary(inserted: 0, updated: 0, skipped: 0)

    func parseRosterFile(bytes: Data, formatHint: String, strategy: String) async throws -> FfiParsedRoster {
        callLog.append("parseRosterFile:\(formatHint):\(strategy)")
        if let e = errorToThrow { throw e }
        return stubbedParsedRoster
    }
    func applyRosterImport(rows: [FfiParsedEmployeeRow]) async throws -> FfiImportSummary {
        callLog.append("applyRosterImport:\(rows.count)")
        if let e = errorToThrow { throw e }
        return stubbedImportSummary
    }

    // MARK: - Availability Progress

    var stubbedAvailabilityProgress: [FfiAvailabilityProgress] = []

    func listAvailabilityProgress(weekStart: String) async throws -> [FfiAvailabilityProgress] {
        callLog.append("listAvailabilityProgress:\(weekStart)")
        if let e = errorToThrow { throw e }
        return stubbedAvailabilityProgress
    }

    func setAvailabilityProgress(employeeId: Int64, weekStart: String, done: Bool) async throws {
        callLog.append("setAvailabilityProgress:\(employeeId):\(weekStart):\(done)")
        if let e = errorToThrow { throw e }
    }
}
