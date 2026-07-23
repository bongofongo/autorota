import SwiftUI
import AutorotaKit

// Shared building blocks for the Edit Log list (`EditLogView`) and the
// per-save detail page (`EditLogSaveDetailView`).

// MARK: - Save source

extension FfiSave {
    /// Typed view of the FFI `source` string. Unknown values read as `.manual`.
    var sourceKind: SaveSource { SaveSource(rawValue: source) ?? .manual }
}

/// System badge for scheduler-generated saves. Renders nothing for `.manual`
/// (the common case needs no label). Uses the save's `source` field, so it
/// never competes with user tags and can't be removed.
struct SaveSourceBadge: View {
    let source: SaveSource

    var body: some View {
        switch source {
        case .generation:
            SystemBadge(text: String(localized: "Generation"), color: .blue)
        case .regeneration:
            SystemBadge(text: String(localized: "Regeneration"), color: .indigo)
        case .restore:
            SystemBadge(text: String(localized: "Checkpoint"), color: .gray)
        case .manual:
            EmptyView()
        }
    }
}

// MARK: - System Badge

/// Read-only capsule used for system-controlled labels ("Current", "Restored").
/// Differs from `TagChip` in that it carries a color tint and never shows a
/// delete button — the user can't remove these.
struct SystemBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Tag Chip

struct TagChipRow: View {
    let tags: [String]
    /// When non-nil, each chip shows an inline `×` delete button.
    let onDelete: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag, onDelete: onDelete.map { cb in { cb(tag) } })
            }
        }
    }
}

struct TagChip: View {
    let tag: String
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.caption.bold())
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.15))
        .foregroundStyle(Color.accentColor)
        .clipShape(Capsule())
    }
}

// MARK: - Save Actions (Restore + Tag)

/// The Restore and Tag action pair for a save, including the restore
/// confirmation dialog and the tag-entry popover. Used by both the inline
/// expansion in `EditLogView` and the detail page.
struct SaveActionButtons: View {
    let save: FfiSave
    let vm: EditLogViewModel
    @State private var tagInput: String = ""
    @FocusState private var tagFieldFocused: Bool
    @State private var showRestoreConfirmation = false
    @State private var showTagInput = false

    private var validation: EditLogViewModel.TagValidation {
        EditLogViewModel.validate(tagInput, existing: save.tags)
    }

    var body: some View {
        HStack(spacing: 8) {
            restoreButton
                .frame(maxWidth: .infinity)
            tagInputArea
                .frame(maxWidth: .infinity)
        }
    }

    private var restoreButton: some View {
        Button {
            showRestoreConfirmation = true
        } label: {
            Label("Restore", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.orange)
        .disabled(vm.isRestoring)
        .confirmationDialog(
            "Restore schedule?",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                Task {
                    await vm.restoreToSave(
                        id: save.id,
                        summary: save.summary,
                        weekStart: save.weekStart
                    )
                }
            }
        } message: {
            Text("This will overwrite the current schedule for week of \(save.weekStart) with the state from this save. This cannot be undone.")
        }
    }

    private var tagInputArea: some View {
        let atMax = save.tags.count >= EditLogViewModel.tagMaxPerSave
        return Button {
            showTagInput = true
        } label: {
            Label("Tag", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(atMax ? .red : .green)
        .disabled(atMax)
        .popover(isPresented: $showTagInput) {
            tagPopoverContent
        }
    }

    private var tagPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add tag")
                .font(.subheadline.bold())
            TextField("Tag", text: $tagInput)
                .textFieldStyle(.roundedBorder)
                .focused($tagFieldFocused)
                .onSubmit { submitTag() }
                .onAppear { tagFieldFocused = true }
            if let hint = validation.hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    tagInput = ""
                    showTagInput = false
                }
                Button("Save") { submitTag() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isSaveEnabled)
            }
        }
        .padding()
        .frame(minWidth: 240)
        .presentationCompactAdaptation(.popover)
    }

    private var isSaveEnabled: Bool {
        if case .valid = validation { return true }
        return false
    }

    private func submitTag() {
        guard case .valid(let value) = validation else { return }
        Task {
            if await vm.addTag(saveId: save.id, tag: value) {
                tagInput = ""
                showTagInput = false
            }
        }
    }
}

