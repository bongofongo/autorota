import SwiftUI
import AutorotaKit

/// Full-detail page for a single save, pushed from the Edit Log list. Shows
/// complete metadata and the entire diff vs the previous save — including for
/// generation saves, whose inline rendering in the list is abbreviated.
struct EditLogSaveDetailView: View {
    let save: FfiSave
    let vm: EditLogViewModel

    /// Live copy from the ViewModel so tag edits made on this page (or
    /// elsewhere) are reflected; falls back to the pushed value.
    private var currentSave: FfiSave {
        vm.saves.first(where: { $0.id == save.id }) ?? save
    }

    var body: some View {
        List {
            metadataSection
            actionsSection
            changesSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Save Details")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await vm.loadChangesForSave(id: save.id) }
    }

    private var metadataSection: some View {
        Section("Details") {
            LabeledContent("Saved") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(absoluteDate(currentSave.savedAt))
                    Text(relativeDate(currentSave.savedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent(daysAffectedLabel) {
                if let changes = vm.changesBySaveId[save.id] {
                    Text(daysAffectedText(changes))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Summary") {
                if let changes = vm.changesBySaveId[save.id] {
                    DiffTotalsLine(changes: changes)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if currentSave.sourceKind != .manual {
                LabeledContent("Source") {
                    SaveSourceBadge(source: currentSave.sourceKind)
                }
            }
            if let restoredAt = currentSave.restoredAt {
                LabeledContent("Restored") {
                    HStack(spacing: 6) {
                        SystemBadge(text: "Restored", color: .green)
                        Text(absoluteDate(restoredAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var daysAffectedLabel: String {
        let count = affectedDays.count
        return count > 1 ? String(localized: "Days affected") : String(localized: "Day affected")
    }

    /// Distinct "YYYY-MM-DD" dates in this save's diff, ascending.
    private var affectedDays: [String] {
        guard let changes = vm.changesBySaveId[save.id] else { return [] }
        return Set(changes.map(\.date)).sorted()
    }

    private func daysAffectedText(_ changes: [FfiChangeDetail]) -> String {
        let days = affectedDays
        if days.isEmpty { return "—" }
        if days.count <= 3 {
            return days.map(formatDay).joined(separator: "; ")
        }
        let first = formatDay(days.first ?? "")
        let last = formatDay(days.last ?? "")
        return "\(days.count) days (\(first) – \(last))"
    }

    /// "2026-07-15" → "Tue 15 Jul". Falls back to the raw string.
    private func formatDay(_ isoDay: String) -> String {
        guard let date = Self.dayParser.date(from: isoDay) else { return isoDay }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private var actionsSection: some View {
        Section {
            SaveActionButtons(save: currentSave, vm: vm)
                .padding(.vertical, 2)
            if !currentSave.tags.isEmpty {
                TagChipRow(tags: currentSave.tags) { tag in
                    Task { await vm.removeTag(saveId: save.id, tag: tag) }
                }
            }
        }
    }

    @ViewBuilder
    private var changesSection: some View {
        Section("Changes") {
            if let changes = vm.changesBySaveId[save.id] {
                if changes.isEmpty {
                    Text("No changes from previous save")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private func parseDate(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    private func absoluteDate(_ iso: String) -> String {
        guard let date = parseDate(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func relativeDate(_ iso: String) -> String {
        guard let date = parseDate(iso) else { return iso }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return relative.localizedString(for: date, relativeTo: Date())
    }
}
