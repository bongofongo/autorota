import Foundation
import Observation
import AutorotaKit

enum HistoryMode: String, CaseIterable, Identifiable {
    case shifts
    case commits
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shifts: return "Shifts"
        case .commits: return "Commits"
        }
    }
}

// MARK: - Snapshot decoding models (shared with CommitHistoryView)

struct SnapshotData: Codable {
    let weekStart: String
    let shifts: [ShiftData]
    let totalHours: Double
    let totalShifts: Int
    let uniqueEmployees: Int
}

struct ShiftData: Codable, Identifiable {
    let shiftId: Int64
    let date: String
    let startTime: String
    let endTime: String
    let requiredRole: String
    let minEmployees: Int
    let maxEmployees: Int
    let assignments: [AssignmentData]

    var id: Int64 { shiftId }
}

struct AssignmentData: Codable, Identifiable {
    let assignmentId: Int64
    let employeeId: Int64
    let employeeName: String
    let status: String
    let hourlyWage: Double?
    let wageCurrency: String?

    var id: Int64 { assignmentId }
}

// MARK: - Shift diff helper

/// Returns true if the live shift differs from the committed snapshot.
/// Compares core shift fields and the set of (employeeId, status) assignment pairs.
func shiftDiffersFromSnapshot(
    snapshot: ShiftData,
    liveShift: FfiShiftInfo,
    liveEntries: [FfiScheduleEntry]
) -> Bool {
    if snapshot.startTime != liveShift.startTime { return true }
    if snapshot.endTime != liveShift.endTime { return true }
    if snapshot.requiredRole != liveShift.requiredRole { return true }
    if snapshot.minEmployees != Int(liveShift.minEmployees) { return true }
    if snapshot.maxEmployees != Int(liveShift.maxEmployees) { return true }
    let snapPairs = Set(snapshot.assignments.map { "\($0.employeeId)|\($0.status.lowercased())" })
    let livePairs = Set(liveEntries.map { "\($0.employeeId)|\($0.status.lowercased())" })
    return snapPairs != livePairs
}

@Observable
final class CommitHistoryViewModel {
    var commits: [FfiCommit] = []
    var isLoading = false
    var error: String?
    var selectedCommitDetail: FfiCommitDetail?
    var mode: HistoryMode = .shifts

    /// Cache of decoded snapshots keyed by commit id.
    var snapshotsByCommitId: [Int64: SnapshotData] = [:]

    /// Shift IDs that have been modified since their latest commit, keyed by week_start.
    var changedShiftIdsByWeek: [String: Set<Int64>] = [:]

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

    /// Load detailed snapshot for a specific commit (used by the Commits-mode sheet).
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

    /// Eagerly fetch + decode every commit's snapshot so the Shifts view can aggregate.
    /// Tolerates per-commit failures.
    func loadAllSnapshotsIfNeeded() async {
        let missing = commits.filter { snapshotsByCommitId[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for commit in missing {
            do {
                guard let detail = try await service.getCommitDetail(commitId: commit.id) else { continue }
                guard let data = detail.snapshotJson.data(using: .utf8) else { continue }
                if let snap = try? decoder.decode(SnapshotData.self, from: data) {
                    snapshotsByCommitId[commit.id] = snap
                }
            } catch {
                // Skip this commit but continue.
                continue
            }
        }
    }

    /// For each week shown in Shifts mode, fetch the live schedule and diff against the latest snapshot.
    func refreshChangedShiftsForAllWeeks() async {
        var result: [String: Set<Int64>] = [:]
        for (weekStart, shifts) in latestShiftsByWeek {
            do {
                guard let live = try await service.getWeekSchedule(weekStart: weekStart) else { continue }
                var changed: Set<Int64> = []
                let snapshotById = Dictionary(uniqueKeysWithValues: shifts.map { ($0.shiftId, $0) })
                for liveShift in live.shifts {
                    guard let snap = snapshotById[liveShift.id] else { continue }
                    let entries = live.entries.filter { $0.shiftId == liveShift.id }
                    if shiftDiffersFromSnapshot(snapshot: snap, liveShift: liveShift, liveEntries: entries) {
                        changed.insert(liveShift.id)
                    }
                }
                result[weekStart] = changed
            } catch {
                continue
            }
        }
        changedShiftIdsByWeek = result
    }

    /// Commits grouped by week_start for display (Commits mode).
    var commitsByWeek: [(weekStart: String, commits: [FfiCommit])] {
        let grouped = Dictionary(grouping: commits, by: \.weekStart)
        return grouped
            .sorted { $0.key > $1.key }
            .map { (weekStart: $0.key, commits: $0.value) }
    }

    /// For each week, the most recently committed version of every shift, deduped by shift_id.
    var latestShiftsByWeek: [(weekStart: String, shifts: [ShiftData])] {
        let grouped = Dictionary(grouping: commits, by: \.weekStart)
        return grouped
            .sorted { $0.key > $1.key }
            .map { (weekStart, weekCommits) in
                let ordered = weekCommits.sorted { $0.committedAt > $1.committedAt }
                var latest: [Int64: ShiftData] = [:]
                for commit in ordered {
                    guard let snap = snapshotsByCommitId[commit.id] else { continue }
                    for shift in snap.shifts where latest[shift.shiftId] == nil {
                        latest[shift.shiftId] = shift
                    }
                }
                let shifts = latest.values.sorted { lhs, rhs in
                    if lhs.date != rhs.date { return lhs.date < rhs.date }
                    return lhs.startTime < rhs.startTime
                }
                return (weekStart: weekStart, shifts: shifts)
            }
    }
}
