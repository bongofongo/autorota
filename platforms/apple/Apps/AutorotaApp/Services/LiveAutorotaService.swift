import AutorotaKit
import Foundation

extension Notification.Name {
    /// Posted by `LiveAutorotaService` mutators (and by `AutorotaSyncEngine`
    /// when it applies a remote change). Carries an `AutorotaDataChange`
    /// payload in `userInfo["change"]`.
    static let autorotaDataChanged = Notification.Name("autorotaDataChanged")
}

/// Typed payload attached to `.autorotaDataChanged` notifications. Listeners
/// inspect `tables` to decide whether they need to reload, and inspect
/// `source` to break reentrant push loops in the iCloud sync engine.
///
/// Back-compat: posts that omit this payload (legacy code paths or tests
/// that fire `.autorotaDataChanged` directly) result in `Notification
/// .autorotaDataChange == nil`. Listeners that read the property must treat
/// `nil` as "I don't know what changed — do a full reload."
struct AutorotaDataChange: Sendable {
    /// Where the mutation originated. The sync engine's local observer
    /// drops events with `.remoteSync` to avoid pushing a change it just
    /// received from CloudKit.
    enum Source: String, Sendable {
        case local
        case remoteSync
    }

    /// Tables modified by this change. Listeners refresh selectively when
    /// they only care about a subset (e.g. the rota view ignores role-only
    /// changes).
    enum Table: String, Sendable, CaseIterable {
        case role
        case employee
        case shiftTemplate
        case shift
        case rota
        case assignment
        case save
        case employeeAvailabilityOverride
        case shiftTemplateOverride

        /// Map the snake_case table name used by CloudKit / SQLite onto the
        /// `Table` case. Falls back to a full set when the name doesn't
        /// match a known case so unrecognised remote rows still trigger a
        /// reload rather than silently get dropped.
        static func from(tableName: String) -> Set<Table> {
            switch tableName {
            case "role", "roles": return [.role]
            case "employee", "employees": return [.employee]
            case "shift_template", "shift_templates": return [.shiftTemplate]
            case "shift", "shifts": return [.shift]
            case "rota", "rotas": return [.rota]
            case "assignment", "assignments": return [.assignment]
            case "save", "saves": return [.save]
            case "employee_availability_override",
                 "employee_availability_overrides": return [.employeeAvailabilityOverride]
            case "shift_template_override",
                 "shift_template_overrides": return [.shiftTemplateOverride]
            default: return Set(Table.allCases)
            }
        }
    }

    let source: Source
    let tables: Set<Table>
    /// Optional list of row IDs touched. May be `nil` when the count is
    /// large (e.g. `runSchedule` writes many assignments) — listeners must
    /// treat `nil` as "every row in `tables`".
    let rowIDs: [Int64]?
}

extension Notification {
    /// Decode the typed `AutorotaDataChange` payload, if any. Returns `nil`
    /// for legacy posts that didn't include a `userInfo["change"]` entry —
    /// listeners must fall back to a full reload in that case.
    var autorotaDataChange: AutorotaDataChange? {
        userInfo?["change"] as? AutorotaDataChange
    }
}

extension NotificationCenter {
    /// Post `.autorotaDataChanged` with a typed payload attached. Replaces
    /// the bare `.post(name: .autorotaDataChanged, object: nil)` pattern at
    /// every mutator call site.
    func postAutorotaDataChange(
        source: AutorotaDataChange.Source = .local,
        tables: Set<AutorotaDataChange.Table>,
        rowIDs: [Int64]? = nil
    ) {
        let change = AutorotaDataChange(source: source, tables: tables, rowIDs: rowIDs)
        post(
            name: .autorotaDataChanged,
            object: nil,
            userInfo: ["change": change]
        )
    }
}

/// Production implementation that delegates to the real AutorotaKit async wrappers.
struct LiveAutorotaService: AutorotaServiceProtocol {
    private func notify(
        _ tables: Set<AutorotaDataChange.Table>,
        rowIDs: [Int64]? = nil
    ) {
        NotificationCenter.default.postAutorotaDataChange(
            source: .local,
            tables: tables,
            rowIDs: rowIDs
        )
    }

    func listRoles() async throws -> [FfiRole] { try await listRolesAsync() }
    func createRole(name: String) async throws -> Int64 {
        let id = try await createRoleAsync(name: name)
        notify([.role], rowIDs: [id])
        return id
    }
    func updateRole(id: Int64, name: String) async throws {
        try await updateRoleAsync(id: id, name: name)
        notify([.role], rowIDs: [id])
    }
    func deleteRole(id: Int64) async throws {
        try await deleteRoleAsync(id: id)
        notify([.role], rowIDs: [id])
    }

