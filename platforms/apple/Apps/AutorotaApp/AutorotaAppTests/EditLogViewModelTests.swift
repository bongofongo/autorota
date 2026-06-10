import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("EditLogViewModel")
struct EditLogViewModelTests {

    private func makeMock() -> MockAutorotaService {
        MockAutorotaService()
    }

    private func makeSave(
        id: Int64 = 1,
        rotaId: Int64 = 1,
        weekStart: String = "2026-03-30",
        tags: [String] = [],
        restoredAt: String? = nil
    ) -> FfiSave {
        FfiSave(
            id: id,
            rotaId: rotaId,
            savedAt: "2026-03-30T12:00:00Z",
            summary: "2 shifts, 1 employee, 8h",
            tags: tags,
            weekStart: weekStart,
            restoredAt: restoredAt
        )
    }

    // MARK: - Loading

    @Test("loadSaves surfaces clean error message from FfiError")
    func loadSavesSurfacesCleanFfiError() async {
        let mock = makeMock()
        mock.errorToThrow = FfiError.Db(code: .dbRowNotFound, msg: "row gone")
        let vm = EditLogViewModel(service: mock)

        await vm.loadSaves()

        #expect(vm.error == "This record no longer exists. It may have been deleted.")
    }

    @Test("loadSaves with empty result shows no error")
    func loadSavesEmptyNoError() async {
        let mock = makeMock()
        let vm = EditLogViewModel(service: mock)

        await vm.loadSaves()

        #expect(vm.error == nil)
        #expect(vm.saves.isEmpty)
    }

    // MARK: - Grouping

    @Test("groupedSaves groups by week and sorts descending")
    func groupedByWeek() async {
        let mock = makeMock()
        mock.stubbedSaves = [
            makeSave(id: 1, weekStart: "2026-03-30"),
            makeSave(id: 2, weekStart: "2026-04-06"),
            makeSave(id: 3, weekStart: "2026-03-30"),
        ]
        let vm = EditLogViewModel(service: mock)
        await vm.loadSaves()
        vm.grouping = .week

        let groups = vm.groupedSaves
        #expect(groups.count == 2)
        #expect(groups[0].key == "2026-04-06")
        #expect(groups[0].title == "Week of 2026-04-06")
        #expect(groups[1].key == "2026-03-30")
        #expect(groups[1].saves.count == 2)
    }

    @Test("groupedSaves groups by month with month-name titles")
    func groupedByMonth() async {
        let mock = makeMock()
        mock.stubbedSaves = [
            makeSave(id: 1, weekStart: "2026-03-30"),
            makeSave(id: 2, weekStart: "2026-04-06"),
            makeSave(id: 3, weekStart: "2026-04-13"),
        ]
        let vm = EditLogViewModel(service: mock)
        await vm.loadSaves()
        vm.grouping = .month

        let groups = vm.groupedSaves
        #expect(groups.count == 2)
        #expect(groups[0].key == "2026-04")
        #expect(groups[0].title == "April 2026")
        #expect(groups[0].saves.count == 2)
        #expect(groups[1].key == "2026-03")
        #expect(groups[1].title == "March 2026")
    }

    @Test("groupedSaves groups by year")
    func groupedByYear() async {
        let mock = makeMock()
        mock.stubbedSaves = [
            makeSave(id: 1, weekStart: "2025-12-29"),
            makeSave(id: 2, weekStart: "2026-04-06"),
        ]
        let vm = EditLogViewModel(service: mock)
        await vm.loadSaves()
        vm.grouping = .year

        let groups = vm.groupedSaves
        #expect(groups.count == 2)
        #expect(groups[0].key == "2026")
        #expect(groups[0].title == "2026")
        #expect(groups[1].key == "2025")
    }

    // MARK: - Expand/Collapse

