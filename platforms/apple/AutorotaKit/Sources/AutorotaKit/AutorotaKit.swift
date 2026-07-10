// AutorotaKit.swift
//
// Thin ergonomics layer on top of the UniFFI-generated bindings.
// The generated file (autorota_ffi.swift) lives alongside this file in
// Sources/AutorotaKit/generated/ and is compiled as part of the same target.

import Foundation

// MARK: - Database initialisation helper

/// Resolve (and create) the app-support directory used to host the database.
public func autorotaAppSupportDirectory() throws -> URL {
    let appSupport = try FileManager.default
        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = appSupport.appendingPathComponent("AutorotaApp", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Resolved file URL for the default production database.
public func autorotaDefaultDBURL() throws -> URL {
    try autorotaAppSupportDirectory().appendingPathComponent("autorota.db")
}

/// Resolve the app-support database path and initialise the Rust pool.
/// Call once from your @main App's init() or Scene body before any other API.
public func autorotaInitDb() throws {
    try initDb(dbPath: autorotaDefaultDBURL().path)
}

/// Initialise the Rust pool against an explicit database path. Used by
/// performance tests that want an ephemeral DB so each run starts fresh.
public func autorotaInitDb(at path: String) throws {
    try initDb(dbPath: path)
}

/// Resolved file URL for the throwaway demo-mode database. Lives beside the
/// production DB; demo mode deletes and reseeds it on every entry.
public func autorotaDemoDBURL() throws -> URL {
    try autorotaAppSupportDirectory().appendingPathComponent("demo.sqlite")
}

/// Swap the process-wide Rust pool to a different database file at runtime.
/// The target is created and migrated if missing; the previous pool is closed
/// after the swap. Used by demo mode to enter and leave the demo database.
public func autorotaSwitchDb(to path: String) throws {
    try switchDb(dbPath: path)
}

/// Seed the current database with the planet-crew demo dataset. `weekStart`
/// is the Monday (yyyy-MM-dd) the guided tour centres on. Expects a freshly
/// created (empty) database.
public func autorotaSeedDemoDb(weekStart: String) throws {
    try seedDemoDb(weekStart: weekStart)
}

/// Quarantine a corrupted database file by renaming it `db.corrupt-<unix-ts>.sqlite`
/// in the same directory. Returns the new path on success. The caller is
/// expected to re-attempt `autorotaInitDb()` afterwards (which will recreate
/// a fresh empty file).
@discardableResult
public func autorotaQuarantineDatabase(at url: URL) throws -> URL {
    let ts = Int(Date().timeIntervalSince1970)
    let quarantine = url.deletingLastPathComponent()
        .appendingPathComponent("db.corrupt-\(ts).sqlite")
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.moveItem(at: url, to: quarantine)
    }
    // Best-effort cleanup of WAL/SHM siblings — leaving them around can
    // cause SQLite to re-attach to the corrupt journal on the next open.
    for ext in ["-wal", "-shm"] {
        let sibling = URL(fileURLWithPath: url.path + ext)
        if FileManager.default.fileExists(atPath: sibling.path) {
            try? FileManager.default.removeItem(at: sibling)
        }
    }
    return quarantine
}

// MARK: - Convenience date helpers

public extension FfiEmployee {
    /// Parse start_date back to a Swift Date for display.
    var startDateValue: Date? {
        ISO8601DateFormatter.sharedDate.date(from: startDate)
    }
}

private extension ISO8601DateFormatter {
    static let sharedDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Async wrappers
//
// UniFFI functions are synchronous (they block on the Tokio runtime internally).
// Call them from a Task.detached or a detached background Task to avoid
// blocking the main actor. Convenience wrappers below handle that pattern.

public func listRolesAsync() async throws -> [FfiRole] {
    try await Task.detached(priority: .userInitiated) {
        try listRoles()
    }.value
}

public func createRoleAsync(name: String) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try createRole(name: name)
    }.value
}

public func updateRoleAsync(id: Int64, name: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try updateRole(id: id, name: name)
    }.value
}

public func deleteRoleAsync(id: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try deleteRole(id: id)
    }.value
}

public func listEmployeesAsync() async throws -> [FfiEmployee] {
    try await Task.detached(priority: .userInitiated) {
        try listEmployees()
    }.value
}

public func createEmployeeAsync(_ employee: FfiEmployee) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try createEmployee(employee: employee)
    }.value
}

public func updateEmployeeAsync(_ employee: FfiEmployee) async throws {
    try await Task.detached(priority: .userInitiated) {
        try updateEmployee(employee: employee)
    }.value
}

