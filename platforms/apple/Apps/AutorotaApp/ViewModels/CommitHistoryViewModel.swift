import Foundation
import Observation
import AutorotaKit

@Observable
final class CommitHistoryViewModel {
    var commits: [FfiCommit] = []
    var isLoading = false
    var error: String?
    var selectedCommitDetail: FfiCommitDetail?

    let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = LiveAutorotaService()) {
        self.service = service
    }

    /// Load all commits across all weeks, sorted by committed_at descending.
    func loadCommits() async {
        isLoading = true
        error = nil
        do {
            commits = try await service.listCommits(rotaId: nil)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Load detailed snapshot for a specific commit.
    func loadCommitDetail(id: Int64) async {
        do {
            selectedCommitDetail = try await service.getCommitDetail(commitId: id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearDetail() {
        selectedCommitDetail = nil
    }

    /// Commits grouped by week_start for display.
    var commitsByWeek: [(weekStart: String, commits: [FfiCommit])] {
        let grouped = Dictionary(grouping: commits, by: \.weekStart)
        return grouped
            .sorted { $0.key > $1.key }
            .map { (weekStart: $0.key, commits: $0.value) }
    }
}
