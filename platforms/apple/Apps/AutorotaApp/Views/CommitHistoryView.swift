import SwiftUI
import AutorotaKit

struct CommitHistoryView: View {

    @State private var vm = CommitHistoryViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView("Loading history…")
                } else if let error = vm.error, vm.commits.isEmpty {
                    ContentUnavailableView {
                        Label("Unable to Load History", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            vm.error = nil
                            Task {
                                await vm.loadCommits()
                                await vm.loadAllSnapshotsIfNeeded()
                                await vm.refreshChangedShiftsForAllWeeks()
                            }
                        }
                    }
                } else if vm.commits.isEmpty {
                    ContentUnavailableView(
                        "No Commits",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Committed shift snapshots will appear here.")
                    )
                } else {
                    VStack(spacing: 0) {
                        if let error = vm.error {
                            ErrorBanner(message: error) { vm.error = nil }
                        }
                        Picker("Mode", selection: $vm.mode) {
                            ForEach(HistoryMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        commitList
                    }
                }
            }
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                await vm.loadCommits()
                await vm.loadAllSnapshotsIfNeeded()
                await vm.refreshChangedShiftsForAllWeeks()
            }
            .refreshable {
                await vm.loadCommits()
                await vm.loadAllSnapshotsIfNeeded()
                await vm.refreshChangedShiftsForAllWeeks()
            }
            .sheet(item: $vm.selectedCommitDetail) { detail in
                CommitDetailSheet(detail: detail, vm: vm)
            }
            .overlay(alignment: .top) {
                if let toast = vm.restoreToast {
                    RestoreToastBanner(toast: toast) { vm.restoreToast = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            withAnimation { vm.restoreToast = nil }
                        }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.restoreToast)
        }
    }

    @ViewBuilder
    private var commitList: some View {
        switch vm.mode {
        case .commits:
            List {
                ForEach(vm.commitsByWeek, id: \.weekStart) { group in
                    Section {
                        ForEach(group.commits, id: \.id) { commit in
                            CommitRow(commit: commit) {
                                Task { await vm.loadCommitDetail(id: commit.id) }
                            }
                        }
                    } header: {
                        Text("Week of \(group.weekStart)")
                    }
                }
            }
        case .shifts:
            List {
                ForEach(vm.latestShiftsByWeek, id: \.weekStart) { group in
                    let changedIds = vm.changedShiftIdsByWeek[group.weekStart] ?? []
                    DisclosureGroup {
                        let days = shiftsByDay(group.shifts)
                        if days.isEmpty {
                            Text("No shifts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(days, id: \.date) { day in
                                let entries = vm.flatEntries(for: day.shifts, changedIds: changedIds)
                                DisclosureGroup {
                                    ForEach(entries) { entry in
                                        FlatAssignmentRow(entry: entry)
                                    }
                                } label: {
                                    HStack {
                                        Text(formatShiftDate(day.date))
                                            .font(.subheadline.bold())
                                        Spacer()
                                        Text("\(day.shifts.count) shift\(day.shifts.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } label: {
                        Text("Week of \(group.weekStart)")
                            .font(.headline)
                    }
                }
            }
        }
    }

    private func shiftsByDay(_ shifts: [ShiftData]) -> [(date: String, shifts: [ShiftData])] {
        let grouped = Dictionary(grouping: shifts, by: \.date)
        return grouped
            .sorted { $0.key < $1.key }
            .map { (date: $0.key, shifts: $0.value.sorted { $0.startTime < $1.startTime }) }
    }
}

// MARK: - Commit row

private struct CommitRow: View {
    let commit: FfiCommit
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.summary)
                    .font(.subheadline.bold())
                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var formattedDate: String {
        // Try to parse the RFC3339 committed_at and display as relative
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFmt.date(from: commit.committedAt) {
            let relFmt = RelativeDateTimeFormatter()
            relFmt.unitsStyle = .abbreviated
            return relFmt.localizedString(for: date, relativeTo: Date())
        }
        // Fallback: try without fractional seconds
        isoFmt.formatOptions = [.withInternetDateTime]
        if let date = isoFmt.date(from: commit.committedAt) {
            let relFmt = RelativeDateTimeFormatter()
            relFmt.unitsStyle = .abbreviated
            return relFmt.localizedString(for: date, relativeTo: Date())
        }
        return commit.committedAt
    }
}

// MARK: - Commit detail sheet

private struct CommitDetailSheet: View {
    let detail: FfiCommitDetail
    let vm: CommitHistoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showWages = false
    @State private var showRestoreAlert = false

    private var changes: [FfiCommitChangeDetail] {
        vm.changesByCommitId[detail.id] ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    Text(detail.summary)
                        .font(.subheadline.bold())
                    Text("Week of \(detail.weekStart)")
                        .foregroundStyle(.secondary)
                    Text(detail.committedAt)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                changesSection

                if let snapshot {
                    Section("Overview") {
                        LabeledContent("Total hours", value: fmtHoursD(snapshot.totalHours))
                        LabeledContent("Total shifts", value: "\(snapshot.totalShifts)")
                        LabeledContent("Unique employees", value: "\(snapshot.uniqueEmployees)")
                        Toggle("Show wages", isOn: $showWages)
                    }

                    Section("Shifts") {
                        ForEach(snapshot.shifts) { shift in
                            ShiftDisclosureRow(shift: shift, showWages: showWages)
                        }
                    }
                } else {
                    Section("Snapshot") {
                        Text(prettyJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showRestoreAlert = true
                    } label: {
                        HStack {
                            Label("Restore this version", systemImage: "arrow.counterclockwise")
                            if vm.isRestoring {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(vm.isRestoring)
                } footer: {
                    Text("Overwrites all shifts and assignments for the week of \(detail.weekStart) with the state captured by this commit.")
                }
            }
            .navigationTitle("Commit Detail")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await vm.loadChangesForCommit(id: detail.id) }
            .alert("Restore this version?", isPresented: $showRestoreAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Restore", role: .destructive) {
                    Task {
                        await vm.restoreToCommit(
                            id: detail.id,
                            summary: detail.summary,
                            weekStart: detail.weekStart
                        )
                        if vm.restoreToast != nil {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This replaces the current shifts and assignments for the week of \(detail.weekStart) with the state captured by this commit. Current changes made since this commit will be lost.")
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 400, idealHeight: 600)
        #endif
    }

    @ViewBuilder
    private var changesSection: some View {
        Section("Changes from previous commit") {
            if changes.isEmpty {
                Text("Nothing changed compared to the previous commit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ChangeSummaryCard(changes: changes)
                let days = groupChangesByDay(changes)
                ForEach(days, id: \.date) { day in
                    DayChangesGroup(date: day.date, changes: day.changes)
                }
            }
        }
    }

    private var snapshot: SnapshotData? {
        guard let data = detail.snapshotJson.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SnapshotData.self, from: data)
    }

    private var prettyJSON: String {
        guard let data = detail.snapshotJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return detail.snapshotJson
        }
        return str
    }
}

// MARK: - Flat assignment row (Shifts mode)

private struct FlatAssignmentRow: View {
    let entry: FlatAssignmentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let name = entry.employeeName {
                    Text(name)
                        .font(.subheadline.bold())
                } else {
                    Text("Unassigned")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.isChanged {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.orange)
                }
            }
            Text("\(entry.startTime)\u{2013}\(entry.endTime)  \(entry.requiredRole.isEmpty ? "Any Role" : entry.requiredRole)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shift disclosure row (Commit detail sheet)

private struct ShiftDisclosureRow: View {
    let shift: ShiftData
    let showWages: Bool
    var isChanged: Bool = false

    var body: some View {
        DisclosureGroup {
            ForEach(shift.assignments) { assignment in
                AssignmentRow(assignment: assignment, showWages: showWages)
            }
            if shift.assignments.isEmpty {
                Text("No assignments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatShiftDate(shift.date))
                        .font(.subheadline.bold())
                    Text("\(shift.startTime)\u{2013}\(shift.endTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(shift.requiredRole.isEmpty ? "Any Role" : shift.requiredRole)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary)
                    .clipShape(Capsule())
                if isChanged {
                    Text("Changed")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                if shift.maxEmployees > 1 {
                    Text("\(shift.assignments.count)/\(shift.maxEmployees)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Assignment row

private struct AssignmentRow: View {
    let assignment: AssignmentData
    let showWages: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(assignment.employeeName)
                .font(.subheadline)
            Text(assignment.status)
                .font(.caption.bold())
                .foregroundStyle(statusColor)
            Spacer()
            if showWages, let wage = assignment.hourlyWage {
                Text("\(currencySymbol)\(String(format: "%.2f", wage))/hr")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch assignment.status.lowercased() {
        case "confirmed": return .green
        case "proposed": return .orange
        case "overridden": return .blue
        default: return .gray
        }
    }

    private var currencySymbol: String {
        (AppCurrency(rawValue: assignment.wageCurrency ?? "usd") ?? .usd).symbol
    }
}

// MARK: - Formatting helpers

private func formatShiftDate(_ dateString: String) -> String {
    let inFmt = DateFormatter()
    inFmt.dateFormat = "yyyy-MM-dd"
    inFmt.locale = Locale(identifier: "en_US_POSIX")
    guard let date = inFmt.date(from: dateString) else { return dateString }
    let outFmt = DateFormatter()
    outFmt.dateFormat = "EEE d MMM"
    return outFmt.string(from: date)
}

private func fmtHoursD(_ v: Double) -> String {
    v.truncatingRemainder(dividingBy: 1) == 0
        ? "\(Int(v))h"
        : String(format: "%.1fh", v)
}

// MARK: - Error banner

/// A dismissible inline banner for non-critical errors, shown above content instead of as a modal alert.
struct ErrorBanner: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - Change viewer

/// Semantic category used for icon + color in the diff viewer. Keeps rendering
/// decoupled from the raw `kind` strings in the FFI payload.
private enum ChangeCategory {
    case added, removed, modified, newShift, moved

    var color: Color {
        switch self {
        case .added: return .green
        case .removed: return .red
        case .modified: return .orange
        case .newShift: return .blue
        case .moved: return .purple
        }
    }

    var systemImage: String {
        switch self {
        case .added: return "person.badge.plus"
        case .removed: return "person.badge.minus"
        case .modified: return "pencil.circle"
        case .newShift: return "plus.square.on.square"
        case .moved: return "arrow.triangle.swap"
        }
    }
}

private func category(for change: FfiCommitChangeDetail) -> ChangeCategory {
    switch change.kind {
    case "shift_added": return .newShift
    case "shift_removed": return .removed
    case "shift_time_changed", "shift_capacity_changed", "shift_role_changed",
         "assignment_status_changed":
        return .modified
    case "assignment_added": return .added
    case "assignment_removed": return .removed
    case "employee_moved": return .moved
    default: return .modified
    }
}

/// Plain-English summary for a single change, suitable for display.
private func summary(for c: FfiCommitChangeDetail) -> String {
    switch c.kind {
    case "shift_added":
        let t = formatTimeRange(c.newStartTime, c.newEndTime)
        let role = (c.newRequiredRole?.isEmpty == false) ? " \(c.newRequiredRole!)" : ""
        return "New shift\(role.isEmpty ? "" : "") \(t)".trimmingCharacters(in: .whitespaces)
    case "shift_removed":
        let t = formatTimeRange(c.oldStartTime, c.oldEndTime)
        return "Shift removed \(t)".trimmingCharacters(in: .whitespaces)
    case "shift_time_changed":
        let old = formatTimeRange(c.oldStartTime, c.oldEndTime)
        let new = formatTimeRange(c.newStartTime, c.newEndTime)
        return "Time changed  \(old) → \(new)"
    case "shift_capacity_changed":
        let oldMin = c.oldMinEmployees.map { "\($0)" } ?? "?"
        let newMin = c.newMinEmployees.map { "\($0)" } ?? "?"
        let oldMax = c.oldMaxEmployees.map { "\($0)" } ?? "?"
        let newMax = c.newMaxEmployees.map { "\($0)" } ?? "?"
        return "Staffing changed  \(oldMin)–\(oldMax) → \(newMin)–\(newMax)"
    case "shift_role_changed":
        let old = c.oldRequiredRole?.isEmpty == false ? c.oldRequiredRole! : "Any Role"
        let new = c.newRequiredRole?.isEmpty == false ? c.newRequiredRole! : "Any Role"
        return "Role changed  \(old) → \(new)"
    case "assignment_added":
        return "\(c.employeeName ?? "Someone") joined"
    case "assignment_removed":
        return "\(c.employeeName ?? "Someone") left"
    case "assignment_status_changed":
        let old = c.oldStatus ?? "?"
        let new = c.newStatus ?? "?"
        return "\(c.employeeName ?? "Someone"): \(old) → \(new)"
    case "employee_moved":
        let from = formatTimeRange(c.fromStartTime, c.fromEndTime)
        return "\(c.employeeName ?? "Someone") moved from \(from)"
    default:
        return c.kind
    }
}

private func formatTimeRange(_ start: String?, _ end: String?) -> String {
    switch (start, end) {
    case let (s?, e?): return "\(s) – \(e)"
    case let (s?, nil): return s
    case let (nil, e?): return e
    case (nil, nil): return ""
    }
}

/// Count summary shown at the top of the Changes section.
private struct ChangeSummaryCard: View {
    let changes: [FfiCommitChangeDetail]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(tallies, id: \.label) { item in
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.caption)
                        Text("\(item.count)")
                            .font(.headline.monospacedDigit())
                    }
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(item.color)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    private var tallies: [(label: String, count: Int, icon: String, color: Color)] {
        var added = 0, removed = 0, modified = 0, newShifts = 0, moved = 0
        for c in changes {
            switch category(for: c) {
            case .added: added += 1
            case .removed: removed += 1
            case .modified: modified += 1
            case .newShift: newShifts += 1
            case .moved: moved += 1
            }
        }
        var out: [(String, Int, String, Color)] = []
        if newShifts > 0 { out.append(("new", newShifts, ChangeCategory.newShift.systemImage, ChangeCategory.newShift.color)) }
        if added > 0 { out.append(("joined", added, ChangeCategory.added.systemImage, ChangeCategory.added.color)) }
        if removed > 0 { out.append(("left", removed, ChangeCategory.removed.systemImage, ChangeCategory.removed.color)) }
        if modified > 0 { out.append(("changed", modified, ChangeCategory.modified.systemImage, ChangeCategory.modified.color)) }
        if moved > 0 { out.append(("moved", moved, ChangeCategory.moved.systemImage, ChangeCategory.moved.color)) }
        return out
    }
}

/// Changes for a single day, shown as a compact list inside a header.
private struct DayChangesGroup: View {
    let date: String
    let changes: [FfiCommitChangeDetail]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(formatShiftDate(date))
                .font(.subheadline.bold())
                .padding(.top, 2)
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                ChangeRow(change: change)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ChangeRow: View {
    let change: FfiCommitChangeDetail

    var body: some View {
        let cat = category(for: change)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: cat.systemImage)
                .foregroundStyle(cat.color)
                .frame(width: 20)
            Text(summary(for: change))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(cat.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Group changes by date for display.
private func groupChangesByDay(
    _ changes: [FfiCommitChangeDetail]
) -> [(date: String, changes: [FfiCommitChangeDetail])] {
    let grouped = Dictionary(grouping: changes, by: \.date)
    return grouped
        .sorted { $0.key < $1.key }
        .map { (date: $0.key, changes: $0.value) }
}

// MARK: - Restore toast banner

private struct RestoreToastBanner: View {
    let toast: RestoreToast
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restored week of \(toast.weekStart)")
                    .font(.subheadline.bold())
                let parts = [
                    "\(toast.shiftsRestored) shift\(toast.shiftsRestored == 1 ? "" : "s")",
                    "\(toast.assignmentsRestored) assignment\(toast.assignmentsRestored == 1 ? "" : "s")",
                ]
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if toast.assignmentsSkipped > 0 {
                    Text("\(toast.assignmentsSkipped) assignment\(toast.assignmentsSkipped == 1 ? "" : "s") skipped — employee no longer exists")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.thinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        )
        .padding(.horizontal)
        .padding(.top, 12)
    }
}

// MARK: - Identifiable conformance for sheet binding

extension FfiCommitDetail: @retroactive Identifiable {}
