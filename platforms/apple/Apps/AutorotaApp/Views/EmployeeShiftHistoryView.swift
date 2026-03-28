import SwiftUI
import AutorotaKit

struct EmployeeShiftHistoryView: View {

    let employeeId: Int64
    let targetWeeklyHours: Float

    @State private var vm = ShiftHistoryViewModel()

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
            } else {
                List {
                    summarySection
                    currentWeekSection
                    upcomingSection
                    pastSection
                    hoursBreakdownSection
                }
            }
        }
        .navigationTitle("Shift Data")
        .task { await vm.load(employeeId: employeeId) }
        .alert("Error", isPresented: .constant(vm.error != nil)) {
            Button("OK") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section("Summary") {
            LabeledContent("This week",
                value: String(format: "%.1fh / %.1fh target", vm.currentWeekHours, targetWeeklyHours))
            LabeledContent("Total worked",
                value: String(format: "%.1fh across %d shifts",
                    vm.totalHours,
                    vm.pastShifts.count))
        }
    }

    private var currentWeekSection: some View {
        Section("This Week") {
            if vm.currentWeekShifts.isEmpty {
                Text("No shifts this week.").foregroundStyle(.secondary)
            } else {
                ForEach(vm.currentWeekShifts, id: \.assignmentId) { record in
                    ShiftRecordRow(record: record)
                }
            }
        }
    }

    private var upcomingSection: some View {
        Section("Upcoming") {
            if vm.plannedShifts.isEmpty {
                Text("No upcoming shifts.").foregroundStyle(.secondary)
            } else {
                ForEach(groupedByWeek(vm.plannedShifts), id: \.weekStart) { group in
                    DisclosureGroup {
                        ForEach(group.records, id: \.assignmentId) { record in
                            ShiftRecordRow(record: record)
                        }
                    } label: {
                        HStack {
                            Text("Week of \(group.weekStart)")
                            Spacer()
                            Text(String(format: "%.1fh", group.totalHours))
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    private var pastSection: some View {
        Section("Past") {
            if vm.pastShifts.isEmpty {
                Text("No past shifts.").foregroundStyle(.secondary)
            } else {
                ForEach(groupedByWeek(vm.pastShifts).reversed(), id: \.weekStart) { group in
                    DisclosureGroup {
                        ForEach(group.records, id: \.assignmentId) { record in
                            ShiftRecordRow(record: record)
                        }
                    } label: {
                        HStack {
                            Text("Week of \(group.weekStart)")
                            Spacer()
                            Text(String(format: "%.1fh", group.totalHours))
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    private var hoursBreakdownSection: some View {
        Section("Hours Breakdown") {
            DisclosureGroup("Weekly") {
                ForEach(vm.weeklyBreakdown) { entry in
                    LabeledContent(entry.weekStart, value: String(format: "%.1fh", entry.hours))
                }
            }
            DisclosureGroup("Monthly") {
                ForEach(vm.monthlyBreakdown) { entry in
                    LabeledContent(entry.month, value: String(format: "%.1fh", entry.hours))
                }
            }
        }
    }

    // MARK: - Helpers

    private struct WeekGroup {
        let weekStart: String
        let records: [FfiEmployeeShiftRecord]
        var totalHours: Float { records.reduce(0) { $0 + $1.durationHours } }
    }

    private func groupedByWeek(_ records: [FfiEmployeeShiftRecord]) -> [WeekGroup] {
        let grouped = Dictionary(grouping: records) { $0.weekStart }
        return grouped.map { WeekGroup(weekStart: $0.key, records: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }
    }
}

// MARK: - Shift Record Row

private struct ShiftRecordRow: View {
    let record: FfiEmployeeShiftRecord

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.weekday) \(record.date)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("\(record.startTime) – \(record.endTime)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(record.requiredRole)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(Capsule())
            statusBadge
            Text(String(format: "%.1fh", record.durationHours))
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (color, label) = statusInfo
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var statusInfo: (Color, String) {
        switch record.status {
        case "Proposed": (.orange, "Proposed")
        case "Confirmed": (.green, "Confirmed")
        case "Overridden": (.blue, "Overridden")
        default: (.gray, record.status)
        }
    }
}
