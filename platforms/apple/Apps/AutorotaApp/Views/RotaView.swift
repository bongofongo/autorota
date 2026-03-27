import SwiftUI
import AutorotaKit

struct RotaView: View {

    @State private var vm = RotaViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeekPickerView(selectedWeek: $vm.selectedWeekStart, category: vm.weekCategory)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .onChange(of: vm.selectedWeekStart) { _, _ in
                        vm.resetModes()
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Past lock/unlock (only in edit mode when week has past days)
                    if vm.isEditMode && vm.weekHasPastDays {
                        Button {
                            vm.pastUnlocked.toggle()
                        } label: {
                            Image(systemName: vm.pastUnlocked ? "lock.open.fill" : "lock.fill")
                        }
                        .tint(vm.pastUnlocked ? .orange : .secondary)
                    }

                    // Edit / Done toggle
                    if vm.schedule != nil {
                        Button(vm.isEditMode ? "Done" : "Edit") {
                            if vm.isEditMode {
                                vm.exitEditMode()
                            } else {
                                Task { await vm.enterEditMode() }
                            }
                        }
                    }

                    // Generate
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
    let category: WeekCategory

    var body: some View {
        HStack {
            Button(action: { selectedWeek = shifted(by: -1) }) {
                Image(systemName: "chevron.left")
            }
            Spacer()
            HStack(spacing: 8) {
                Text("Week of \(selectedWeek)")
                    .font(.subheadline.bold())
                CategoryBadge(category: category)
            }
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

private struct CategoryBadge: View {
    let category: WeekCategory

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var label: String {
        switch category {
        case .past: "Past"
        case .current: "Current"
        case .future: "Future"
        }
    }

    private var color: Color {
        switch category {
        case .past: .secondary
        case .current: .blue
        case .future: .orange
        }
    }
}

// MARK: - Schedule grid

private struct ScheduleGridView: View {
    let vm: RotaViewModel
    let schedule: FfiWeekSchedule

    @State private var shiftForEmployeePicker: FfiShiftInfo?
    @State private var shiftForTimeEdit: FfiShiftInfo?
    @State private var dayForNewShift: SheetDate?
    @State private var shiftToDelete: Int64?

    private var activeDays: [String] {
        vm.allWeekdays.filter { day in
            !(vm.shiftsByDay.first(where: { $0.weekday == day })?.shifts ?? []).isEmpty
                || vm.isEditMode
        }
    }

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                landscapeContent(availableWidth: geo.size.width)
            } else {
                portraitContent
            }
        }
        .safeAreaInset(edge: .bottom) {
            if vm.hasSwapSource {
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("Tap a highlighted employee to swap")
                        .font(.subheadline)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
        }
        .sheet(item: $shiftForEmployeePicker) { shift in
            EmployeePickerSheet(vm: vm, shift: shift)
        }
        .sheet(item: $shiftForTimeEdit) { shift in
            ShiftTimeEditSheet(vm: vm, shift: shift)
        }
        .sheet(item: $dayForNewShift) { sheetDate in
            AddShiftSheet(vm: vm, date: sheetDate.id)
        }
        .alert(
            "Delete this shift?",
            isPresented: Binding(
                get: { shiftToDelete != nil },
                set: { if !$0 { shiftToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { shiftToDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = shiftToDelete {
                    Task { await vm.deleteShift(id: id) }
                }
            }
        } message: {
            Text("This shift and all its assignments will be permanently deleted.")
        }
    }

    // MARK: Portrait layout

    private var portraitContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                ForEach(vm.allWeekdays, id: \.self) { day in
                    let shifts = vm.shiftsByDay.first(where: { $0.weekday == day })?.shifts ?? []
                    if !shifts.isEmpty || vm.isEditMode {
                        Section {
                            ForEach(shifts, id: \.id) { shift in
                                let locked = vm.isShiftLocked(shift)
                                ShiftCard(
                                    shift: shift,
                                    assignments: vm.assignments(for: shift.id),
                                    vm: vm,
                                    isEditMode: vm.isEditMode,
                                    isLocked: locked,
                                    onAddEmployee: { shiftForEmployeePicker = shift },
                                    onEditTimes: { shiftForTimeEdit = shift },
                                    onDeleteShift: { shiftToDelete = shift.id }
                                )
                            }
                            if vm.isEditMode && !vm.isDayLocked(day) {
                                Button {
                                    dayForNewShift = SheetDate(vm.dateForWeekday(day))
                                } label: {
                                    Label("Add Shift", systemImage: "plus.circle")
                                        .font(.subheadline)
                                }
                                .padding(.horizontal)
                            }
                        } header: {
                            HStack {
                                Text(day)
                                    .font(.headline)
                                if vm.isDayPast(day) {
                                    Image(systemName: vm.pastUnlocked ? "lock.open" : "lock")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: Landscape layout (weekly columns)

    private func landscapeContent(availableWidth: CGFloat) -> some View {
        let columnMinWidth: CGFloat = 150
        let columnSpacing: CGFloat = 8
        let outerPadding: CGFloat = 8
        let count = CGFloat(max(activeDays.count, 1))
        let totalSpacing = (count - 1) * columnSpacing + outerPadding * 2
        let columnWidth = max(columnMinWidth, (availableWidth - totalSpacing) / count)

        return ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(activeDays, id: \.self) { day in
                        dayColumn(day: day, width: columnWidth)
                    }
                }
                .padding(.horizontal, outerPadding)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func dayColumn(day: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Column header
            HStack(spacing: 4) {
                Text(day)
                    .font(.headline)
                if vm.isDayPast(day) {
                    Image(systemName: vm.pastUnlocked ? "lock.open" : "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Shifts
            let shifts = vm.shiftsByDay.first(where: { $0.weekday == day })?.shifts ?? []
            if shifts.isEmpty && !vm.isEditMode {
                Text("No shifts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.horizontal, 8)
            } else {
                ForEach(shifts, id: \.id) { shift in
                    let locked = vm.isShiftLocked(shift)
                    ShiftCard(
                        shift: shift,
                        assignments: vm.assignments(for: shift.id),
                        vm: vm,
                        isEditMode: vm.isEditMode,
                        isLocked: locked,
                        onAddEmployee: { shiftForEmployeePicker = shift },
                        onEditTimes: { shiftForTimeEdit = shift },
                        onDeleteShift: { shiftToDelete = shift.id },
                        isCompact: true
                    )
                }
            }

            if vm.isEditMode && !vm.isDayLocked(day) {
                Button {
                    dayForNewShift = SheetDate(vm.dateForWeekday(day))
                } label: {
                    Label("Add Shift", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .top)
    }
}

// MARK: - Shift card

private struct ShiftCard: View {
    let shift: FfiShiftInfo
    let assignments: [FfiScheduleEntry]
    let vm: RotaViewModel
    let isEditMode: Bool
    let isLocked: Bool
    let onAddEmployee: () -> Void
    let onEditTimes: () -> Void
    let onDeleteShift: () -> Void
    var isCompact: Bool = false

    private var canEdit: Bool { isEditMode && !isLocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if canEdit {
                        Button(action: onEditTimes) {
                            HStack(spacing: 4) {
                                Text("\(shift.startTime) – \(shift.endTime)")
                                    .font(.subheadline.bold())
                                Image(systemName: "pencil")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    } else {
                        Text("\(shift.startTime) – \(shift.endTime)")
                            .font(.subheadline.bold())
                    }
                    RoleTag(name: shift.requiredRole)
                }
                Spacer()

                if canEdit {
                    Button(action: onDeleteShift) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }

                Text("\(assignments.count)/\(shift.maxEmployees)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(assignments.count < Int(shift.minEmployees) ? .red : .secondary)
            }

            // Assignment rows
            if assignments.isEmpty {
                Text("Unassigned")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                ForEach(assignments, id: \.assignmentId) { entry in
                    AssignmentRow(
                        entry: entry,
                        vm: vm,
                        isEditMode: isEditMode,
                        isLocked: isLocked,
                        isCompact: isCompact
                    )
                }
            }

            // Add employee button
            if canEdit && assignments.count < Int(shift.maxEmployees) {
                Button(action: onAddEmployee) {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(radius: 1)
        )
        .opacity(isLocked && isEditMode ? 0.5 : 1.0)
        .padding(.horizontal, isCompact ? 6 : 16)
    }
}

// MARK: - Assignment row

private struct AssignmentRow: View {
    let entry: FfiScheduleEntry
    let vm: RotaViewModel
    let isEditMode: Bool
    let isLocked: Bool
    var isCompact: Bool = false

    private var isSwapSource: Bool { vm.isSwapSource(assignmentId: entry.assignmentId) }
    private var isSwapTarget: Bool { vm.isSwapTarget(entry: entry) }
    private var canEdit: Bool { isEditMode && !isLocked }

    var body: some View {
        // When a swap target, wrap in a tappable button-style row
        if canEdit && vm.hasSwapSource && isSwapTarget {
            swapTargetRow
        } else {
            baseRow
        }
    }

    // The row shown for a valid swap target — tapping it executes the swap
    private var swapTargetRow: some View {
        Button {
            Task { await vm.executeSwap(targetAssignmentId: entry.assignmentId) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(.white)
                    .frame(width: 16)
                Text(entry.employeeName ?? "Unknown")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
                #if os(iOS)
                if !isCompact {
                    Text("Swap")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.85))
                }
                #else
                Text("Swap")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.85))
                #endif
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(.indigo, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // Normal row for all other states
    private var baseRow: some View {
        HStack {
            if canEdit {
                // Tappable name tag — initiates or cancels swap
                Button {
                    if isSwapSource {
                        vm.cancelSwap()
                    } else if !vm.hasSwapSource {
                        vm.selectSwapSource(assignmentId: entry.assignmentId, shiftId: entry.shiftId)
                    }
                } label: {
                    Text(entry.employeeName ?? "Unknown")
                        .font(.subheadline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            isSwapSource
                                ? Color.indigo.opacity(0.2)
                                : Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(
                                    isSwapSource ? Color.indigo : Color.secondary.opacity(0.3),
                                    lineWidth: 1
                                )
                        )
                        .foregroundStyle(isSwapSource ? .indigo : .primary)
                }
                .buttonStyle(.plain)
                .disabled(vm.hasSwapSource && !isSwapSource)
            } else {
                Text(entry.employeeName ?? "Unknown")
                    .font(.subheadline)
            }

            Spacer()

            if canEdit && !vm.hasSwapSource {
                Button {
                    Task { await vm.deleteAssignment(id: entry.assignmentId) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

}

// MARK: - Employee picker sheet

private struct EmployeePickerSheet: View {
    let vm: RotaViewModel
    let shift: FfiShiftInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let available = vm.availableEmployees(for: shift.id)
            if available.isEmpty {
                ContentUnavailableView(
                    "No Available Employees",
                    systemImage: "person.slash",
                    description: Text("All employees are already assigned to this shift.")
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            } else {
                List(available, id: \.id) { employee in
                    Button {
                        Task {
                            await vm.addEmployeeToShift(shiftId: shift.id, employeeId: employee.id)
                            dismiss()
                        }
                    } label: {
                        Text(employee.displayName)
                    }
                }
                .navigationTitle("Add Employee")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Shift time edit sheet

private struct ShiftTimeEditSheet: View {
    let vm: RotaViewModel
    let shift: FfiShiftInfo
    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date

    init(vm: RotaViewModel, shift: FfiShiftInfo) {
        self.vm = vm
        self.shift = shift
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let base = Calendar.current.startOfDay(for: Date())
        _startDate = State(initialValue: fmt.date(from: shift.startTime) ?? base)
        _endDate = State(initialValue: fmt.date(from: shift.endTime) ?? base)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start Time", selection: $startDate, displayedComponents: .hourAndMinute)
                DatePicker("End Time", selection: $endDate, displayedComponents: .hourAndMinute)
            }
            .navigationTitle("Edit Shift Time")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "HH:mm"
                        fmt.locale = Locale(identifier: "en_US_POSIX")
                        let start = fmt.string(from: startDate)
                        let end = fmt.string(from: endDate)
                        Task {
                            await vm.updateShiftTimes(id: shift.id, startTime: start, endTime: end)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Add shift sheet

private struct AddShiftSheet: View {
    let vm: RotaViewModel
    let date: String
    @Environment(\.dismiss) private var dismiss
    @State private var startDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
    @State private var endDate = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
    @State private var selectedRole: String = ""

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start Time", selection: $startDate, displayedComponents: .hourAndMinute)
                DatePicker("End Time", selection: $endDate, displayedComponents: .hourAndMinute)
                Picker("Role", selection: $selectedRole) {
                    Text("Select a role").tag("")
                    ForEach(vm.roles, id: \.id) { role in
                        Text(role.name).tag(role.name)
                    }
                }
            }
            .navigationTitle("Add Shift")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "HH:mm"
                        fmt.locale = Locale(identifier: "en_US_POSIX")
                        let start = fmt.string(from: startDate)
                        let end = fmt.string(from: endDate)
                        Task {
                            await vm.createAdHocShift(
                                date: date, startTime: start,
                                endTime: end, requiredRole: selectedRole
                            )
                            dismiss()
                        }
                    }
                    .disabled(selectedRole.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Identifiable conformances for sheet bindings

extension FfiShiftInfo: @retroactive Identifiable {}

/// Wrapper to make a date string usable with `.sheet(item:)`.
private struct SheetDate: Identifiable {
    let id: String
    init(_ date: String) { self.id = date }
}
