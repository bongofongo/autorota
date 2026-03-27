import Foundation
import AutorotaKit
@testable import AutorotaApp

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

    func finalizeRota(id: Int64) async throws {
        callLog.append("finalizeRota:\(id)")
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

    func createAdHocShift(rotaId: Int64, date: String, startTime: String, endTime: String, requiredRole: String) async throws -> Int64 {
        callLog.append("createAdHocShift:\(date)")
        if let e = errorToThrow { throw e }
        return 1
    }

    func listShiftsForRota(rotaId: Int64) async throws -> [FfiShift] {
        callLog.append("listShiftsForRota:\(rotaId)")
        if let e = errorToThrow { throw e }
        return stubbedShifts
    }
}
