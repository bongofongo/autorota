import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("CommitHistoryViewModel")
struct CommitHistoryViewModelTests {

    private func makeMock() -> MockAutorotaService {
        MockAutorotaService()
    }

    private func makeCommit(id: Int64 = 1, rotaId: Int64 = 1, weekStart: String = "2026-03-30") -> FfiCommit {
        FfiCommit(
            id: id,
            rotaId: rotaId,
            committedAt: "2026-03-30T12:00:00Z",
            summary: "2 shifts committed",
            weekStart: weekStart
        )
    }

    // MARK: - Error display

    @Test("loadCommits surfaces clean error message from FfiError")
    func loadCommitsSurfacesCleanFfiError() async {
        let mock = makeMock()
        mock.errorToThrow = FfiError.Db(msg: "A referenced record no longer exists. It may have been deleted.")
        let vm = CommitHistoryViewModel(service: mock)

        await vm.loadCommits()

        #expect(vm.error != nil)
        // Should show the clean message, not the Swift enum wrapper
        #expect(vm.error == "A referenced record no longer exists. It may have been deleted.")
    }

    @Test("loadCommits surfaces clean error for non-FfiError")
    func loadCommitsSurfacesGenericError() async {
        let mock = makeMock()
        mock.errorToThrow = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something went wrong"])
        let vm = CommitHistoryViewModel(service: mock)

        await vm.loadCommits()

        #expect(vm.error != nil)
        #expect(vm.error == "Something went wrong")
    }

    @Test("loadCommitDetail surfaces clean error message")
    func loadCommitDetailSurfacesCleanError() async {
        let mock = makeMock()
        let vm = CommitHistoryViewModel(service: mock)

        // First call succeeds so commits load
        mock.stubbedCommits = [makeCommit()]
        await vm.loadCommits()
        #expect(vm.error == nil)

        // Now set error for detail call
        mock.errorToThrow = FfiError.NotFound(msg: "Commit not found")
        await vm.loadCommitDetail(id: 1)

        #expect(vm.error == "Commit not found")
    }

    // MARK: - Shift mode aggregation

    @Test("latestShiftsByWeek returns empty when no snapshots loaded")
    func latestShiftsByWeekEmptyWithoutSnapshots() async {
        let mock = makeMock()
        mock.stubbedCommits = [makeCommit()]
        let vm = CommitHistoryViewModel(service: mock)

        await vm.loadCommits()

        let weeks = vm.latestShiftsByWeek
        #expect(weeks.count == 1)
        #expect(weeks[0].shifts.isEmpty)
    }

    @Test("loadCommits with empty result shows no error")
    func loadCommitsEmptyNoError() async {
        let mock = makeMock()
        let vm = CommitHistoryViewModel(service: mock)

        await vm.loadCommits()

        #expect(vm.error == nil)
        #expect(vm.commits.isEmpty)
    }
}
