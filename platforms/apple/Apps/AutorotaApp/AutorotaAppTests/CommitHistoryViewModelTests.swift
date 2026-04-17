import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("ActivityLogViewModel")
struct ActivityLogViewModelTests {

    private func makeMock() -> MockAutorotaService {
        MockAutorotaService()
    }

    private func makeSave(id: Int64 = 1, rotaId: Int64 = 1, weekStart: String = "2026-03-30", label: String? = nil) -> FfiSave {
        FfiSave(
            id: id,
            rotaId: rotaId,
            savedAt: "2026-03-30T12:00:00Z",
            summary: "2 shifts, 1 employee, 8h",
            weekStart: weekStart,
            label: label
        )
    }

    // MARK: - Loading

    @Test("loadSaves surfaces clean error message from FfiError")
    func loadSavesSurfacesCleanFfiError() async {
        let mock = makeMock()
        mock.errorToThrow = FfiError.Db(msg: "A referenced record no longer exists.")
        let vm = ActivityLogViewModel(service: mock)

        await vm.loadSaves()

        #expect(vm.error == "A referenced record no longer exists.")
    }

    @Test("loadSaves surfaces clean error for non-FfiError")
    func loadSavesSurfacesGenericError() async {
        let mock = makeMock()
        mock.errorToThrow = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something went wrong"])
        let vm = ActivityLogViewModel(service: mock)

        await vm.loadSaves()

        #expect(vm.error == "Something went wrong")
    }

    @Test("loadSaves with empty result shows no error")
    func loadSavesEmptyNoError() async {
        let mock = makeMock()
        let vm = ActivityLogViewModel(service: mock)

        await vm.loadSaves()

        #expect(vm.error == nil)
        #expect(vm.saves.isEmpty)
    }

    // MARK: - Grouping

    @Test("savesByWeek groups and sorts by week descending")
    func savesByWeekGroupsCorrectly() async {
        let mock = makeMock()
        mock.stubbedSaves = [
            makeSave(id: 1, weekStart: "2026-03-30"),
            makeSave(id: 2, weekStart: "2026-04-06"),
            makeSave(id: 3, weekStart: "2026-03-30"),
        ]
        let vm = ActivityLogViewModel(service: mock)
        await vm.loadSaves()

        let weeks = vm.savesByWeek
        #expect(weeks.count == 2)
        #expect(weeks[0].weekStart == "2026-04-06")
        #expect(weeks[1].weekStart == "2026-03-30")
        #expect(weeks[1].saves.count == 2)
    }

    // MARK: - Expand/Collapse

    @Test("toggleExpanded expands and collapses")
    func toggleExpandedWorks() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave()]
        mock.stubbedDetailedDiffResult = []
        let vm = ActivityLogViewModel(service: mock)
        await vm.loadSaves()

        await vm.toggleExpanded(saveId: 1)
        #expect(vm.expandedSaveId == 1)

        await vm.toggleExpanded(saveId: 1)
        #expect(vm.expandedSaveId == nil)
    }

    // MARK: - Label

    @Test("updateLabel trims whitespace and updates local cache")
    func updateLabelTrimsAndUpdates() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave()]
        let vm = ActivityLogViewModel(service: mock)
        await vm.loadSaves()

        await vm.updateLabel(saveId: 1, label: "  Final schedule  ")

        #expect(vm.saves[0].label == "Final schedule")
        #expect(mock.callLog.contains("updateSaveLabel:1:Final schedule"))
    }

    @Test("updateLabel with empty string clears label")
    func updateLabelEmptyClearsLabel() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave(label: "Old label")]
        let vm = ActivityLogViewModel(service: mock)
        await vm.loadSaves()

        await vm.updateLabel(saveId: 1, label: "")

        #expect(vm.saves[0].label == nil)
        #expect(mock.callLog.contains("updateSaveLabel:1:nil"))
    }

    // MARK: - Restore

    @Test("restoreToSave sets toast on success")
    func restoreToSaveSetsToast() async {
        let mock = makeMock()
        mock.stubbedRestoreResult = FfiRestoreResult(
            rotaId: 1, shiftsRestored: 5, assignmentsRestored: 3, assignmentsSkipped: 1
        )
        let vm = ActivityLogViewModel(service: mock)

        await vm.restoreToSave(id: 1, summary: "test save", weekStart: "2026-03-30")

        #expect(vm.restoreToast != nil)
        #expect(vm.restoreToast?.shiftsRestored == 5)
        #expect(vm.restoreToast?.assignmentsSkipped == 1)
    }

    @Test("restoreToSave surfaces error")
    func restoreToSaveSurfacesError() async {
        let mock = makeMock()
        mock.errorToThrow = FfiError.NotFound(msg: "Save not found")
        let vm = ActivityLogViewModel(service: mock)

        await vm.restoreToSave(id: 999, summary: "x", weekStart: "2026-03-30")

        #expect(vm.error == "Save not found")
        #expect(vm.restoreToast == nil)
    }
}
