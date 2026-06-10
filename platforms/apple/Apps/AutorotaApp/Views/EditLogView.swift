import SwiftUI
import AutorotaKit
import TipKit

struct EditLogView: View {
    @State private var vm = EditLogViewModel()
    @State private var expandedGroups: Set<String> = [currentWeekStart()]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isMenuPushed) private var isMenuPushed

    var body: some View {
        @Bindable var vm = vm
        return OptionalNavigationStack(embed: !isMenuPushed) {
            ZStack(alignment: .top) {
                Group {
                    if vm.isLoading && vm.saves.isEmpty {
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let err = vm.error, vm.saves.isEmpty {
                        ContentUnavailableView(
                            "Couldn't load edits",
                            systemImage: "exclamationmark.triangle",
                            description: Text(err)
                        )
                    } else if vm.saves.isEmpty {
                        ContentUnavailableView(
                            "No edits yet",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Saves will appear here as you edit schedules.")
                        )
                    } else {
                        VStack(spacing: 0) {
                            Picker("Group by", selection: $vm.grouping) {
                                ForEach(EditLogViewModel.LogGrouping.allCases) { g in
                                    Text(g.label).tag(g)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                            .padding(.top, 8)
                            savesList
                        }
                        .onChange(of: vm.grouping) {
                            expandedGroups = defaultExpandedGroups()
                        }
                    }
                }

                if let toast = vm.restoreToast {
                    RestoreToastBanner(toast: toast)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            Task {
                                try? await Task.sleep(for: .seconds(4))
                                if reduceMotion {
                                    vm.restoreToast = nil
                                } else {
                                    withAnimation { vm.restoreToast = nil }
                                }
                            }
                        }
                }
            }
            .navigationTitle("Edit Log")
            .task { await vm.loadSaves() }
            .onTapGesture { dismissKeyboard() }
        }
    }

    private var savesList: some View {
        List {
            ForEach(vm.groupedSaves) { group in
                DisclosureGroup(isExpanded: groupBinding(group.key)) {
                    ForEach(group.saves, id: \.id) { save in
                        SaveEntryView(save: save, vm: vm)
                    }
                } label: {
                    HStack {
                        Text(group.title)
                            .font(.headline)
                        // Edit count only at week granularity (per design).
                        if vm.grouping == .week {
                            Spacer()
                            Text("\(group.saves.count) edit\(group.saves.count == 1 ? "" : "s")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await vm.loadSaves() }
    }

    /// Default expansion: open the group containing the current week.
    private func defaultExpandedGroups() -> Set<String> {
        [EditLogViewModel.groupKey(for: currentWeekStart(), grouping: vm.grouping)]
    }

    private func groupBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(key) },
            set: { isOn in
                if isOn { expandedGroups.insert(key) } else { expandedGroups.remove(key) }
            }
        )
    }
}

private func dismissKeyboard() {
    #if os(iOS)
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
    #elseif os(macOS)
    NSApp.keyWindow?.makeFirstResponder(nil)
    #endif
}

// MARK: - Save Entry

private struct SaveEntryView: View {
    let save: FfiSave
    let vm: EditLogViewModel
    @State private var tagInput: String = ""
    @FocusState private var tagFieldFocused: Bool
    @State private var showRestoreConfirmation = false
    @State private var showTagInput = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let restoreTip = EditLogRestoreTip()

    private var isExpanded: Bool { vm.expandedSaveId == save.id }

    private var validation: EditLogViewModel.TagValidation {
        EditLogViewModel.validate(tagInput, existing: save.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                tagFieldFocused = false
                showTagInput = false
                Task { await vm.toggleExpanded(saveId: save.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(formattedDate(save.savedAt))
                                .font(.subheadline.bold())
                            if save.restoredAt != nil {
                                SystemBadge(text: "Restored", color: .green)
                            }
                            if !save.tags.isEmpty {
                                TagChipRow(
                                    tags: save.tags,
                                    onDelete: nil
                                )
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                TipView(restoreTip)

                HStack(spacing: 8) {
                    restoreButton
                        .frame(maxWidth: .infinity)
                    tagInputArea
                        .frame(maxWidth: .infinity)
                }

                if !save.tags.isEmpty {
                    TagChipRow(tags: save.tags) { tag in
                        Task { await vm.removeTag(saveId: save.id, tag: tag) }
                    }
                }

                if let changes = vm.changesBySaveId[save.id] {
                    if changes.isEmpty {
                        Text("No changes from previous save")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ChangeSummaryCard(changes: changes)
                        DayChangesGroup(changes: changes)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.vertical, 4)
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

    private func formattedDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return relative.localizedString(for: date, relativeTo: Date())
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

// MARK: - System Badge

/// Read-only capsule used for system-controlled labels ("Current", "Restored").
/// Differs from `TagChip` in that it carries a color tint and never shows a
/// delete button — the user can't remove these.
private struct SystemBadge: View {
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

private struct TagChipRow: View {
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

private struct TagChip: View {
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

// MARK: - Change Summary Card

private struct ChangeSummaryCard: View {
    let changes: [FfiChangeDetail]

    var body: some View {
        let counts = changeCounts(changes)
        HStack(spacing: 12) {
            ForEach(counts, id: \.label) { item in
                HStack(spacing: 4) {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color)
                    Text("\(item.count)")
                        .font(.caption.bold())
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        var added = 0, removed = 0, modified = 0, moved = 0
        for c in changes {
            switch c.kind {
            case "shift_added", "assignment_added": added += 1
            case "shift_removed", "assignment_removed": removed += 1
            case "employee_moved": moved += 1
            default: modified += 1
            }
        }
        var items: [CountItem] = []
        if added > 0 { items.append(CountItem(label: "added", count: added, icon: "plus.circle.fill", color: .green)) }
        if removed > 0 { items.append(CountItem(label: "removed", count: removed, icon: "minus.circle.fill", color: .red)) }
        if modified > 0 { items.append(CountItem(label: "changed", count: modified, icon: "pencil.circle.fill", color: .orange)) }
        if moved > 0 { items.append(CountItem(label: "moved", count: moved, icon: "arrow.right.circle.fill", color: .purple)) }
        return items
    }
}

// MARK: - Day Changes Group

private struct DayChangesGroup: View {
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

private struct ChangeRow: View {
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

    private enum ChangeCategory { case added, removed, modified, moved }

    private var category: ChangeCategory {
        switch change.kind {
        case "shift_added", "assignment_added": return .added
        case "shift_removed", "assignment_removed": return .removed
        case "employee_moved": return .moved
        default: return .modified
        }
    }

    private var color: Color {
        switch category {
        case .added: return .green
        case .removed: return .red
        case .modified: return .orange
        case .moved: return .purple
        }
    }

    private var icon: String {
        switch category {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .moved: return "arrow.right.circle.fill"
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
            return "\(change.employeeName ?? "Unknown") joined"
        case "assignment_removed":
            return "\(change.employeeName ?? "Unknown") removed"
        case "assignment_status_changed":
            return "\(change.employeeName ?? "Unknown"): \(change.oldStatus ?? "?") → \(change.newStatus ?? "?")"
        case "employee_moved":
            return "\(change.employeeName ?? "Unknown") moved from \(change.fromStartTime ?? "") – \(change.fromEndTime ?? "")"
        default:
            return change.kind
        }
    }
}

// MARK: - Restore Toast Banner

private struct RestoreToastBanner: View {
    let toast: RestoreToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.body.bold())
            VStack(alignment: .leading, spacing: 1) {
                Text("Schedule restored")
                    .font(.subheadline.weight(.semibold))
                Text("Week of \(toast.weekStart)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.top, 8)
    }
}
