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

// MARK: - Restore toast

/// Ephemeral message shown after a successful restore. The view observes
/// `CommitHistoryViewModel.restoreToast` and auto-dismisses after a delay.
struct RestoreToast: Equatable {
    let commitSummary: String
    let weekStart: String
    let shiftsRestored: Int
    let assignmentsRestored: Int
    let assignmentsSkipped: Int
}

// MARK: - Flat assignment entry (for Shifts-mode flattened list)

struct FlatAssignmentEntry: Identifiable {
    let id: String
    let employeeName: String?
    let startTime: String
    let endTime: String
    let requiredRole: String
    let isChanged: Bool
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

    /// Detailed changes vs previous commit, keyed by commit id. Loaded on demand
    /// when a commit detail sheet opens.
    var changesByCommitId: [Int64: [FfiCommitChangeDetail]] = [:]

    /// Toast shown after a successful restore. Non-nil = visible.
    var restoreToast: RestoreToast?

    /// Whether a restore is currently in flight (drives UI spinner + disables button).
    var isRestoring = false

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
            self.error = userFacingMessage(error)
        }
        isLoading = false
    }

    /// Load detailed snapshot for a specific commit (used by the Commits-mode sheet).
    func loadCommitDetail(id: Int64) async {
        do {
            selectedCommitDetail = try await service.getCommitDetail(commitId: id)
        } catch {
            self.error = userFacingMessage(error)
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

    /// For each week shown in Shifts mode, use Rust-side diff to find changed shifts.
    func refreshChangedShiftsForAllWeeks() async {
        var result: [String: Set<Int64>] = [:]
        // Collect unique rota IDs per week
        for (weekStart, _) in latestShiftsByWeek {
            do {
                guard let live = try await service.getWeekSchedule(weekStart: weekStart) else { continue }
                let diffs = try await service.diffRota(rotaId: live.rotaId)
                let changed = Set(diffs.filter { $0.isNew || $0.isChanged }.map { $0.shiftId })
                result[weekStart] = changed
            } catch {
                continue
            }
        }
        changedShiftIdsByWeek = result
    }

    /// Flatten shifts for a given day into one row per assignment (or one "Unassigned" row).
    func flatEntries(for shifts: [ShiftData], changedIds: Set<Int64>) -> [FlatAssignmentEntry] {
        var entries: [FlatAssignmentEntry] = []
        for shift in shifts {
            let changed = changedIds.contains(shift.shiftId)
            if shift.assignments.isEmpty {
                entries.append(FlatAssignmentEntry(
                    id: "\(shift.shiftId)-unassigned",
                    employeeName: nil,
                    startTime: shift.startTime,
                    endTime: shift.endTime,
                    requiredRole: shift.requiredRole,
                    isChanged: changed
                ))
            } else {
                for assignment in shift.assignments {
                    entries.append(FlatAssignmentEntry(
                        id: "\(shift.shiftId)-\(assignment.assignmentId)",
                        employeeName: assignment.employeeName,
                        startTime: shift.startTime,
                        endTime: shift.endTime,
                        requiredRole: shift.requiredRole,
                        isChanged: changed
                    ))
                }
            }
        }
        return entries.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return ($0.employeeName ?? "~") < ($1.employeeName ?? "~")
        }
    }

    /// Commits grouped by week_start for display (Commits mode).
    var commitsByWeek: [(weekStart: String, commits: [FfiCommit])] {
        let grouped = Dictionary(grouping: commits, by: \.weekStart)
        return grouped
            .sorted { $0.key > $1.key }
            .map { (weekStart: $0.key, commits: $0.value) }
    }

    /// Load detailed changes between this commit and the previous commit
    /// for the same rota. Empty array if this is the first commit.
    func loadChangesForCommit(id: Int64) async {
        guard changesByCommitId[id] == nil else { return }
        do {
            let changes = try await service.diffCommitVsPrevious(commitId: id)
            changesByCommitId[id] = changes
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    /// Restore the rota to the state captured by a commit. On success, posts
    /// `.autorotaDataChanged` (done by the service) and surfaces a toast.
    func restoreToCommit(id: Int64, summary: String, weekStart: String) async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            let result = try await service.restoreToCommit(commitId: id)
            restoreToast = RestoreToast(
                commitSummary: summary,
                weekStart: weekStart,
                shiftsRestored: Int(result.shiftsRestored),
                assignmentsRestored: Int(result.assignmentsRestored),
                assignmentsSkipped: Int(result.assignmentsSkipped)
            )
            // After a restore the changed-shift caches are stale.
            changedShiftIdsByWeek.removeAll()
        } catch {
            self.error = userFacingMessage(error)
        }
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