    @Test("toggleExpanded expands and collapses")
    func toggleExpandedWorks() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave()]
        mock.stubbedDetailedDiffResult = []
        let vm = EditLogViewModel(service: mock)
        await vm.loadSaves()

        await vm.toggleExpanded(saveId: 1)
        #expect(vm.expandedSaveId == 1)

        await vm.toggleExpanded(saveId: 1)
        #expect(vm.expandedSaveId == nil)
    }

    // MARK: - Validation

    @Test("validate accepts a clean tag and returns trimmed value")
    func validateAcceptsCleanTag() {
        let result = EditLogViewModel.validate("  morning  ", existing: [])
        #expect(result == .valid("morning"))
    }

    @Test("validate rejects empty and whitespace-only input")
    func validateRejectsEmpty() {
        #expect(EditLogViewModel.validate("", existing: []) == .empty)
        #expect(EditLogViewModel.validate("   ", existing: []) == .empty)
    }

    @Test("validate rejects tags over 15 chars")
    func validateRejectsTooLong() {
        let over = String(repeating: "a", count: 16)
        #expect(EditLogViewModel.validate(over, existing: []) == .tooLong)
    }

    @Test("validate rejects semicolon")
    func validateRejectsSemicolon() {
        #expect(EditLogViewModel.validate("a;b", existing: []) == .hasSemicolon)
    }

    @Test("validate rejects case-insensitive duplicate")
    func validateRejectsDuplicate() {
        #expect(EditLogViewModel.validate("Morning", existing: ["morning"]) == .duplicate)
    }

    @Test("validate blocks new tags once the max is reached")
    func validateMaxReached() {
        let existing = ["a", "b", "c"]
        #expect(EditLogViewModel.validate("d", existing: existing) == .maxReached)
    }

    // MARK: - Add tag

    @Test("addTag appends trimmed value and returns true on success")
    func addTagAppendsAndReturnsTrue() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave()]
        let vm = EditLogViewModel(service: mock)
        await vm.loadSaves()

        let ok = await vm.addTag(saveId: 1, tag: "  busy  ")

        #expect(ok == true)
        #expect(vm.saves[0].tags == ["busy"])
        #expect(mock.callLog.contains("addSaveTag:1:busy"))
    }

    @Test("addTag returns false and surfaces error when service throws")
    func addTagSurfacesServiceError() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave(tags: ["a", "b", "c"])]
        mock.stubbedTags = [1: ["a", "b", "c"]]
        let vm = EditLogViewModel(service: mock)
        await vm.loadSaves()

        let ok = await vm.addTag(saveId: 1, tag: "d")

        #expect(ok == false)
        #expect(vm.saves[0].tags == ["a", "b", "c"])
        #expect(vm.error != nil)
    }

    @Test("addTag skips empty input without calling service")
    func addTagSkipsEmpty() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave()]
        let vm = EditLogViewModel(service: mock)
        await vm.loadSaves()

        let ok = await vm.addTag(saveId: 1, tag: "   ")

        #expect(ok == false)
        #expect(mock.callLog.filter { $0.hasPrefix("addSaveTag") }.isEmpty)
    }

    // MARK: - Remove tag

    @Test("removeTag drops matching tag case-insensitively")
    func removeTagDropsTag() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave(tags: ["Morning", "Busy"])]
        let vm = EditLogViewModel(service: mock)
        await vm.loadSaves()

        await vm.removeTag(saveId: 1, tag: "morning")

        #expect(vm.saves[0].tags == ["Busy"])
        #expect(mock.callLog.contains("removeSaveTag:1:morning"))
    }

    // MARK: - Restore

    @Test("restoreToSave sets toast on success")
    func restoreToSaveSetsToast() async {
        let mock = makeMock()
        mock.stubbedRestoreResult = FfiRestoreResult(
            rotaId: 1, shiftsRestored: 5, assignmentsRestored: 3, assignmentsSkipped: 1
        )
        let vm = EditLogViewModel(service: mock)

        await vm.restoreToSave(id: 1, summary: "test save", weekStart: "2026-03-30")

        #expect(vm.restoreToast != nil)
        #expect(vm.restoreToast?.shiftsRestored == 5)
        #expect(vm.restoreToast?.assignmentsSkipped == 1)
    }

    @Test("restoreToSave surfaces error")
    func restoreToSaveSurfacesError() async {
        let mock = makeMock()
        mock.errorToThrow = FfiError.NotFound(code: .notFoundGeneric, msg: "save missing")
        let vm = EditLogViewModel(service: mock)

        await vm.restoreToSave(id: 999, summary: "x", weekStart: "2026-03-30")

        #expect(vm.error == "The requested item could not be found.")
        #expect(vm.restoreToast == nil)
    }
}