    func listEmployees() async throws -> [FfiEmployee] { try await listEmployeesAsync() }
    func createEmployee(_ employee: FfiEmployee) async throws -> Int64 {
        let id = try await createEmployeeAsync(employee)
        notify([.employee], rowIDs: [id])
        return id
    }
    func updateEmployee(_ employee: FfiEmployee) async throws {
        try await updateEmployeeAsync(employee)
        notify([.employee], rowIDs: [employee.id])
    }
    func deleteEmployee(id: Int64) async throws {
        try await deleteEmployeeAsync(id: id)
        notify([.employee], rowIDs: [id])
    }

    func listShiftTemplates() async throws -> [FfiShiftTemplate] { try await listShiftTemplatesAsync() }
    func createShiftTemplate(_ template: FfiShiftTemplate) async throws -> Int64 {
        let id = try await createShiftTemplateAsync(template)
        notify([.shiftTemplate], rowIDs: [id])
        return id
    }
    func updateShiftTemplate(_ template: FfiShiftTemplate) async throws {
        try await updateShiftTemplateAsync(template)
        notify([.shiftTemplate], rowIDs: [template.id])
    }
    func deleteShiftTemplate(id: Int64) async throws {
        try await deleteShiftTemplateAsync(id: id)
        notify([.shiftTemplate], rowIDs: [id])
    }

    func getWeekSchedule(weekStart: String) async throws -> FfiWeekSchedule? { try await getWeekScheduleAsync(weekStart: weekStart) }
    func runSchedule(weekStart: String) async throws -> FfiScheduleResult {
        let result = try await runScheduleAsync(weekStart: weekStart)
        // Schedule run rewrites the entire rota's assignments; row-level
        // identity is too noisy to enumerate, so leave rowIDs nil.
        notify([.rota, .shift, .assignment])
        return result
    }
    func materialiseWeek(weekStart: String) async throws -> Int64 {
        let id = try await materialiseWeekAsync(weekStart: weekStart)
        notify([.rota, .shift], rowIDs: [id])
        return id
    }
    func createEmptyWeek(weekStart: String) async throws -> Int64 {
        let id = try await createEmptyWeekAsync(weekStart: weekStart)
        notify([.rota], rowIDs: [id])
        return id
    }
    func deleteWeek(weekStart: String) async throws {
        try await deleteWeekAsync(weekStart: weekStart)
        notify([.rota, .shift, .assignment])
    }
    func createAssignment(_ assignment: FfiAssignment) async throws -> Int64 {
        let id = try await createAssignmentAsync(assignment)
        notify([.assignment], rowIDs: [id])
        return id
    }
    func updateAssignmentStatus(id: Int64, status: String) async throws {
        try await updateAssignmentStatusAsync(id: id, status: status)
        notify([.assignment], rowIDs: [id])
    }
    func swapAssignments(idA: Int64, idB: Int64) async throws {
        try await swapAssignmentsAsync(idA: idA, idB: idB)
        notify([.assignment], rowIDs: [idA, idB])
    }
    func deleteAssignment(id: Int64) async throws {
        try await deleteAssignmentAsync(id: id)
        notify([.assignment], rowIDs: [id])
    }
    func moveAssignment(id: Int64, newShiftId: Int64) async throws {
        try await moveAssignmentAsync(id: id, newShiftId: newShiftId)
        notify([.assignment], rowIDs: [id])
    }

    func deleteShift(id: Int64) async throws {
        try await deleteShiftAsync(id: id)
        notify([.shift, .assignment], rowIDs: [id])
    }
    func updateShiftTimes(id: Int64, startTime: String, endTime: String) async throws {
        try await updateShiftTimesAsync(id: id, startTime: startTime, endTime: endTime)
        notify([.shift], rowIDs: [id])
    }
    func createAdHocShift(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String) async throws -> Int64 {
        let id = try await createAdHocShiftAsync(rotaId: rotaId, date: date, startTime: startTime, endTime: endTime, requiredRole: requiredRole)
        notify([.shift], rowIDs: [id])
        return id
    }
    func listShiftsForRota(rotaId: Int64) async throws -> [FfiShift] { try await listShiftsForRotaAsync(rotaId: rotaId) }

    func listEmployeeShiftHistory(employeeId: Int64) async throws -> [FfiEmployeeShiftRecord] { try await listEmployeeShiftHistoryAsync(employeeId: employeeId) }
    func listAllShiftHistory(startDate: String?, endDate: String?) async throws -> [FfiEmployeeShiftRecord] { try await listAllShiftHistoryAsync(startDate: startDate, endDate: endDate) }

