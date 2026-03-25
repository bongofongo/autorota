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
