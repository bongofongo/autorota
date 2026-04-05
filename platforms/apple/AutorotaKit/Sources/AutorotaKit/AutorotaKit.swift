// AutorotaKit.swift
//
// Thin ergonomics layer on top of the UniFFI-generated bindings.
// The generated file (autorota_ffi.swift) lives alongside this file in
// Sources/AutorotaKit/generated/ and is compiled as part of the same target.

import Foundation

// MARK: - Database initialisation helper

/// Resolve the app-support database path and initialise the Rust pool.
/// Call once from your @main App's init() or Scene body before any other API.
public func autorotaInitDb() throws {
    let appSupport = try FileManager.default
        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = appSupport.appendingPathComponent("AutorotaApp", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dbURL = dir.appendingPathComponent("autorota.db")
    try initDb(dbPath: dbURL.path)
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

public func finalizeRotaAsync(id: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try finalizeRota(id: id)
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

public func createAdHocShiftAsync(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try createAdHocShift(rotaId: rotaId, date: date, startTime: startTime, endTime: endTime, requiredRole: requiredRole)
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

// MARK: - Staging & Commits

public func stageShiftsAsync(shiftIds: [Int64]) async throws {
    try await Task.detached(priority: .userInitiated) {
        try stageShifts(shiftIds: shiftIds)
    }.value
}

public func stageDayAsync(rotaId: Int64, date: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try stageDay(rotaId: rotaId, date: date)
    }.value
}

public func stageWeekAsync(rotaId: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try stageWeek(rotaId: rotaId)
    }.value
}

public func unstageShiftsAsync(shiftIds: [Int64]) async throws {
    try await Task.detached(priority: .userInitiated) {
        try unstageShifts(shiftIds: shiftIds)
    }.value
}

public func unstageDayAsync(rotaId: Int64, date: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try unstageDay(rotaId: rotaId, date: date)
    }.value
}

public func unstageWeekAsync(rotaId: Int64) async throws {
    try await Task.detached(priority: .userInitiated) {
        try unstageWeek(rotaId: rotaId)
    }.value
}

public func getStagingStateAsync(rotaId: Int64) async throws -> FfiStagingState {
    try await Task.detached(priority: .userInitiated) {
        try getStagingState(rotaId: rotaId)
    }.value
}

public func commitStagedShiftsAsync(rotaId: Int64) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try commitStagedShifts(rotaId: rotaId)
    }.value
}

public func listCommitsAsync(rotaId: Int64?) async throws -> [FfiCommit] {
    try await Task.detached(priority: .userInitiated) {
        try listCommits(rotaId: rotaId)
    }.value
}

public func getCommitDetailAsync(commitId: Int64) async throws -> FfiCommitDetail? {
    try await Task.detached(priority: .userInitiated) {
        try getCommitDetail(commitId: commitId)
    }.value
}

public func rotaIsCommittedAsync(rotaId: Int64) async throws -> Bool {
    try await Task.detached(priority: .userInitiated) {
        try rotaIsCommitted(rotaId: rotaId)
    }.value
}

// MARK: - Export

public func exportWeekScheduleAsync(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult {
    try await Task.detached(priority: .userInitiated) {
        try exportWeekSchedule(weekStart: weekStart, config: config)
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
