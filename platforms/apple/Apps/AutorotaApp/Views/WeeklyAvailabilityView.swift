import SwiftUI
import AutorotaKit

struct WeeklyAvailabilityView: View {

    @State private var vm = EmployeeViewModel()
    @State private var progressVM = AvailabilityProgressViewModel()
    @Environment(\.dismiss) private var dismiss
    /// Tracks whether the current window is landscape (width > height).
    @State private var isLandscape = false

    /// Next Monday's date, used for the header.
    private var nextWeekStart: Date {
        let cal = Calendar.current
        let today = Date()
        let weekday = cal.component(.weekday, from: today)
        // weekday: 1=Sun, 2=Mon, ..., 7=Sat
        let daysUntilMonday = (9 - weekday) % 7
        return cal.date(byAdding: .day, value: daysUntilMonday == 0 ? 7 : daysUntilMonday, to: today)!
    }

    private var weekLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let start = nextWeekStart
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start)!
        return "Week of \(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private var weekStartString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: nextWeekStart)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    /// Grid on macOS always; on iOS only in landscape.
    private var useGridLayout: Bool {
        #if os(macOS)
        return true
        #else
        return isLandscape
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.employees.isEmpty {
                    ProgressView("Loading…")
                } else if vm.employees.isEmpty {
                    ContentUnavailableView("No Employees", systemImage: "person.slash")
                } else if useGridLayout {
                    gridLayout
                } else {
                    CarouselAvailabilityView(
                        employees: vm.employees,
                        vm: vm,
                        progressVM: progressVM,
                        weekLabel: weekLabel,
                        weekStartString: weekStartString
                    )
                }
            }
            .navigationTitle("Weekly Availability")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await vm.load() }
            .task { await progressVM.load(weekStart: weekStartString) }
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > proxy.size.height
            } action: { newValue in
                isLandscape = newValue
            }
        }
    }

    // MARK: - Grid Layout (iPad/Mac)

    @ViewBuilder
    private var gridLayout: some View {
        if progressVM.allDone(employees: vm.employees) {
            VStack {
                Text(weekLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                AllAvailabilitiesSetView()
            }
        } else {
            ScrollView {
                Text(weekLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(vm.employees, id: \.id) { employee in
                        AvailabilityCard(
                            employee: employee,
                            vm: vm,
                            progressVM: progressVM,
                            weekStartString: weekStartString
                        )
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Card (for grid layout)

private struct AvailabilityCard: View {
    let employee: FfiEmployee
    let vm: EmployeeViewModel
    let progressVM: AvailabilityProgressViewModel
    let weekStartString: String

    @State private var slots: [AvailabilitySlot]
    @State private var selectionMode = false
    private let visibleRange: (start: Int, end: Int)

    init(employee: FfiEmployee, vm: EmployeeViewModel, progressVM: AvailabilityProgressViewModel, weekStartString: String) {
        self.employee = employee
        self.vm = vm
        self.progressVM = progressVM
        self.weekStartString = weekStartString
        let initial = employee.availability.isEmpty ? employee.defaultAvailability : employee.availability
        self._slots = State(initialValue: initial)
        self.visibleRange = AvailabilityGridView.inferredVisibleRange(from: initial)
    }

    private var isDone: Bool { progressVM.isDone(employee.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(employee.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !employee.roles.isEmpty {
                        Text(employee.roles.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                // Selection mode toggle
                Button {
                    selectionMode.toggle()
                } label: {
                    Image(systemName: "rectangle.dashed")
                        .font(.body)
                        .foregroundStyle(selectionMode ? .white : .secondary)
                        .frame(width: 36, height: 36)
                        .background(selectionMode ? Color.blue : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Done checkmark
                Button {
                    Task {
                        if isDone {
                            await progressVM.markUndone(employeeId: employee.id, weekStart: weekStartString)
                        } else {
                            await progressVM.markDone(employeeId: employee.id, weekStart: weekStartString)
                        }
                    }
                } label: {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.title3)
                        .foregroundStyle(isDone ? .green : .secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            AvailabilityGridView(
                slots: slots,
                isEditable: true,
                visibleHourStart: visibleRange.start,
                visibleHourEnd: visibleRange.end,
                onChange: { newSlots in
                    slots = newSlots
                    var updated = employee
                    updated.availability = newSlots
                    Task { await vm.update(updated) }
                },
                showSelectionToggle: false,
                externalSelectionMode: $selectionMode
            )
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