// MARK: - Change Summary Card

struct ChangeSummaryCard: View {
    let changes: [FfiChangeDetail]
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// iPhone portrait (compact width) drops the text labels — icon + count
    /// only — because the full row doesn't fit.
    private var showsLabels: Bool {
        #if os(iOS)
        horizontalSizeClass != .compact
        #else
        true
        #endif
    }

    var body: some View {
        let counts = changeCounts(changes)
        HStack(spacing: 12) {
            ForEach(counts, id: \.label) { item in
                HStack(spacing: 4) {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color)
                    Text("\(item.count)")
                        .font(.caption.bold())
                    if showsLabels {
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.count) \(item.label)")
            }
        }
        .padding(.vertical, 4)
    }

    private struct CountItem {
        let label: String
        let count: Int
        let icon: String
        let color: Color
    }

    private func changeCounts(_ changes: [FfiChangeDetail]) -> [CountItem] {
        let t = DiffTotals(changes: changes)
        var items: [CountItem] = []
        if t.added > 0 { items.append(CountItem(label: "added", count: t.added, icon: "plus.circle.fill", color: .green)) }
        if t.removed > 0 { items.append(CountItem(label: "removed", count: t.removed, icon: "minus.circle.fill", color: .red)) }
        if t.changed > 0 { items.append(CountItem(label: "changed", count: t.changed, icon: "pencil.circle.fill", color: .orange)) }
        if t.moved > 0 { items.append(CountItem(label: "moved", count: t.moved, icon: "arrow.right.circle.fill", color: .purple)) }
        if t.swapped > 0 { items.append(CountItem(label: "swapped", count: t.swapped, icon: "arrow.left.arrow.right.circle.fill", color: .teal)) }
        return items
    }
}

// MARK: - Diff totals

/// Bucketed counts over a save's diff. A swap counts once, not as two moves.
struct DiffTotals {
    var added = 0
    var removed = 0
    var changed = 0
    var moved = 0
    var swapped = 0

    init(changes: [FfiChangeDetail]) {
        for c in changes {
            switch c.kind {
            case "shift_added", "assignment_added": added += 1
            case "shift_removed", "assignment_removed": removed += 1
            case "employee_moved": moved += 1
            case "employees_swapped": swapped += 1
            default: changed += 1
            }
        }
    }

    var isEmpty: Bool { added == 0 && removed == 0 && changed == 0 && moved == 0 && swapped == 0 }
}

/// Compact one-line diff summary for the detail header: "+3 / − 2 / ⇄ 2".
/// Shows only non-zero buckets, separated by " / "; move and swap use their
/// change-row icons.
struct DiffTotalsLine: View {
    let changes: [FfiChangeDetail]

    var body: some View {
        let t = DiffTotals(changes: changes)
        if t.isEmpty {
            Text("No changes")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(tokens(t).enumerated()), id: \.offset) { index, token in
                    if index > 0 {
                        Text("/")
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 2) {
                        if let icon = token.icon {
                            Image(systemName: icon)
                                .font(.caption)
                        }
                        Text(token.text)
                    }
                    .foregroundStyle(token.color)
                    .fontWeight(.semibold)
                    .accessibilityLabel(token.accessibility)
                }
            }
        }
    }

    private func tokens(_ t: DiffTotals) -> [(icon: String?, text: String, color: Color, accessibility: String)] {
        var out: [(String?, String, Color, String)] = []
        if t.added > 0 { out.append((nil, "+ \(t.added)", .green, "\(t.added) added")) }
        if t.removed > 0 { out.append((nil, "− \(t.removed)", .red, "\(t.removed) removed")) }
        if t.changed > 0 { out.append((nil, "~ \(t.changed)", .orange, "\(t.changed) changed")) }
        if t.moved > 0 { out.append(("arrow.right.circle.fill", "\(t.moved)", .purple, "\(t.moved) moved")) }
        if t.swapped > 0 { out.append(("arrow.left.arrow.right.circle.fill", "\(t.swapped)", .teal, "\(t.swapped) swapped")) }
        return out
    }
}