    func upsertEmployeeAvailabilityOverride(_ o: FfiEmployeeAvailabilityOverride) async throws -> Int64 {
        let id = try await upsertEmployeeAvailabilityOverrideAsync(override_: o)
        notify([.employeeAvailabilityOverride], rowIDs: [id])
        return id
    }
    func getEmployeeAvailabilityOverride(employeeId: Int64, date: String) async throws -> FfiEmployeeAvailabilityOverride? { try await getEmployeeAvailabilityOverrideAsync(employeeId: employeeId, date: date) }
    func listEmployeeAvailabilityOverrides(employeeId: Int64) async throws -> [FfiEmployeeAvailabilityOverride] { try await listEmployeeAvailabilityOverridesAsync(employeeId: employeeId) }
    func listAllEmployeeAvailabilityOverrides() async throws -> [FfiEmployeeAvailabilityOverride] { try await listAllEmployeeAvailabilityOverridesAsync() }
    func deleteEmployeeAvailabilityOverride(id: Int64) async throws {
        try await deleteEmployeeAvailabilityOverrideAsync(id: id)
        notify([.employeeAvailabilityOverride], rowIDs: [id])
    }
    func upsertShiftTemplateOverride(_ o: FfiShiftTemplateOverride) async throws -> Int64 {
        let id = try await upsertShiftTemplateOverrideAsync(override_: o)
        notify([.shiftTemplateOverride], rowIDs: [id])
        return id
    }
    func getShiftTemplateOverride(templateId: Int64, date: String) async throws -> FfiShiftTemplateOverride? { try await getShiftTemplateOverrideAsync(templateId: templateId, date: date) }
    func listShiftTemplateOverridesForTemplate(templateId: Int64) async throws -> [FfiShiftTemplateOverride] { try await listShiftTemplateOverridesForTemplateAsync(templateId: templateId) }
    func listAllShiftTemplateOverrides() async throws -> [FfiShiftTemplateOverride] { try await listAllShiftTemplateOverridesAsync() }
    func deleteShiftTemplateOverride(id: Int64) async throws {
        try await deleteShiftTemplateOverrideAsync(id: id)
        notify([.shiftTemplateOverride], rowIDs: [id])
    }

    // Saves
    func createSave(rotaId: Int64) async throws -> Int64 {
        let id = try await createSaveAsync(rotaId: rotaId)
        notify([.save], rowIDs: [id])
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
        // Restore replaces the live rota wholesale.
        notify([.rota, .shift, .assignment, .save], rowIDs: [saveId])
        return result
    }
    func addSaveTag(saveId: Int64, tag: String) async throws {
        try await addSaveTagAsync(saveId: saveId, tag: tag)
        notify([.save], rowIDs: [saveId])
    }
    func removeSaveTag(saveId: Int64, tag: String) async throws {
        try await removeSaveTagAsync(saveId: saveId, tag: tag)
        notify([.save], rowIDs: [saveId])
    }

    func exportWeekSchedule(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult { try await exportWeekScheduleAsync(weekStart: weekStart, config: config) }
    func exportEmployeeSchedule(config: FfiEmployeeExportConfig) async throws -> FfiExportResult { try await exportEmployeeScheduleAsync(config: config) }
    func exportEmployeeBundle(config: FfiEmployeeExportConfig) async throws -> [FfiExportResult] { try await exportEmployeeBundleAsync(config: config) }
    func exportPreviewFull(config: FfiExportConfig) async throws -> FfiExportResult { try await exportPreviewFullAsync(config: config) }
    func exportPreviewEmployee(config: FfiEmployeeExportConfig) async throws -> FfiExportResult { try await exportPreviewEmployeeAsync(config: config) }

    func parseRosterFile(bytes: Data, formatHint: String, strategy: String) async throws -> FfiParsedRoster {
        try await parseRosterFileAsync(bytes: bytes, formatHint: formatHint, strategy: strategy)
    }
    func applyRosterImport(rows: [FfiParsedEmployeeRow]) async throws -> FfiImportSummary {
        let result = try await applyRosterImportAsync(rows: rows)
        notify([.employee])
        return result
    }

    // Availability Progress
    func listAvailabilityProgress(weekStart: String) async throws -> [FfiAvailabilityProgress] { try await listAvailabilityProgressAsync(weekStart: weekStart) }
    func setAvailabilityProgress(employeeId: Int64, weekStart: String, done: Bool) async throws { try await setAvailabilityProgressAsync(employeeId: employeeId, weekStart: weekStart, done: done) }
}
