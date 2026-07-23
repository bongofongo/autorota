import SwiftUI
import AutorotaKit

struct EditLogView: View {
    @State private var vm = EditLogViewModel()
    @State private var expandedGroups: Set<String> = [currentWeekStart()]
    /// Non-nil pushes the full-detail page via `navigationDestination(item:)`.
    /// A plain Button + destination binding instead of an inline
    /// `NavigationLink` — links nested among other buttons in a List row get
    /// unreliable hit areas (see IOS_BUGS.md #3 for the same tap-swallowing
    /// class of bug in the shift template sheet).
    @State private var detailSave: FfiSave?
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
            .onReceive(NotificationCenter.default.publisher(for: .autorotaDataChanged)) { note in
                if affectsSaves(note) {
                    Task { await vm.loadSaves() }
                }
            }
            // No top-level tap-to-dismiss-keyboard here: it swallows child
            // control taps (IOS_BUGS.md #3). The list already dismisses via
            // `.scrollDismissesKeyboard`, and tag entry lives in a popover.
            .navigationDestination(item: $detailSave) { save in
                EditLogSaveDetailView(save: save, vm: vm)
            }
        }
    }

    /// One inset-grouped Section per group — each renders as its own rounded
    /// island. Rows are only present while the group is expanded; the header
    /// is a button toggling that state.
    private var savesList: some View {
        List {
            ForEach(vm.groupedSaves) { group in
                Section {
                    if expandedGroups.contains(group.key) {
                        ForEach(group.saves, id: \.id) { save in
                            SaveEntryView(save: save, vm: vm, detailSave: $detailSave)
                        }
                    }
                } header: {
                    groupHeader(group)
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

    private func groupHeader(_ group: EditLogViewModel.SaveGroup) -> some View {
        let expanded = expandedGroups.contains(group.key)
        return Button {
            if reduceMotion {
                toggleGroup(group.key)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { toggleGroup(group.key) }
            }
        } label: {
            HStack {
                Text(group.title)
                    .font(.headline)
                Spacer()
                Text("\(group.saves.count) edit\(group.saves.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    private func toggleGroup(_ key: String) {
        if expandedGroups.contains(key) {
            expandedGroups.remove(key)
        } else {
            expandedGroups.insert(key)
        }
    }

    /// Reload only when a change touches saves (or rotas, whose week_start is
    /// denormalized into each entry). A `nil` payload is a legacy/full post —
    /// reload to be safe.
    private func affectsSaves(_ note: Notification) -> Bool {
        guard let change = note.autorotaDataChange else { return true }
        return change.tables.contains(.save) || change.tables.contains(.rota)
    }

    /// Default expansion: open the group containing the current week.
    private func defaultExpandedGroups() -> Set<String> {
        [EditLogViewModel.groupKey(for: currentWeekStart(), grouping: vm.grouping)]
    }
}

// MARK: - Save Entry

private struct SaveEntryView: View {
    let save: FfiSave
    let vm: EditLogViewModel
    @Binding var detailSave: FfiSave?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                            SaveSourceBadge(source: save.sourceKind)
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

                SaveActionButtons(save: save, vm: vm)

                if !save.tags.isEmpty {
                    TagChipRow(tags: save.tags) { tag in
                        Task { await vm.removeTag(saveId: save.id, tag: tag) }
                    }
                }

                // All entries render abbreviated inline: summary counts only.
                // Per-change rows live on the detail page.
                if let changes = vm.changesBySaveId[save.id] {
                    if changes.isEmpty {
                        Text("No changes from previous save")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ChangeSummaryCard(changes: changes)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }

                Button {
                    detailSave = save
                } label: {
                    HStack {
                        Label("View full details", systemImage: "doc.text.magnifyingglass")
                            .font(.footnote)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
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
        relative.unitsStyle = .full
        return relative.localizedString(for: date, relativeTo: Date())
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
