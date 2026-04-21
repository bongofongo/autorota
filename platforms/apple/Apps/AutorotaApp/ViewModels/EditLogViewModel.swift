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
final class EditLogViewModel {
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

    /// Max tags per save — mirrors the Rust constant.
    static let tagMaxPerSave = 3
    /// Max characters per tag — mirrors the Rust constant.
    static let tagMaxLen = 15

    /// Result of client-side tag validation. Mirrors the Rust `TagError` cases
    /// plus a `.valid` success carrying the trimmed value.
    enum TagValidation: Equatable {
        case valid(String)
        case empty
        case tooLong
        case hasSemicolon
        case duplicate
        case maxReached

        /// Short, user-facing hint. `nil` for `.valid` and `.empty` (so we
        /// don't yell at a blank field before the user has typed anything).
        var hint: String? {
            switch self {
            case .valid, .empty: return nil
            case .tooLong: return "Max \(EditLogViewModel.tagMaxLen) characters"
            case .hasSemicolon: return "No semicolons"
            case .duplicate: return "Tag already added"
            case .maxReached: return "Max \(EditLogViewModel.tagMaxPerSave) tags"
            }
        }
    }

    /// Validate a candidate tag against the per-tag rules and the current
    /// on-save set. Pure — callable from the View for disabled-state.
    static func validate(_ raw: String, existing: [String]) -> TagValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.count >= tagMaxPerSave { return .maxReached }
        if trimmed.isEmpty { return .empty }
        if trimmed.count > tagMaxLen { return .tooLong }
        if trimmed.contains(";") { return .hasSemicolon }
        let lower = trimmed.lowercased()
        if existing.contains(where: { $0.lowercased() == lower }) { return .duplicate }
        return .valid(trimmed)
    }

    /// Add a tag. Returns true on success so the caller can clear input.
    @discardableResult
    func addTag(saveId: Int64, tag: String) async -> Bool {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await service.addSaveTag(saveId: saveId, tag: trimmed)
            if let idx = saves.firstIndex(where: { $0.id == saveId }) {
                var tags = saves[idx].tags
                tags.append(trimmed)
                saves[idx] = replacingTags(on: saves[idx], with: tags)
            }
            return true
        } catch {
            self.error = userFacingMessage(error)
            return false
        }
    }

    /// Remove a tag by case-insensitive match.
    func removeTag(saveId: Int64, tag: String) async {
        do {
            try await service.removeSaveTag(saveId: saveId, tag: tag)
            if let idx = saves.firstIndex(where: { $0.id == saveId }) {
                let lower = tag.lowercased()
                let tags = saves[idx].tags.filter { $0.lowercased() != lower }
                saves[idx] = replacingTags(on: saves[idx], with: tags)
            }
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    private func replacingTags(on save: FfiSave, with tags: [String]) -> FfiSave {
        FfiSave(
            id: save.id,
            rotaId: save.rotaId,
            savedAt: save.savedAt,
            summary: save.summary,
            tags: tags,
            weekStart: save.weekStart,
            restoredAt: save.restoredAt
        )
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
            // Re-fetch so the restored entry picks up its new restored_at
            // timestamp and moves to the top of its week.
            await loadSaves()
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
