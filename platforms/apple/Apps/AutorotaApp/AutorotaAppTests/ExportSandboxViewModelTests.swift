import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("ExportSandboxViewModel")
struct ExportSandboxViewModelTests {

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "sandbox-tests-\(UUID().uuidString)"))
    }

    @Test func startsWithValidInitialLayout() throws {
        let vm = ExportSandboxViewModel(service: MockAutorotaService(), defaults: try makeDefaults())

        #expect(vm.layout == .initial)
        #expect(vm.validationError == nil)
        #expect(Set(vm.trayFields) == [.role, .cost])
    }

    @Test func costPillIsCellsOnly() throws {
        let vm = ExportSandboxViewModel(service: MockAutorotaService(), defaults: try makeDefaults())

        #expect(vm.canDrop(.cost, in: .rows) == false)
        #expect(vm.drop(.cost, in: .rows) == false)
        #expect(vm.rejectionMessage != nil)

        // Allowed in cells regardless of where the employee pill sits.
        #expect(vm.drop(.cost, in: .cells))
        #expect(vm.drop(.employeeName, in: .cells))
        #expect(vm.layout.cells.contains(.cost))
        #expect(vm.canDrop(.cost, in: .cells))
    }

    @Test func dropMovesPillBetweenZonesWithoutDuplication() throws {
        let vm = ExportSandboxViewModel(service: MockAutorotaService(), defaults: try makeDefaults())

        // shiftName starts in cells; move it to rows... blocked? rows hold
        // the employee pill, so shiftName is rejected there.
        #expect(vm.drop(.shiftName, in: .rows) == false)

        // Move employee to cells first, then shiftName to rows is allowed.
        #expect(vm.drop(.employeeName, in: .cells))
        #expect(vm.drop(.shiftName, in: .rows))

        // Consumable invariant: each field lives in exactly one zone.
        for field in ExportField.allCases {
            let placements = [
                vm.layout.rows.contains(field),
                vm.layout.cells.contains(field),
                vm.trayFields.contains(field),
            ].filter { $0 }.count
            #expect(placements == 1, "\(field) must be in exactly one zone")
        }
        #expect(vm.layout.rows == [.shiftName])
        #expect(vm.layout.cells.contains(.employeeName))
    }

    @Test func rejectedDropSetsGuidance() throws {
        let vm = ExportSandboxViewModel(service: MockAutorotaService(), defaults: try makeDefaults())

        // Employee pill sits in rows initially → other pills can't join it.
        #expect(vm.canDrop(.time, in: .rows) == false)
        #expect(vm.drop(.time, in: .rows) == false)
        #expect(vm.rejectionMessage != nil)

        // A successful drop clears the message.
        #expect(vm.drop(.time, in: .cells))
        #expect(vm.rejectionMessage == nil)
    }

    @Test func employeeDropEvictsCohabitantsToTray() throws {
        let vm = ExportSandboxViewModel(service: MockAutorotaService(), defaults: try makeDefaults())

        // Initial: rows=[employee], cells=[shiftName, time]. Moving the
        // employee into cells must push shiftName and time back to the tray —
        // a zone holding the employee pill renders names only.
        #expect(vm.drop(.employeeName, in: .cells))

        #expect(vm.layout.cells == [.employeeName])
        #expect(vm.layout.rows.isEmpty)
        #expect(Set(vm.trayFields) == [.shiftName, .time, .role, .cost])
    }

    @Test func employeeDropKeepsCostInCells() throws {
        let vm = ExportSandboxViewModel(service: MockAutorotaService(), defaults: try makeDefaults())

        // Cost may share the cells with the employee pill — the engine
        // appends costs to names — so it survives the eviction.
        #expect(vm.drop(.cost, in: .cells))
        #expect(vm.drop(.employeeName, in: .cells))

        #expect(Set(vm.layout.cells) == [.employeeName, .cost])
        #expect(Set(vm.trayFields) == [.shiftName, .time, .role])
    }

    @Test func returnToTrayUnplacesPill() throws {
        let vm = ExportSandboxViewModel(service: MockAutorotaService(), defaults: try makeDefaults())

        vm.returnToTray(.shiftName)

        #expect(!vm.layout.cells.contains(.shiftName))
        #expect(vm.trayFields.contains(.shiftName))
    }

    @Test func sectionAddRemoveReorder() throws {
        let vm = ExportSandboxViewModel(service: MockAutorotaService(), defaults: try makeDefaults())
        let barista = FfiRole(id: 1, name: "Barista")
        let chef = FfiRole(id: 2, name: "Chef")

        vm.addSection(barista)
        vm.addSection(chef)
        #expect(vm.layout.sections.map(\.name) == ["Barista", "Chef"])

        // Duplicate adds are ignored.
        vm.addSection(barista)
        #expect(vm.layout.sections.count == 2)

        vm.moveSections(from: IndexSet(integer: 1), to: 0)
        #expect(vm.layout.sections.map(\.name) == ["Chef", "Barista"])

        vm.removeSection(id: 2)
        #expect(vm.layout.sections.map(\.name) == ["Barista"])
    }

    @Test func placementsPersistAcrossInstances() throws {
        let defaults = try makeDefaults()
        let vm = ExportSandboxViewModel(service: MockAutorotaService(), defaults: defaults)
        vm.drop(.employeeName, in: .cells)
        vm.drop(.time, in: .rows)
        vm.addSection(FfiRole(id: 5, name: "Barista"))

        let reloaded = ExportSandboxViewModel(service: MockAutorotaService(), defaults: defaults)

        #expect(reloaded.layout == vm.layout)
        #expect(reloaded.layout.sections.first?.name == "Barista")
    }

    @Test func loadRolesRefreshesRenamedAndDropsDeletedSections() async throws {
        let defaults = try makeDefaults()
        ExportCustomLayout(
            rows: [.employeeName],
            cells: [.time],
            sections: [
                ExportRoleSection(id: 1, name: "Old Name"),
                ExportRoleSection(id: 99, name: "Deleted Role"),
            ]
        ).save(to: defaults)

        let mock = MockAutorotaService()
        mock.stubbedRoles = [FfiRole(id: 1, name: "Barista")]
        let vm = ExportSandboxViewModel(service: mock, defaults: defaults)

        await vm.loadRoles()

        #expect(vm.rolesLoaded)
        #expect(vm.layout.sections.count == 1)
        #expect(vm.layout.sections.first?.name == "Barista")
        // Placed roles don't show in the tray.
        #expect(vm.trayRoles.isEmpty)
    }

    @Test func loadRolesErrorSurfaces() async throws {
        let mock = MockAutorotaService()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let vm = ExportSandboxViewModel(service: mock, defaults: try makeDefaults())

        await vm.loadRoles()

        #expect(vm.rolesError != nil)
        #expect(vm.rolesLoaded)
    }
}
