import XCTest
@testable import AutorotaKit

/// Integration tests that exercise the real Rust FFI through AutorotaKit.
/// These require the XCFramework to be built first.
///
/// Since initDb uses a global OnceLock, all tests share a single database
/// initialized in setUp. Tests that modify state should clean up after themselves.
final class IntegrationTests: XCTestCase {

    private static var tempDir: URL!
    private static var initialized = false

    override class func setUp() {
        super.setUp()
        guard !initialized else { return }
        initialized = true

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutorotaKitTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir

        let dbPath = dir.appendingPathComponent("test.db").path
        try! initDb(dbPath: dbPath)
    }

    override class func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }

    // MARK: - Roles

    func testRoleCRUD() async throws {
        let roleId = try await createRoleAsync(name: "TestRole")
        XCTAssertGreaterThan(roleId, 0)

        var roles = try await listRolesAsync()
        XCTAssertTrue(roles.contains(where: { $0.name == "TestRole" }))

        try await updateRoleAsync(id: roleId, name: "RenamedRole")
        roles = try await listRolesAsync()
        XCTAssertTrue(roles.contains(where: { $0.name == "RenamedRole" }))
        XCTAssertFalse(roles.contains(where: { $0.name == "TestRole" }))

        try await deleteRoleAsync(id: roleId)
        roles = try await listRolesAsync()
        XCTAssertFalse(roles.contains(where: { $0.name == "RenamedRole" }))
    }

    // MARK: - Employees

    func testEmployeeCRUD() async throws {
        // Setup: create role
        let roleId = try await createRoleAsync(name: "EmpTestRole")

        let emp = Fixtures.employee(firstName: "Test", lastName: "User", role: "EmpTestRole")
        let empId = try await createEmployeeAsync(emp)
        XCTAssertGreaterThan(empId, 0)

        let employees = try await listEmployeesAsync()
        let found = employees.first(where: { $0.id == empId })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.firstName, "Test")
        XCTAssertEqual(found?.lastName, "User")
        XCTAssertEqual(found?.displayName, "Test User")

        // Update
        var updated = found!
        updated.nickname = "Testy"
        try await updateEmployeeAsync(updated)

        let employees2 = try await listEmployeesAsync()
        let updated2 = employees2.first(where: { $0.id == empId })
        XCTAssertEqual(updated2?.displayName, "Testy")

        // Delete (soft)
        try await deleteEmployeeAsync(id: empId)
        let after = try await listEmployeesAsync()
        XCTAssertFalse(after.contains(where: { $0.id == empId }))

        // Cleanup role
        try await deleteRoleAsync(id: roleId)
    }

    // MARK: - Shift Templates

    func testShiftTemplateCRUD() async throws {
        let roleId = try await createRoleAsync(name: "TmplTestRole")

        let tmpl = Fixtures.shiftTemplate(
            name: "Test Morning",
            weekdays: ["Mon", "Wed", "Fri"],
            role: "TmplTestRole"
        )
        let tmplId = try await createShiftTemplateAsync(tmpl)
        XCTAssertGreaterThan(tmplId, 0)

        let templates = try await listShiftTemplatesAsync()
        let found = templates.first(where: { $0.id == tmplId })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.weekdays, ["Mon", "Wed", "Fri"])
        XCTAssertEqual(found?.startTime, "07:00")
        XCTAssertEqual(found?.endTime, "12:00")

        // Delete
        try await deleteShiftTemplateAsync(id: tmplId)
        let after = try await listShiftTemplatesAsync()
        XCTAssertFalse(after.contains(where: { $0.id == tmplId }))

        try await deleteRoleAsync(id: roleId)
    }

    // MARK: - Schedule Workflow

    func testScheduleWorkflow() async throws {
        // Setup: role + employee + template
        let roleId = try await createRoleAsync(name: "SchedTestRole")

        let emp = Fixtures.employee(firstName: "Sched", lastName: "Worker", role: "SchedTestRole")
        let empId = try await createEmployeeAsync(emp)

        let tmpl = Fixtures.shiftTemplate(
            name: "Sched Morning",
            weekdays: ["Mon"],
            role: "SchedTestRole"
        )
        let tmplId = try await createShiftTemplateAsync(tmpl)

        // Materialise a far-future week
        let ws = "2028-01-03" // A Monday
        let rotaId = try await materialiseWeekAsync(weekStart: ws)
        XCTAssertGreaterThan(rotaId, 0)

        // Verify shifts were created
        let shifts = try await listShiftsForRotaAsync(rotaId: rotaId)
        XCTAssertEqual(shifts.count, 1)
        XCTAssertEqual(shifts[0].date, "2028-01-03")

        // Get schedule — should have shifts but no entries yet
        let schedule = try await getWeekScheduleAsync(weekStart: ws)
        XCTAssertNotNil(schedule)
        XCTAssertEqual(schedule?.shifts.count, 1)
        XCTAssertEqual(schedule?.entries.count, 0)

        // Cleanup
        try await deleteShiftTemplateAsync(id: tmplId)
        try await deleteEmployeeAsync(id: empId)
        try await deleteRoleAsync(id: roleId)
    }

    // MARK: - Availability Roundtrip

    func testAvailabilityRoundtrip() async throws {
        let roleId = try await createRoleAsync(name: "AvailTestRole")

        let slots = [
            AvailabilitySlot(weekday: "Mon", hour: 8, state: "Yes"),
            AvailabilitySlot(weekday: "Tue", hour: 14, state: "Maybe"),
            AvailabilitySlot(weekday: "Fri", hour: 20, state: "No"),
        ]

        let emp = FfiEmployee(
            id: 0,
            firstName: "Avail",
            lastName: "Test",
            nickname: nil,
            displayName: "",
            roles: ["AvailTestRole"],
            startDate: "2026-01-01",
            targetWeeklyHours: 30.0,
            weeklyHoursDeviation: 5.0,
            maxDailyHours: 8.0,
            notes: nil,
            bankDetails: nil,
            hourlyWage: nil,
            wageCurrency: nil,
            defaultAvailability: slots,
            availability: slots,
            deleted: false
        )

        let empId = try await createEmployeeAsync(emp)
        let employees = try await listEmployeesAsync()
        let found = employees.first(where: { $0.id == empId })!

        XCTAssertEqual(found.defaultAvailability.count, 3)

        let monSlot = found.defaultAvailability.first(where: { $0.weekday == "Mon" && $0.hour == 8 })
        XCTAssertEqual(monSlot?.state, "Yes")

        let friSlot = found.defaultAvailability.first(where: { $0.weekday == "Fri" && $0.hour == 20 })
        XCTAssertEqual(friSlot?.state, "No")

        // Cleanup
        try await deleteEmployeeAsync(id: empId)
        try await deleteRoleAsync(id: roleId)
    }
}