public func deleteEmployeeAsync(id: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try deleteEmployee(id: id)
    }.value
}

public func listShiftTemplatesAsync() async throws -> [FfiShiftTemplate] {
    try await Task.detached(priority: .userInitiated) {
        try listShiftTemplates()
    }.value
}

public func createShiftTemplateAsync(_ template: FfiShiftTemplate) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try createShiftTemplate(template: template)
    }.value
}

public func updateShiftTemplateAsync(_ template: FfiShiftTemplate) async throws {
    try await Task.detached(priority: .userInitiated) {
        try updateShiftTemplate(template: template)
    }.value
}

public func deleteShiftTemplateAsync(id: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try deleteShiftTemplate(id: id)
    }.value
}

public func getWeekScheduleAsync(weekStart: String) async throws -> FfiWeekSchedule? {
    try await Task.detached(priority: .userInitiated) {
        try getWeekSchedule(weekStart: weekStart)
    }.value
}

public func runScheduleAsync(weekStart: String) async throws -> FfiScheduleResult {
    try await Task.detached(priority: .userInitiated) {
        try runSchedule(weekStart: weekStart)
    }.value
}

public func materialiseWeekAsync(weekStart: String) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try materialiseWeek(weekStart: weekStart)
    }.value
}

public func createEmptyWeekAsync(weekStart: String) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try createEmptyWeek(weekStart: weekStart)
    }.value
}

public func deleteWeekAsync(weekStart: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try deleteWeek(weekStart: weekStart)
    }.value
}

public func updateAssignmentStatusAsync(id: Int64, status: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try updateAssignmentStatus(id: id, status: status)
    }.value
}

public func swapAssignmentsAsync(idA: Int64, idB: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try swapAssignments(idA: idA, idB: idB)
    }.value
}

public func deleteAssignmentAsync(id: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try deleteAssignment(id: id)
    }.value
}

public func createAssignmentAsync(_ assignment: FfiAssignment) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try createAssignment(assignment: assignment)
    }.value
}

public func moveAssignmentAsync(id: Int64, newShiftId: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try moveAssignment(id: id, newShiftId: newShiftId)
    }.value
}

public func deleteShiftAsync(id: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try deleteShift(id: id)
    }.value
}

public func updateShiftTimesAsync(id: Int64, startTime: String, endTime: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try updateShiftTimes(id: id, startTime: startTime, endTime: endTime)
    }.value
}

public func updateShiftAsync(id: Int64, minEmployees: UInt32, maxEmployees: UInt32, roleRequirements: [FfiRoleRequirement]) async throws {
    try await Task.detached(priority: .userInitiated) {
        try updateShift(id: id, minEmployees: minEmployees, maxEmployees: maxEmployees, roleRequirements: roleRequirements)
    }.value
}

public func createAdHocShiftAsync(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String, roleRequirements: [FfiRoleRequirement]) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try createAdHocShift(rotaId: rotaId, date: date, startTime: startTime, endTime: endTime, requiredRole: requiredRole, roleRequirements: roleRequirements)
    }.value
}

public func listShiftsForRotaAsync(rotaId: Int64) async throws -> [FfiShift] {
    try await Task.detached(priority: .userInitiated) {
        try listShiftsForRota(rotaId: rotaId)
    }.value
}

// MARK: - Override async wrappers

public func upsertEmployeeAvailabilityOverrideAsync(override_: FfiEmployeeAvailabilityOverride) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try upsertEmployeeAvailabilityOverride(override: override_)
    }.value
}

public func getEmployeeAvailabilityOverrideAsync(employeeId: Int64, date: String) async throws -> FfiEmployeeAvailabilityOverride? {
    try await Task.detached(priority: .userInitiated) {
        try getEmployeeAvailabilityOverride(employeeId: employeeId, date: date)
    }.value
}

public func listEmployeeAvailabilityOverridesAsync(employeeId: Int64) async throws -> [FfiEmployeeAvailabilityOverride] {
    try await Task.detached(priority: .userInitiated) {
        try listEmployeeAvailabilityOverrides(employeeId: employeeId)
    }.value
}

public func listAllEmployeeAvailabilityOverridesAsync() async throws -> [FfiEmployeeAvailabilityOverride] {
    try await Task.detached(priority: .userInitiated) {
        try listAllEmployeeAvailabilityOverrides()
    }.value
}

public func deleteEmployeeAvailabilityOverrideAsync(id: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try deleteEmployeeAvailabilityOverride(id: id)
    }.value
}

