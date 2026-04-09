import SwiftUI
import AutorotaKit

struct CommitHistoryView: View {

    @State private var vm = CommitHistoryViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView("Loading history…")
                } else if vm.commits.isEmpty {
                    ContentUnavailableView(
                        "No Commits",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Committed shift snapshots will appear here.")
                    )
                } else {
                    VStack(spacing: 0) {
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
                CommitDetailSheet(detail: detail)
            }
            .alert("Error", isPresented: .constant(vm.error != nil)) {
                Button("OK") { vm.error = nil }
            } message: {
                Text(vm.error ?? "")
            }
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
    @Environment(\.dismiss) private var dismiss
    @State private var showWages = false

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
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 400, idealHeight: 600)
        #endif
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
            Text("\(entry.startTime)\u{2013}\(entry.endTime)  \(entry.requiredRole)")
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
                Text(shift.requiredRole)
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

// MARK: - Identifiable conformance for sheet binding

extension FfiCommitDetail: @retroactive Identifiable {}
