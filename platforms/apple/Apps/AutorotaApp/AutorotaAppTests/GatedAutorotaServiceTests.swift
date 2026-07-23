import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@MainActor
struct GatedAutorotaServiceTests {

    @Test
    func mutationsThrowWhenExpired() async throws {
        let mock = MockAutorotaService()
        let gate = LicenseGate()
        gate.update(state: .expired(previousTier: .localManager))
        let gated = GatedAutorotaService(inner: mock, gate: gate)

        await #expect(throws: LicenseError.readOnly) { _ = try await gated.createRole(name: "Barista") }
        await #expect(throws: LicenseError.readOnly) { _ = try await gated.createEmployee(makeEmployee()) }
        await #expect(throws: LicenseError.readOnly) { _ = try await gated.runSchedule(weekStart: "2026-04-27") }
        await #expect(throws: LicenseError.readOnly) { _ = try await gated.createSave(rotaId: 1, source: .manual) }
        await #expect(throws: LicenseError.readOnly) {
            _ = try await gated.applyRosterImport(rows: [])
        }
        await #expect(throws: LicenseError.readOnly) {
            try await gated.setAvailabilityProgress(employeeId: 1, weekStart: "2026-04-27", done: true)
        }
    }

    @Test
    func mutationsSucceedWhenInTrial() async throws {
        let mock = MockAutorotaService()
        let gate = LicenseGate()
        gate.update(state: .trial(startedAt: Date(), daysRemaining: 7))
        let gated = GatedAutorotaService(inner: mock, gate: gate)

        let id = try await gated.createRole(name: "Barista")
        #expect(id == 1)
        #expect(mock.callLog.contains("createRole:Barista"))
    }

    @Test
    func readsPassThroughEvenWhenExpired() async throws {
        let mock = MockAutorotaService()
        mock.stubbedRoles = []
        let gate = LicenseGate()
        gate.update(state: .expired(previousTier: .localManager))
        let gated = GatedAutorotaService(inner: mock, gate: gate)

        _ = try await gated.listRoles()
        _ = try await gated.listEmployees()
        _ = try await gated.getWeekSchedule(weekStart: "2026-04-27")
        _ = try await gated.diffRota(rotaId: 1)
        _ = try await gated.listSaves(rotaId: nil)

        #expect(mock.callLog.contains("listRoles"))
    }

    private func makeEmployee() -> FfiEmployee {
        FfiEmployee(
            id: 1, firstName: "A", lastName: "B", nickname: nil,
            displayName: "A B", roles: [], startDate: "2025-01-01",
            targetWeeklyHours: 0, weeklyHoursDeviation: 0, maxDailyHours: 0,
            notes: nil, bankDetails: nil, phone: nil, email: nil,
            preferredContact: nil, hourlyWage: nil, wageCurrency: nil,
            defaultAvailability: [], availability: [], deleted: false
        )
    }
}