public func upsertShiftTemplateOverrideAsync(override_: FfiShiftTemplateOverride) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try upsertShiftTemplateOverride(override: override_)
    }.value
}

public func getShiftTemplateOverrideAsync(templateId: Int64, date: String) async throws -> FfiShiftTemplateOverride? {
    try await Task.detached(priority: .userInitiated) {
        try getShiftTemplateOverride(templateId: templateId, date: date)
    }.value
}

public func listShiftTemplateOverridesForTemplateAsync(templateId: Int64) async throws -> [FfiShiftTemplateOverride] {
    try await Task.detached(priority: .userInitiated) {
        try listShiftTemplateOverridesForTemplate(templateId: templateId)
    }.value
}

public func listAllShiftTemplateOverridesAsync() async throws -> [FfiShiftTemplateOverride] {
    try await Task.detached(priority: .userInitiated) {
        try listAllShiftTemplateOverrides()
    }.value
}

public func deleteShiftTemplateOverrideAsync(id: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try deleteShiftTemplateOverride(id: id)
    }.value
}

// MARK: - Empty availability helper

/// Returns an empty availability slot list (all hours default to Maybe in the scheduler).
public func emptyAvailability() -> [AvailabilitySlot] { [] }

/// Returns today's Monday formatted as "YYYY-MM-DD".
public func currentWeekStart() -> String {
    let cal = Calendar(identifier: .iso8601)
    let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    return fmt.string(from: monday)
}

/// Returns the Monday of the week `weeksAhead` weeks from now.
public func weekStart(weeksFromNow offset: Int) -> String {
    let cal = Calendar(identifier: .iso8601)
    let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
    let target = cal.date(byAdding: .weekOfYear, value: offset, to: monday)!
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    return fmt.string(from: target)
}

// MARK: - Employee Shift History

public func listEmployeeShiftHistoryAsync(employeeId: Int64) async throws -> [FfiEmployeeShiftRecord] {
    try await Task.detached(priority: .userInitiated) {
        try listEmployeeShiftHistory(employeeId: employeeId)
    }.value
}

public func listAllShiftHistoryAsync(startDate: String?, endDate: String?) async throws -> [FfiEmployeeShiftRecord] {
    try await Task.detached(priority: .userInitiated) {
        try listAllShiftHistory(startDate: startDate, endDate: endDate)
    }.value
}

// MARK: - Saves

public func createSaveAsync(rotaId: Int64) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try createSave(rotaId: rotaId)
    }.value
}

public func listSavesAsync(rotaId: Int64?) async throws -> [FfiSave] {
    try await Task.detached(priority: .userInitiated) {
        try listSaves(rotaId: rotaId)
    }.value
}

public func getSaveDetailAsync(saveId: Int64) async throws -> FfiSaveDetail? {
    try await Task.detached(priority: .userInitiated) {
        try getSaveDetail(saveId: saveId)
    }.value
}

public func rotaHasSavesAsync(rotaId: Int64) async throws -> Bool {
    try await Task.detached(priority: .userInitiated) {
        try rotaHasSaves(rotaId: rotaId)
    }.value
}

public func restoreToSaveAsync(saveId: Int64) async throws -> FfiRestoreResult {
    try await Task.detached(priority: .userInitiated) {
        try restoreToSave(saveId: saveId)
    }.value
}

public func diffRotaAsync(rotaId: Int64) async throws -> [FfiShiftDiff] {
    try await Task.detached(priority: .userInitiated) {
        try diffRota(rotaId: rotaId)
    }.value
}

public func diffRotaDetailedAsync(rotaId: Int64) async throws -> [FfiChangeDetail] {
    try await Task.detached(priority: .userInitiated) {
        try diffRotaDetailed(rotaId: rotaId)
    }.value
}

public func diffSavesDetailedAsync(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail] {
    try await Task.detached(priority: .userInitiated) {
        try diffSavesDetailed(oldSaveId: oldSaveId, newSaveId: newSaveId)
    }.value
}

public func diffSaveVsPreviousAsync(saveId: Int64) async throws -> [FfiChangeDetail] {
    try await Task.detached(priority: .userInitiated) {
        try diffSaveVsPrevious(saveId: saveId)
    }.value
}

public func addSaveTagAsync(saveId: Int64, tag: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try addSaveTag(saveId: saveId, tag: tag)
    }.value
}

public func removeSaveTagAsync(saveId: Int64, tag: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try removeSaveTag(saveId: saveId, tag: tag)
    }.value
}

// MARK: - Export

