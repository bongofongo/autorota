import SwiftUI
import AutorotaKit

/// Single-employee-at-a-time availability editor with bottom navigation bar.
/// Used on compact-width devices (iPhone).
struct CarouselAvailabilityView: View {

    let employees: [FfiEmployee]
    let vm: EmployeeViewModel
    let progressVM: AvailabilityProgressViewModel
    let weekLabel: String
    let weekStartString: String

    @State private var selectedIndex: Int = 0
    @State private var showEmployeePicker = false

    // Per-employee local slot state, keyed by employee ID
    @State private var slotsCache: [Int64: [AvailabilitySlot]] = [:]

    private var currentEmployee: FfiEmployee? {
        guard employees.indices.contains(selectedIndex) else { return nil }
        return employees[selectedIndex]
    }

    private func slotsFor(_ employee: FfiEmployee) -> [AvailabilitySlot] {
        slotsCache[employee.id] ?? (employee.availability.isEmpty ? employee.defaultAvailability : employee.availability)
    }

    var body: some View {
        if employees.isEmpty {
            ContentUnavailableView("No Employees", systemImage: "person.slash")
        } else {
            VStack(spacing: 0) {
                // Week label
                Text(weekLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Availability grid for current employee
                TabView(selection: $selectedIndex) {
                    ForEach(Array(employees.enumerated()), id: \.element.id) { index, employee in
                        AvailabilityPage(
                            employee: employee,
                            slots: slotsFor(employee),
                            onSlotsChange: { newSlots in
                                slotsCache[employee.id] = newSlots
                                var updated = employee
                                updated.availability = newSlots
                                Task { await vm.update(updated) }
                            }
                        )
                        .tag(index)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif

            }
            .safeAreaInset(edge: .bottom) {
                if let employee = currentEmployee {
                    VStack(spacing: 0) {
                        Divider()
                        ZStack {
                            // Centered: employee name
                            Button {
                                showEmployeePicker = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(employee.displayName)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            // Trailing: done checkmark
                            HStack {
                                Spacer()
                                Button {
                                    Task { await toggleDone(employee: employee) }
                                } label: {
                                    Image(systemName: progressVM.isDone(employee.id) ? "checkmark.circle.fill" : "checkmark.circle")
                                        .font(.title3)
                                        .foregroundStyle(progressVM.isDone(employee.id) ? .green : .secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(.bar)
                }
            }
            .sheet(isPresented: $showEmployeePicker) {
                AvailabilityEmployeePickerSheet(
                    employees: employees,
                    progressVM: progressVM,
                    selectedIndex: selectedIndex,
                    selection: $selectedIndex
                )
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Actions

    private func toggleDone(employee: FfiEmployee) async {
        if progressVM.isDone(employee.id) {
            await progressVM.markUndone(employeeId: employee.id, weekStart: weekStartString)
        } else {
            await progressVM.markDone(employeeId: employee.id, weekStart: weekStartString)
            // Auto-advance to next not-done employee
            if let nextIdx = progressVM.nextNotDoneIndex(employees: employees, after: selectedIndex) {
                withAnimation { selectedIndex = nextIdx }
            }
        }
    }
}

// MARK: - Availability Page (single employee)

private struct AvailabilityPage: View {
    let employee: FfiEmployee
    @State var slots: [AvailabilitySlot]
    let onSlotsChange: ([AvailabilitySlot]) -> Void

    private let visibleRange: (start: Int, end: Int)

    init(employee: FfiEmployee, slots: [AvailabilitySlot], onSlotsChange: @escaping ([AvailabilitySlot]) -> Void) {
        self.employee = employee
        self._slots = State(initialValue: slots)
        self.onSlotsChange = onSlotsChange
        self.visibleRange = AvailabilityGridView.inferredVisibleRange(from: slots)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(employee.displayName)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 16)

                if !employee.roles.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(employee.roles, id: \.self) { role in
                            Text(role)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                }

                AvailabilityGridView(
                    slots: slots,
                    isEditable: true,
                    visibleHourStart: visibleRange.start,
                    visibleHourEnd: visibleRange.end,
                    showRangePicker: true,
                    onChange: { newSlots in
                        slots = newSlots
                        onSlotsChange(newSlots)
                    }
                )
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Employee Picker Sheet

private struct AvailabilityEmployeePickerSheet: View {
    let employees: [FfiEmployee]
    let progressVM: AvailabilityProgressViewModel
    let selectedIndex: Int
    @Binding var selection: Int
    @Environment(\.dismiss) private var dismiss

    @State private var notDoneExpanded = true
    @State private var doneExpanded = false

    private var notDoneEmployees: [(index: Int, employee: FfiEmployee)] {
        employees.enumerated().filter { !progressVM.isDone($0.element.id) }.map { (index: $0.offset, employee: $0.element) }
    }

    private var doneEmployees: [(index: Int, employee: FfiEmployee)] {
        employees.enumerated().filter { progressVM.isDone($0.element.id) }.map { (index: $0.offset, employee: $0.element) }
    }

    var body: some View {
        NavigationStack {
            List {
                DisclosureGroup("Not Done (\(notDoneEmployees.count))", isExpanded: $notDoneExpanded) {
                    ForEach(notDoneEmployees, id: \.employee.id) { item in
                        Button {
                            selection = item.index
                            dismiss()
                        } label: {
                            HStack {
                                Text(item.employee.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if item.index == selectedIndex {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                DisclosureGroup("Done (\(doneEmployees.count))", isExpanded: $doneExpanded) {
                    ForEach(doneEmployees, id: \.employee.id) { item in
                        Button {
                            selection = item.index
                            dismiss()
                        } label: {
                            HStack {
                                Text(item.employee.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                                if item.index == selectedIndex {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Employees")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

