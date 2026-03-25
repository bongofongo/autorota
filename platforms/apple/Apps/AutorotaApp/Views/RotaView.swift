import SwiftUI
import AutorotaKit

struct RotaView: View {

    @State private var vm = RotaViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeekPickerView(selectedWeek: $vm.selectedWeekStart)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .onChange(of: vm.selectedWeekStart) { _, _ in
                        Task { await vm.loadSchedule() }
                    }

                Divider()

                if vm.isLoading {
                    Spacer()
                    ProgressView("Loading schedule…")
                    Spacer()
                } else if let schedule = vm.schedule {
                    ScheduleGridView(vm: vm, schedule: schedule)
                } else {
                    Spacer()
                    ContentUnavailableView(
                        "No Schedule",
                        systemImage: "calendar.badge.plus",
                        description: Text("Tap Generate to create a schedule for this week.")
                    )
                    Spacer()
                }
            }
            .navigationTitle("Rota")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let schedule = vm.schedule, !schedule.finalized {
                        Button("Finalize") {
                            Task { await vm.finalizeRota() }
                        }
                        .tint(.green)
                    }

                    if vm.isScheduling {
                        ProgressView()
                    } else {
                        Button("Generate", systemImage: "wand.and.stars") {
                            Task { await vm.runSchedule() }
                        }
                    }
                }
            }
            .alert("Scheduling Warnings", isPresented: .constant(!vm.warnings.isEmpty)) {
                Button("OK") { vm.warnings = [] }
            } message: {
                Text(vm.warnings.map { w in
                    "\(w.weekday) \(w.startTime)–\(w.endTime) (\(w.requiredRole)): \(w.filled)/\(w.needed) filled"
                }.joined(separator: "\n"))
            }
            .alert("Error", isPresented: .constant(vm.error != nil)) {
                Button("OK") { vm.error = nil }
            } message: {
                Text(vm.error ?? "")
            }
            .task { await vm.loadSchedule() }
        }
    }
}

// MARK: - Week picker

private struct WeekPickerView: View {
    @Binding var selectedWeek: String

    var body: some View {
        HStack {
            Button(action: { selectedWeek = shifted(by: -1) }) {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text("Week of \(selectedWeek)")
                .font(.subheadline.bold())
            Spacer()
            Button(action: { selectedWeek = shifted(by: 1) }) {
                Image(systemName: "chevron.right")
            }
        }
    }

    private func shifted(by weeks: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = fmt.date(from: selectedWeek) else { return selectedWeek }
        let cal = Calendar(identifier: .iso8601)
        let shifted = cal.date(byAdding: .weekOfYear, value: weeks, to: date)!
        return fmt.string(from: shifted)
    }
}

// MARK: - Schedule grid

private struct ScheduleGridView: View {
    let vm: RotaViewModel
    let schedule: FfiWeekSchedule

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                ForEach(vm.shiftsByDay, id: \.weekday) { group in
                    Section {
                        ForEach(group.shifts, id: \.id) { shift in
                            ShiftCard(shift: shift, assignments: vm.assignments(for: shift.id), vm: vm)
                        }
                    } header: {
                        Text(group.weekday)
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Shift card

private struct ShiftCard: View {
    let shift: FfiShiftInfo
    let assignments: [FfiScheduleEntry]
    let vm: RotaViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(shift.startTime) – \(shift.endTime)")
                        .font(.subheadline.bold())
                    Text(shift.requiredRole)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(assignments.count)/\(shift.maxEmployees)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(assignments.count < Int(shift.minEmployees) ? .red : .secondary)
            }

            if assignments.isEmpty {
                Text("Unassigned")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                ForEach(assignments, id: \.assignmentId) { entry in
                    AssignmentRow(entry: entry, vm: vm)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background).shadow(radius: 1))
        .padding(.horizontal)
    }
}

// MARK: - Assignment row

private struct AssignmentRow: View {
    let entry: FfiScheduleEntry
    let vm: RotaViewModel

    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)

            Text(entry.employeeName)
                .font(.subheadline)

            Spacer()

            Menu {
                if entry.status != "Confirmed" {
                    Button("Confirm") {
                        Task { await vm.confirmAssignment(id: entry.assignmentId) }
                    }
                }
                Button("Remove", role: .destructive) {
                    Task { await vm.deleteAssignment(id: entry.assignmentId) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        switch entry.status {
        case "Confirmed":  return "checkmark.circle.fill"
        case "Overridden": return "pin.fill"
        default:           return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case "Confirmed":  return .green
        case "Overridden": return .orange
        default:           return .secondary
        }
    }
}