public func exportWeekScheduleAsync(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult {
    try await Task.detached(priority: .userInitiated) {
        try exportWeekSchedule(weekStart: weekStart, config: config)
    }.value
}

public func exportEmployeeScheduleAsync(config: FfiEmployeeExportConfig) async throws -> FfiExportResult {
    try await Task.detached(priority: .userInitiated) {
        try exportEmployeeSchedule(config: config)
    }.value
}

public func exportEmployeeBundleAsync(config: FfiEmployeeExportConfig) async throws -> [FfiExportResult] {
    try await Task.detached(priority: .userInitiated) {
        try exportEmployeeBundle(config: config)
    }.value
}

public func exportPreviewFullAsync(config: FfiExportConfig) async throws -> FfiExportResult {
    try await Task.detached(priority: .userInitiated) {
        try exportPreviewFull(config: config)
    }.value
}

public func exportPreviewEmployeeAsync(config: FfiEmployeeExportConfig) async throws -> FfiExportResult {
    try await Task.detached(priority: .userInitiated) {
        try exportPreviewEmployee(config: config)
    }.value
}

// MARK: - Roster Import

public func parseRosterFileAsync(bytes: Data, formatHint: String, strategy: String) async throws -> FfiParsedRoster {
    try await Task.detached(priority: .userInitiated) {
        try parseRosterFile(bytes: bytes, formatHint: formatHint, strategy: strategy)
    }.value
}

public func applyRosterImportAsync(rows: [FfiParsedEmployeeRow]) async throws -> FfiImportSummary {
    try await Task.detached(priority: .userInitiated) {
        try applyRosterImport(rows: rows)
    }.value
}

// MARK: - Data Bundle Exchange

public func exportDataBundleAsync(sections: FfiBundleSections) async throws -> FfiExportResult {
    try await Task.detached(priority: .userInitiated) {
        try exportDataBundle(sections: sections)
    }.value
}

public func inspectDataBundleAsync(bytes: Data) async throws -> FfiBundleInfo {
    try await Task.detached(priority: .userInitiated) {
        try inspectDataBundle(bytes: bytes)
    }.value
}

public func importDataBundleAsync(bytes: Data) async throws -> FfiBundleImportSummary {
    try await Task.detached(priority: .userInitiated) {
        try importDataBundle(bytes: bytes)
    }.value
}

// MARK: - Sync

public func getPendingSyncRecordsAsync(tableName: String) async throws -> [FfiSyncRecord] {
    try await Task.detached(priority: .userInitiated) {
        try getPendingSyncRecords(tableName: tableName)
    }.value
}

public func markRecordsSyncedAsync(tableName: String, recordIds: [Int64], baseSnapshots: [String]) async throws {
    try await Task.detached(priority: .userInitiated) {
        try markRecordsSynced(tableName: tableName, recordIds: recordIds, baseSnapshots: baseSnapshots)
    }.value
}

public func applyRemoteRecordAsync(record: FfiSyncRecord) async throws {
    try await Task.detached(priority: .userInitiated) {
        try applyRemoteRecord(record: record)
    }.value
}

public func getSyncMetadataAsync(key: String) async throws -> String? {
    try await Task.detached(priority: .userInitiated) {
        try getSyncMetadata(key: key)
    }.value
}

public func setSyncMetadataAsync(key: String, value: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try setSyncMetadata(key: key, value: value)
    }.value
}

public func getBaseSnapshotsAsync(tableName: String, recordIds: [Int64]) async throws -> [FfiBaseSnapshot] {
    try await Task.detached(priority: .userInitiated) {
        try getBaseSnapshots(tableName: tableName, recordIds: recordIds)
    }.value
}

public func getPendingTombstonesAsync() async throws -> [FfiTombstone] {
    try await Task.detached(priority: .userInitiated) {
        try getPendingTombstones()
    }.value
}

public func clearTombstonesAsync(ids: [Int64]) async throws {
    try await Task.detached(priority: .userInitiated) {
        try clearTombstones(ids: ids)
    }.value
}

public func countEmployeesAsync() async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try countEmployees()
    }.value
}

// MARK: - Availability Progress

public func listAvailabilityProgressAsync(weekStart: String) async throws -> [FfiAvailabilityProgress] {
    try await Task.detached(priority: .userInitiated) {
        try listAvailabilityProgress(weekStart: weekStart)
    }.value
}

public func setAvailabilityProgressAsync(employeeId: Int64, weekStart: String, done: Bool) async throws {
    try await Task.detached(priority: .userInitiated) {
        try setAvailabilityProgress(employeeId: employeeId, weekStart: weekStart, done: done)
    }.value
}
