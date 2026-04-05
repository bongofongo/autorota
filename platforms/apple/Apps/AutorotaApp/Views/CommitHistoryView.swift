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
                    commitList
                }
            }
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await vm.loadCommits() }
            .refreshable { await vm.loadCommits() }
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

    private var commitList: some View {
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

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    Text(detail.summary)
                    Text("Week of \(detail.weekStart)")
                        .foregroundStyle(.secondary)
                    Text(detail.committedAt)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Snapshot") {
                    Text(prettyJSON)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
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

// MARK: - Identifiable conformance for sheet binding

extension FfiCommitDetail: @retroactive Identifiable {}
