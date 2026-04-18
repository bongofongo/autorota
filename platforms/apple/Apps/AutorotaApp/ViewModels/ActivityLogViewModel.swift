import Foundation
import Observation
import AutorotaKit

// MARK: - Restore toast

/// Ephemeral message shown after a successful restore.
struct RestoreToast: Equatable {
    let saveSummary: String
    let weekStart: String
    let shiftsRestored: Int
    let assignmentsRestored: Int
    let assignmentsSkipped: Int
}

@Observable
final class ActivityLogViewModel {
    var saves: [FfiSave] = []
    var isLoading = false
    var error: String?

    /// Changes for each save, keyed by save ID. Loaded on demand when expanded.
    var changesBySaveId: [Int64: [FfiChangeDetail]] = [:]

    /// Which save entry is currently expanded (nil = all collapsed).
    var expandedSaveId: Int64?

    /// Toast shown after a successful restore. Non-nil = visible.
    var restoreToast: RestoreToast?

    /// Whether a restore is currently in flight.
    var isRestoring = false

    let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = LiveAutorotaService()) {
        self.service = service
    }

    /// Load all saves across all weeks, sorted by saved_at descending.
    func loadSaves() async {
        isLoading = true
        error = nil
        do {
            saves = try await service.listSaves(rotaId: nil)
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
    }

    /// Toggle expansion of a save entry. Loads changes on first expand.
    func toggleExpanded(saveId: Int64) async {
        if expandedSaveId == saveId {
            expandedSaveId = nil
        } else {
            expandedSaveId = saveId
            await loadChangesForSave(id: saveId)
        }
    }

    /// Load detailed changes between this save and the previous save.
    func loadChangesForSave(id: Int64) async {
        guard changesBySaveId[id] == nil else { return }
        do {
            let changes = try await service.diffSaveVsPrevious(saveId: id)
            changesBySaveId[id] = changes
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    /// Update the label on a save.
    func updateLabel(saveId: Int64, label: String?) async {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            try await service.updateSaveLabel(saveId: saveId, label: finalLabel)
            // Update local cache
            if let idx = saves.firstIndex(where: { $0.id == saveId }) {
                saves[idx] = FfiSave(
                    id: saves[idx].id,
                    rotaId: saves[idx].rotaId,
                    savedAt: saves[idx].savedAt,
                    summary: saves[idx].summary,
                    label: finalLabel,
                    weekStart: saves[idx].weekStart
                )
            }
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    /// Restore the rota to the state captured by a save.
    func restoreToSave(id: Int64, summary: String, weekStart: String) async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            let result = try await service.restoreToSave(saveId: id)
            restoreToast = RestoreToast(
                saveSummary: summary,
                weekStart: weekStart,
                shiftsRestored: Int(result.shiftsRestored),
                assignmentsRestored: Int(result.assignmentsRestored),
                assignmentsSkipped: Int(result.assignmentsSkipped)
            )
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    /// Saves grouped by week_start for display.
    var savesByWeek: [(weekStart: String, saves: [FfiSave])] {
        let grouped = Dictionary(grouping: saves, by: \.weekStart)
        return grouped
            .sorted { $0.key > $1.key }
            .map { (weekStart: $0.key, saves: $0.value) }
    }
}
