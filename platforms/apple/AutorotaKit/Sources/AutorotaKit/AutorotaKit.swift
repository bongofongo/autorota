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

/// Resolved file URL for the throwaway debug "default" sample database. Lives
/// beside the production DB; the `#if DEBUG` sample loader deletes and reseeds
/// it on every load. Never used by release builds.
public func autorotaSampleDBURL() throws -> URL {
    try autorotaAppSupportDirectory().appendingPathComponent("sample-debug.sqlite")
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

/// Seed the current database with the debug-only "default" sample dataset
/// (30 employees, four roles, eight templates). `weekStart` is a Monday
/// (yyyy-MM-dd) for parity with the demo seeder. Expects a freshly created
/// (empty) database.
public func autorotaSeedSampleDebugDb(weekStart: String) throws {
    try seedSampleDebugDb(weekStart: weekStart)
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

/// Shared cached "yyyy-MM-dd" formatter (POSIX locale).
let isoDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

public extension FfiEmployee {
    /// Parse start_date back to a Swift Date for display.
    var startDateValue: Date? {
        isoDateFmt.date(from: startDate)
    }
}

// MARK: - Async wrappers
//
// UniFFI functions are synchronous (they block on the Tokio runtime internally).
// Call them from a Task.detached or a detached background Task to avoid
// blocking the main actor. Convenience wrappers below handle that pattern.

/// Run a blocking FFI call on a detached task so it never blocks the main actor.
private func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

public func listRolesAsync() async throws -> [FfiRole] {
    try await detached { try listRoles() }
}

public func createRoleAsync(name: String) async throws -> Int64 {
    try await detached { try createRole(name: name) }
}

public func updateRoleAsync(id: Int64, name: String) async throws {
    try await detached { try updateRole(id: id, name: name) }
}

public func deleteRoleAsync(id: Int64) async throws {
    try await detached { try deleteRole(id: id) }
}

public func listEmployeesAsync() async throws -> [FfiEmployee] {
    try await detached { try listEmployees() }
}

public func createEmployeeAsync(_ employee: FfiEmployee) async throws -> Int64 {
    try await detached { try createEmployee(employee: employee) }
}

public func updateEmployeeAsync(_ employee: FfiEmployee) async throws {
    try await detached { try updateEmployee(employee: employee) }
}

public func deleteEmployeeAsync(id: Int64) async throws {
    try await detached { try deleteEmployee(id: id) }
}

public func listShiftTemplatesAsync() async throws -> [FfiShiftTemplate] {
    try await detached { try listShiftTemplates() }
}

public func createShiftTemplateAsync(_ template: FfiShiftTemplate) async throws -> Int64 {
    try await detached { try createShiftTemplate(template: template) }
}

public func updateShiftTemplateAsync(_ template: FfiShiftTemplate) async throws {
    try await detached { try updateShiftTemplate(template: template) }
}

public func deleteShiftTemplateAsync(id: Int64) async throws {
    try await detached { try deleteShiftTemplate(id: id) }
}

public func getWeekScheduleAsync(weekStart: String) async throws -> FfiWeekSchedule? {
    try await detached { try getWeekSchedule(weekStart: weekStart) }
}

public func runScheduleAsync(weekStart: String) async throws -> FfiScheduleResult {
    try await detached { try runSchedule(weekStart: weekStart) }
}

public func materialiseWeekAsync(weekStart: String) async throws -> Int64 {
    try await detached { try materialiseWeek(weekStart: weekStart) }
}

public func createEmptyWeekAsync(weekStart: String) async throws -> Int64 {
    try await detached { try createEmptyWeek(weekStart: weekStart) }
}

public func deleteWeekAsync(weekStart: String) async throws {
    try await detached { try deleteWeek(weekStart: weekStart) }
}

public func updateAssignmentStatusAsync(id: Int64, status: String) async throws {
    try await detached { try updateAssignmentStatus(id: id, status: status) }
}

public func swapAssignmentsAsync(idA: Int64, idB: Int64) async throws {
    try await detached { try swapAssignments(idA: idA, idB: idB) }
}

public func deleteAssignmentAsync(id: Int64) async throws {
    try await detached { try deleteAssignment(id: id) }
}

public func createAssignmentAsync(_ assignment: FfiAssignment) async throws -> Int64 {
    try await detached { try createAssignment(assignment: assignment) }
}

public func moveAssignmentAsync(id: Int64, newShiftId: Int64) async throws {
    try await detached { try moveAssignment(id: id, newShiftId: newShiftId) }
}

public func deleteShiftAsync(id: Int64) async throws {
    try await detached { try deleteShift(id: id) }
}

public func updateShiftTimesAsync(id: Int64, startTime: String, endTime: String) async throws {
    try await detached { try updateShiftTimes(id: id, startTime: startTime, endTime: endTime) }
}

public func updateShiftAsync(id: Int64, minEmployees: UInt32, maxEmployees: UInt32, roleRequirements: [FfiRoleRequirement]) async throws {
    try await detached { try updateShift(id: id, minEmployees: minEmployees, maxEmployees: maxEmployees, roleRequirements: roleRequirements) }
}

public func createAdHocShiftAsync(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String, roleRequirements: [FfiRoleRequirement]) async throws -> Int64 {
    try await detached { try createAdHocShift(rotaId: rotaId, date: date, startTime: startTime, endTime: endTime, requiredRole: requiredRole, roleRequirements: roleRequirements) }
}

public func listShiftsForRotaAsync(rotaId: Int64) async throws -> [FfiShift] {
    try await detached { try listShiftsForRota(rotaId: rotaId) }
}

// MARK: - Override async wrappers

public func upsertEmployeeAvailabilityOverrideAsync(override_: FfiEmployeeAvailabilityOverride) async throws -> Int64 {
    try await detached { try upsertEmployeeAvailabilityOverride(override: override_) }
}

public func getEmployeeAvailabilityOverrideAsync(employeeId: Int64, date: String) async throws -> FfiEmployeeAvailabilityOverride? {
    try await detached { try getEmployeeAvailabilityOverride(employeeId: employeeId, date: date) }
}

public func listEmployeeAvailabilityOverridesAsync(employeeId: Int64) async throws -> [FfiEmployeeAvailabilityOverride] {
    try await detached { try listEmployeeAvailabilityOverrides(employeeId: employeeId) }
}

public func listAllEmployeeAvailabilityOverridesAsync() async throws -> [FfiEmployeeAvailabilityOverride] {
    try await detached { try listAllEmployeeAvailabilityOverrides() }
}

public func deleteEmployeeAvailabilityOverrideAsync(id: Int64) async throws {
    try await detached { try deleteEmployeeAvailabilityOverride(id: id) }
}

public func upsertShiftTemplateOverrideAsync(override_: FfiShiftTemplateOverride) async throws -> Int64 {
    try await detached { try upsertShiftTemplateOverride(override: override_) }
}

public func getShiftTemplateOverrideAsync(templateId: Int64, date: String) async throws -> FfiShiftTemplateOverride? {
    try await detached { try getShiftTemplateOverride(templateId: templateId, date: date) }
}

public func listShiftTemplateOverridesForTemplateAsync(templateId: Int64) async throws -> [FfiShiftTemplateOverride] {
    try await detached { try listShiftTemplateOverridesForTemplate(templateId: templateId) }
}

public func listAllShiftTemplateOverridesAsync() async throws -> [FfiShiftTemplateOverride] {
    try await detached { try listAllShiftTemplateOverrides() }
}

public func deleteShiftTemplateOverrideAsync(id: Int64) async throws {
    try await detached { try deleteShiftTemplateOverride(id: id) }
}

// MARK: - Empty availability helper

/// Returns an empty availability slot list (all hours default to Maybe in the scheduler).
public func emptyAvailability() -> [AvailabilitySlot] { [] }

/// Returns today's Monday formatted as "YYYY-MM-DD".
public func currentWeekStart() -> String {
    weekStart(weeksFromNow: 0)
}

/// Returns the Monday of the week `weeksAhead` weeks from now.
public func weekStart(weeksFromNow offset: Int) -> String {
    let cal = Calendar(identifier: .iso8601)
    let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
    let target = cal.date(byAdding: .weekOfYear, value: offset, to: monday)!
    return isoDateFmt.string(from: target)
}

// MARK: - Employee Shift History

public func listEmployeeShiftHistoryAsync(employeeId: Int64) async throws -> [FfiEmployeeShiftRecord] {
    try await detached { try listEmployeeShiftHistory(employeeId: employeeId) }
}

public func listAllShiftHistoryAsync(startDate: String?, endDate: String?) async throws -> [FfiEmployeeShiftRecord] {
    try await detached { try listAllShiftHistory(startDate: startDate, endDate: endDate) }
}

// MARK: - Saves

public func createSaveAsync(rotaId: Int64, source: String) async throws -> Int64 {
    try await detached { try createSave(rotaId: rotaId, source: source) }
}

public func listSavesAsync(rotaId: Int64?) async throws -> [FfiSave] {
    try await detached { try listSaves(rotaId: rotaId) }
}

public func getSaveDetailAsync(saveId: Int64) async throws -> FfiSaveDetail? {
    try await detached { try getSaveDetail(saveId: saveId) }
}

public func rotaHasSavesAsync(rotaId: Int64) async throws -> Bool {
    try await detached { try rotaHasSaves(rotaId: rotaId) }
}

public func restoreToSaveAsync(saveId: Int64) async throws -> FfiRestoreResult {
    try await detached { try restoreToSave(saveId: saveId) }
}

public func diffRotaAsync(rotaId: Int64) async throws -> [FfiShiftDiff] {
    try await detached { try diffRota(rotaId: rotaId) }
}

public func diffRotaDetailedAsync(rotaId: Int64) async throws -> [FfiChangeDetail] {
    try await detached { try diffRotaDetailed(rotaId: rotaId) }
}

public func diffSavesDetailedAsync(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail] {
    try await detached { try diffSavesDetailed(oldSaveId: oldSaveId, newSaveId: newSaveId) }
}

public func diffSaveVsPreviousAsync(saveId: Int64) async throws -> [FfiChangeDetail] {
    try await detached { try diffSaveVsPrevious(saveId: saveId) }
}

public func addSaveTagAsync(saveId: Int64, tag: String) async throws {
    try await detached { try addSaveTag(saveId: saveId, tag: tag) }
}

public func removeSaveTagAsync(saveId: Int64, tag: String) async throws {
    try await detached { try removeSaveTag(saveId: saveId, tag: tag) }
}

// MARK: - Export

public func exportWeekScheduleAsync(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult {
    try await detached { try exportWeekSchedule(weekStart: weekStart, config: config) }
}

public func exportEmployeeScheduleAsync(config: FfiEmployeeExportConfig) async throws -> FfiExportResult {
    try await detached { try exportEmployeeSchedule(config: config) }
}

public func exportEmployeeBundleAsync(config: FfiEmployeeExportConfig) async throws -> [FfiExportResult] {
    try await detached { try exportEmployeeBundle(config: config) }
}

public func exportPreviewFullAsync(config: FfiExportConfig) async throws -> FfiExportResult {
    try await detached { try exportPreviewFull(config: config) }
}

public func exportPreviewEmployeeAsync(config: FfiEmployeeExportConfig) async throws -> FfiExportResult {
    try await detached { try exportPreviewEmployee(config: config) }
}

// MARK: - Roster Import

public func parseRosterFileAsync(bytes: Data, formatHint: String, strategy: String) async throws -> FfiParsedRoster {
    try await detached { try parseRosterFile(bytes: bytes, formatHint: formatHint, strategy: strategy) }
}

public func applyRosterImportAsync(rows: [FfiParsedEmployeeRow]) async throws -> FfiImportSummary {
    try await detached { try applyRosterImport(rows: rows) }
}

// MARK: - Data Bundle Exchange

public func exportDataBundleAsync(sections: FfiBundleSections) async throws -> FfiExportResult {
    try await detached { try exportDataBundle(sections: sections) }
}

public func inspectDataBundleAsync(bytes: Data) async throws -> FfiBundleInfo {
    try await detached { try inspectDataBundle(bytes: bytes) }
}

public func importDataBundleAsync(bytes: Data) async throws -> FfiBundleImportSummary {
    try await detached { try importDataBundle(bytes: bytes) }
}

// MARK: - Sync

public func getPendingSyncRecordsAsync(tableName: String) async throws -> [FfiSyncRecord] {
    try await detached { try getPendingSyncRecords(tableName: tableName) }
}

public func markRecordsSyncedAsync(tableName: String, recordIds: [Int64], baseSnapshots: [String]) async throws {
    try await detached { try markRecordsSynced(tableName: tableName, recordIds: recordIds, baseSnapshots: baseSnapshots) }
}

public func applyRemoteRecordAsync(record: FfiSyncRecord) async throws {
    try await detached { try applyRemoteRecord(record: record) }
}

public func getSyncMetadataAsync(key: String) async throws -> String? {
    try await detached { try getSyncMetadata(key: key) }
}

public func setSyncMetadataAsync(key: String, value: String) async throws {
    try await detached { try setSyncMetadata(key: key, value: value) }
}

public func getBaseSnapshotsAsync(tableName: String, recordIds: [Int64]) async throws -> [FfiBaseSnapshot] {
    try await detached { try getBaseSnapshots(tableName: tableName, recordIds: recordIds) }
}

public func getPendingTombstonesAsync() async throws -> [FfiTombstone] {
    try await detached { try getPendingTombstones() }
}

public func clearTombstonesAsync(ids: [Int64]) async throws {
    try await detached { try clearTombstones(ids: ids) }
}

public func countEmployeesAsync() async throws -> Int64 {
    try await detached { try countEmployees() }
}

// MARK: - Availability Progress

public func listAvailabilityProgressAsync(weekStart: String) async throws -> [FfiAvailabilityProgress] {
    try await detached { try listAvailabilityProgress(weekStart: weekStart) }
}

public func setAvailabilityProgressAsync(employeeId: Int64, weekStart: String, done: Bool) async throws {
    try await detached { try setAvailabilityProgress(employeeId: employeeId, weekStart: weekStart, done: done) }
}
