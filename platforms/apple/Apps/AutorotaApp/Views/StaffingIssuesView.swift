import SwiftUI

/// Warnings sheet opened from the Rota tab's options menu. Lists the week's
/// live staffing gaps: under-minimum shifts (and unmet per-role minimums) as
/// warnings, met-minimum-but-below-maximum shifts as notes. Warnings first.
struct StaffingIssuesView: View {
    let issues: [StaffingIssue]
    /// Maps a weekday ("Mon") to its day-of-month label ("Jun 1") for the
    /// selected week. Injected so this view stays dumb and previewable.
    let dayLabel: (String) -> String
    /// Called when a row is tapped: the host dismisses this sheet, scrolls the
    /// grid to the shift, and opens its editor. nil disables row tapping.
    var onSelect: ((StaffingIssue) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private var warnings: [StaffingIssue] { issues.filter { $0.severity == .warning } }
    private var notes: [StaffingIssue] { issues.filter { $0.severity == .note } }

    var body: some View {
        NavigationStack {
            Group {
                if issues.isEmpty {
                    ContentUnavailableView(
                        "Fully staffed",
                        systemImage: "checkmark.circle",
                        description: Text("Every shift this week has met its minimum and maximum headcount.")
                    )
                } else {
                    List {
                        if !warnings.isEmpty {
                            Section {
                                ForEach(warnings) { issue in
                                    row(for: issue)
                                }
                            } header: {
                                Text("Warnings")
                            } footer: {
                                Text("These shifts are below their minimum staffing.")
                            }
                        }
                        if !notes.isEmpty {
                            Section {
                                ForEach(notes) { issue in
                                    row(for: issue)
                                }
                            } header: {
                                Text("Notes")
                            } footer: {
                                Text("These shifts have met their minimum but still have room before the maximum.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Warnings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// A plain row, or a tappable one that jumps to the shift when the host
    /// provided `onSelect`.
    @ViewBuilder
    private func row(for issue: StaffingIssue) -> some View {
        if let onSelect {
            Button {
                onSelect(issue)
            } label: {
                StaffingIssueRow(issue: issue, dayLabel: dayLabel, showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this shift in the rota.")
        } else {
            StaffingIssueRow(issue: issue, dayLabel: dayLabel)
        }
    }
}

private struct StaffingIssueRow: View {
    let issue: StaffingIssue
    let dayLabel: (String) -> String
    var showsChevron = false

    private var isWarning: Bool { issue.severity == .warning }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(issue.weekday) \(dayLabel(issue.weekday))")
                        .font(.subheadline.weight(.semibold))
                    Text("\(issue.startTime)–\(issue.endTime)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(detailText)
                    .font(.footnote)
                    .foregroundStyle(isWarning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }

            Spacer()

            Text("\(issue.filled)/\(issue.needed)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        if isWarning {
            if let role = issue.role {
                return String(localized: "Needs \(issue.needed - issue.filled) more \(role)")
            }
            return String(localized: "Needs \(issue.needed - issue.filled) more to reach the minimum")
        }
        let room = issue.needed - issue.filled
        return String(localized: "Room for \(room) more")
    }
}

#Preview("Issues") {
    StaffingIssuesView(
        issues: [
            StaffingIssue(shiftId: 1, severity: .warning, weekday: "Mon", date: "2026-07-06",
                          startTime: "07:00", endTime: "12:00", role: nil, filled: 1, needed: 2),
            StaffingIssue(shiftId: 2, severity: .warning, weekday: "Wed", date: "2026-07-08",
                          startTime: "12:00", endTime: "17:00", role: "Barista", filled: 0, needed: 1),
            StaffingIssue(shiftId: 3, severity: .note, weekday: "Fri", date: "2026-07-10",
                          startTime: "07:00", endTime: "12:00", role: nil, filled: 2, needed: 3),
        ],
        dayLabel: { _ in "Jul 6" }
    )
}

#Preview("Empty") {
    StaffingIssuesView(issues: [], dayLabel: { _ in "" })
}
