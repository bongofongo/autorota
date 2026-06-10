import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("ExportCustomLayoutMapper")
struct ExportCustomLayoutMapperTests {

    // MARK: - Mapping

    @Test func employeeInRowsMapsToEmployeeLayout() throws {
        let layout = ExportCustomLayout(
            rows: [.employeeName],
            cells: [.shiftName, .time]
        )
        let config = try ExportCustomLayoutMapper.ffiConfig(layout, format: "csv")

        #expect(config.layout == "employee_by_weekday")
        #expect(config.showShiftName == true)
        #expect(config.showTimes == true)
        #expect(config.showRole == false)
        #expect(config.rowContent == nil)
        #expect(config.roleSections == nil)
        #expect(config.pdfTemplate == nil)
    }

    @Test func roleInCellsSetsShowRole() throws {
        let layout = ExportCustomLayout(
            rows: [.employeeName],
            cells: [.role]
        )
        let config = try ExportCustomLayoutMapper.ffiConfig(layout, format: "pdf")

        #expect(config.layout == "employee_by_weekday")
        #expect(config.showShiftName == false)
        #expect(config.showTimes == false)
        #expect(config.showRole == true)
        #expect(config.profile == "staff_schedule")
    }

    @Test func employeeInCellsMapsToShiftLayoutWithRowContent() throws {
        let layout = ExportCustomLayout(
            rows: [.time, .role],
            cells: [.employeeName]
        )
        let config = try ExportCustomLayoutMapper.ffiConfig(layout, format: "csv")

        #expect(config.layout == "shift_by_weekday")
        // Cells render employee names only; the flags stay off.
        #expect(config.showShiftName == false)
        #expect(config.showTimes == false)
        #expect(config.showRole == false)
        let rowContent = try #require(config.rowContent)
        #expect(rowContent.showShiftName == false)
        #expect(rowContent.showTimes == true)
        #expect(rowContent.showRole == true)
    }

    @Test func costInCellsSelectsManagerReport() throws {
        let layout = ExportCustomLayout(
            rows: [.employeeName],
            cells: [.shiftName, .cost]
        )
        let config = try ExportCustomLayoutMapper.ffiConfig(layout, format: "csv")

        #expect(config.profile == "manager_report")
        // Cost is a profile switch, not a cell flag.
        #expect(config.showShiftName == true)
        #expect(config.showTimes == false)
        #expect(config.showRole == false)
    }

    @Test func costWithEmployeeInCellsSelectsManagerReport() throws {
        let layout = ExportCustomLayout(
            rows: [.time],
            cells: [.employeeName, .cost]
        )
        let config = try ExportCustomLayoutMapper.ffiConfig(layout, format: "csv")

        #expect(config.layout == "shift_by_weekday")
        #expect(config.profile == "manager_report")
    }

    @Test func noCostPillSelectsStaffSchedule() throws {
        let layout = ExportCustomLayout(rows: [.employeeName], cells: [.time])
        let config = try ExportCustomLayoutMapper.ffiConfig(layout, format: "csv")

        #expect(config.profile == "staff_schedule")
    }

    @Test func sectionsPassThroughInOrder() throws {
        let layout = ExportCustomLayout(
            rows: [.employeeName],
            cells: [.time],
            sections: [
                ExportRoleSection(id: 2, name: "Chef"),
                ExportRoleSection(id: 1, name: "Barista"),
            ]
        )
        let config = try ExportCustomLayoutMapper.ffiConfig(layout, format: "csv")

        #expect(config.roleSections == ["Chef", "Barista"])
    }

    // MARK: - Validation

