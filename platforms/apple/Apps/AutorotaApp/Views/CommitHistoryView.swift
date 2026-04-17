import SwiftUI
import AutorotaKit

struct ActivityLogView: View {
    @State private var vm = ActivityLogViewModel()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Group {
                    if vm.isLoading && vm.saves.isEmpty {
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.saves.isEmpty {
                        ContentUnavailableView(
                            "No activity yet",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Saves will appear here as you edit schedules.")
                        )
                    } else {
                        savesList
                    }
                }

                if let toast = vm.restoreToast {
                    RestoreToastBanner(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            Task {
                                try? await Task.sleep(for: .seconds(4))
                                withAnimation { vm.restoreToast = nil }
                            }
                        }
                }
            }
            .navigationTitle("Activity Log")
            .task { await vm.loadSaves() }
        }
    }

    private var savesList: some View {
        List {
            ForEach(vm.savesByWeek, id: \.weekStart) { weekGroup in
                Section("Week of \(weekGroup.weekStart)") {
                    ForEach(weekGroup.saves, id: \.id) { save in
                        SaveEntryView(save: save, vm: vm)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadSaves() }
    }
}

// MARK: - Save Entry

private struct SaveEntryView: View {
    let save: FfiSave
    let vm: ActivityLogViewModel
    @State private var labelText: String = ""
    @State private var showRestoreConfirmation = false

    private var isExpanded: Bool { vm.expandedSaveId == save.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await vm.toggleExpanded(saveId: save.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(formattedDate(save.savedAt))
                                .font(.subheadline.bold())
                            if let label = save.label {
                                Text(label)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundStyle(.accent)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(save.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

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

                HStack {
                    TextField("Add label…", text: $labelText)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                    if !labelText.isEmpty || save.label != nil {
                        Button("Save") {
                            Task { await vm.updateLabel(saveId: save.id, label: labelText) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .onAppear { labelText = save.label ?? "" }

                Button(role: .destructive) {
                    showRestoreConfirmation = true
                } label: {
                    Label("Restore to this point", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                            await vm.loadSaves()
                        }
                    }
                } message: {
                    Text("This will overwrite the current schedule for week of \(save.weekStart) with the state from this save. This cannot be undone.")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return relative.localizedString(for: date, relativeTo: Date())
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
        VStack(spacing: 4) {
            Label("Restored to: \(toast.saveSummary)", systemImage: "checkmark.circle.fill")
                .font(.subheadline.bold())
            Text("Week of \(toast.weekStart) — \(toast.shiftsRestored) shifts, \(toast.assignmentsRestored) assignments")
                .font(.caption)
            if toast.assignmentsSkipped > 0 {
                Text("\(toast.assignmentsSkipped) assignment(s) skipped (employees deleted)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