// MARK: - Day Changes Group

struct DayChangesGroup: View {
    let changes: [FfiChangeDetail]

    var body: some View {
        let grouped = Dictionary(grouping: changes, by: \.date)
        let sorted = grouped.sorted { $0.key < $1.key }
        ForEach(sorted, id: \.key) { date, dayChanges in
            VStack(alignment: .leading, spacing: 4) {
                Text(date)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(Array(dayChanges.enumerated()), id: \.offset) { _, change in
                    ChangeRow(change: change)
                }
            }
        }
    }
}

// MARK: - Change Row

struct ChangeRow: View {
    let change: FfiChangeDetail

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(summary)
                .font(.caption)
        }
        .padding(.vertical, 1)
    }

    private enum ChangeCategory { case added, removed, modified, moved, swapped }

    private var category: ChangeCategory {
        switch change.kind {
        case "shift_added", "assignment_added": return .added
        case "shift_removed", "assignment_removed": return .removed
        case "employee_moved": return .moved
        case "employees_swapped": return .swapped
        default: return .modified
        }
    }

    private var color: Color {
        switch category {
        case .added: return .green
        case .removed: return .red
        case .modified: return .orange
        case .moved: return .purple
        case .swapped: return .teal
        }
    }

    private var icon: String {
        switch category {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .moved: return "arrow.right.circle.fill"
        case .swapped: return "arrow.left.arrow.right.circle.fill"
        }
    }

    private var summary: String {
        switch change.kind {
        case "shift_added":
            return "New shift \(change.newStartTime ?? "") – \(change.newEndTime ?? "") (\(change.newRequiredRole ?? "any"))"
        case "shift_removed":
            return "Removed shift \(change.oldStartTime ?? "") – \(change.oldEndTime ?? "")"
        case "shift_time_changed":
            return "Time changed \(change.oldStartTime ?? "") – \(change.oldEndTime ?? "") → \(change.newStartTime ?? "") – \(change.newEndTime ?? "")"
        case "shift_capacity_changed":
            return "Capacity \(change.oldMinEmployees.map(String.init) ?? "?")–\(change.oldMaxEmployees.map(String.init) ?? "?") → \(change.newMinEmployees.map(String.init) ?? "?")–\(change.newMaxEmployees.map(String.init) ?? "?")"
        case "shift_role_changed":
            return "Role \(change.oldRequiredRole ?? "?") → \(change.newRequiredRole ?? "?")"
        case "assignment_added":
            return "\(change.employeeName ?? "Unknown") joined \(change.newStartTime ?? "") – \(change.newEndTime ?? "")"
        case "assignment_removed":
            return "\(change.employeeName ?? "Unknown") removed from \(change.oldStartTime ?? "") – \(change.oldEndTime ?? "")"
        case "assignment_status_changed":
            return "\(change.employeeName ?? "Unknown"): \(change.oldStatus ?? "?") → \(change.newStatus ?? "?") (\(change.newStartTime ?? "") – \(change.newEndTime ?? ""))"
        case "employee_moved":
            return "\(change.employeeName ?? "Unknown") moved \(change.fromStartTime ?? "") – \(change.fromEndTime ?? "") → \(change.newStartTime ?? "") – \(change.newEndTime ?? "")"
        case "employees_swapped":
            return "\(change.employeeName ?? "Unknown") (\(change.newStartTime ?? "") – \(change.newEndTime ?? "")) ⇄ \(change.otherEmployeeName ?? "Unknown") (\(change.fromStartTime ?? "") – \(change.fromEndTime ?? ""))"
        default:
            return change.kind
        }
    }
}