    @Test func employeeUnplacedIsInvalid() {
        let layout = ExportCustomLayout(rows: [.shiftName], cells: [.time])
        #expect(ExportCustomLayoutMapper.validate(layout) == .employeeUnplaced)
        #expect(throws: CustomLayoutError.employeeUnplaced) {
            try ExportCustomLayoutMapper.ffiConfig(layout, format: "csv")
        }
    }

    @Test func emptyCellsIsInvalid() {
        let layout = ExportCustomLayout(rows: [.employeeName], cells: [])
        #expect(ExportCustomLayoutMapper.validate(layout) == .cellsEmpty)
    }

    @Test func emptyRowsIsInvalid() {
        let layout = ExportCustomLayout(rows: [], cells: [.employeeName])
        #expect(ExportCustomLayoutMapper.validate(layout) == .rowsEmpty)
    }

    @Test func initialLayoutIsValid() {
        #expect(ExportCustomLayoutMapper.validate(.initial) == nil)
    }

    // MARK: - Persistence round-trip

    @Test func codableRoundTrip() throws {
        let layout = ExportCustomLayout(
            rows: [.shiftName, .time],
            cells: [.employeeName],
            sections: [ExportRoleSection(id: 7, name: "Barista")]
        )
        let defaults = try #require(UserDefaults(suiteName: "mapper-tests-\(UUID().uuidString)"))
        layout.save(to: defaults)
        let loaded = ExportCustomLayout.load(from: defaults)

        #expect(loaded == layout)
    }

    @Test func loadReturnsNilForGarbageBlob() throws {
        let defaults = try #require(UserDefaults(suiteName: "mapper-tests-\(UUID().uuidString)"))
        defaults.set(Data("not json".utf8), forKey: ExportCustomLayout.storageKey)

        #expect(ExportCustomLayout.load(from: defaults) == nil)
    }

    // MARK: - FullExportConfigBuilder

    @Test func builderPresetByEmployee() {
        let config = FullExportConfigBuilder.make(
            layoutPref: "employee_by_weekday",
            format: "pdf"
        )
        #expect(config.layout == "employee_by_weekday")
        #expect(config.showShiftName == true)
        #expect(config.showTimes == true)
        #expect(config.showRole == false)
        #expect(config.profile == "staff_schedule")
        // Weekly grid is the only template; nil lets the engine default.
        #expect(config.pdfTemplate == nil)
    }

    @Test func builderPresetByShift() {
        let config = FullExportConfigBuilder.make(
            layoutPref: "shift_by_weekday",
            format: "csv"
        )
        #expect(config.layout == "shift_by_weekday")
        #expect(config.showShiftName == false)
        #expect(config.showRole == true)
        #expect(config.profile == "staff_schedule")
        #expect(config.pdfTemplate == nil)
    }

    @Test func builderUsesCustomLayoutFromDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "builder-tests-\(UUID().uuidString)"))
        ExportCustomLayout(
            rows: [.time],
            cells: [.employeeName, .cost],
            sections: [ExportRoleSection(id: 1, name: "Barista")]
        ).save(to: defaults)

        let config = FullExportConfigBuilder.make(
            layoutPref: "custom",
            format: "pdf",
            defaults: defaults
        )
        #expect(config.layout == "shift_by_weekday")
        #expect(config.roleSections == ["Barista"])
        #expect(config.rowContent?.showTimes == true)
        #expect(config.profile == "manager_report")
        #expect(config.pdfTemplate == nil)
    }

    @Test func builderFallsBackWhenCustomBlobMissing() throws {
        let defaults = try #require(UserDefaults(suiteName: "builder-tests-\(UUID().uuidString)"))

        let config = FullExportConfigBuilder.make(
            layoutPref: "custom",
            format: "pdf",
            defaults: defaults
        )
        // By Employee preset fallback.
        #expect(config.layout == "employee_by_weekday")
        #expect(config.showShiftName == true)
        #expect(config.roleSections == nil)
    }

    @Test func builderFallsBackWhenCustomLayoutInvalid() throws {
        let defaults = try #require(UserDefaults(suiteName: "builder-tests-\(UUID().uuidString)"))
        // Employee pill unplaced → invalid.
        ExportCustomLayout(rows: [.shiftName], cells: [.time]).save(to: defaults)

        let config = FullExportConfigBuilder.make(
            layoutPref: "custom",
            format: "csv",
            defaults: defaults
        )
        #expect(config.layout == "employee_by_weekday")
    }
}
