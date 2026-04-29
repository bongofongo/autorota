import SwiftUI
import AutorotaKit
import TipKit
import os

private extension Logger {
    /// Logger for SwiftUI views in `RotaView` — use for diagnostics around
    /// silent date-arithmetic fallbacks and other defensive guards that
    /// would otherwise crash the picker.
    static let weekPicker = Logger(
        subsystem: "com.toadmountain.autorota",
        category: "rota.week-picker"
    )
}

struct RotaView: View {

    @State private var vm = RotaViewModel()
    @State private var showExportSheet = false
    /// `-1` means "not yet loaded" — treat as having employees so the existing
    /// no-schedule CUV (with Generate prompt) is the default. Only an explicit
    /// `0` triggers the prerequisite empty state.
    @State private var employeeCount: Int = -1
    /// Tracks the currently-running week-change reload so the prior task can
    /// be cancelled when the user rapidly steps through weeks. Without this,
    /// a slow load for week N could overwrite a fresh load for week N+1.
    @State private var weekChangeTask: Task<Void, Never>?
    private let twoPassTip = RotaTwoPassTip()
    private let shareTip = RotaShareTip()
    @Environment(RotaUIBridge.self) private var bridge
    @Environment(EmployeeUIBridge.self) private var employeeBridge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeekPickerView(selectedWeek: $vm.selectedWeekStart, category: vm.weekCategory)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .onChange(of: vm.selectedWeekStart) { _, _ in
                        // Cancel any in-flight reload from a prior week step
                        // so a slow load can't clobber a fresh one.
                        weekChangeTask?.cancel()
                        weekChangeTask = Task {
                            await vm.autoSave()
                            if Task.isCancelled { return }
                            vm.resetModes()
                            if Task.isCancelled { return }
                            await vm.loadSchedule()
                        }
                    }

                Divider()

                if vm.isLoading {
                    Spacer()
                    ProgressView("Loading schedule…")
                    Spacer()
                } else if let schedule = vm.schedule {
                    ScheduleGridView(vm: vm, schedule: schedule)
                } else if employeeCount == 0 {
                    Spacer()
                    ContentUnavailableView {
                        Label("empty.rota.title", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text("empty.rota.body")
                    } actions: {
                        Button {
                            employeeBridge.requestNewEmployeeSheet = true
                        } label: {
                            Label("empty.rota.action", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
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
            .safeAreaInset(edge: .top, spacing: 0) {
                rotaTopTip
            }
            .navigationTitle("Rota")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    overflowMenu
                }
            }
            .onChange(of: vm.isEditMode) { _, new in
                if reduceMotion {
                    bridge.isEditMode = new
                } else {
                    withAnimation(.smooth(duration: 0.35)) {
                        bridge.isEditMode = new
                    }
                }
            }
            .onChange(of: bridge.isEditMode) { _, new in
                if !new && vm.isEditMode {
                    vm.exitEditMode()
                }
            }
            .alert(
                "No schedule for \(vm.weekDateRangeLabel)",
                isPresented: $vm.showGenerateConfirmation
            ) {
                Button("Use existing shifts") {
                    Task { await vm.createFromTemplate() }
                }
                Button("Create empty schedule") {
                    Task { await vm.createEmpty() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("How would you like to create a schedule for this week?")
            }
            .alert(
                "Delete schedule for \(vm.weekDateRangeLabel)?",
                isPresented: $vm.showDeleteScheduleConfirmation
            ) {
                Button("Delete", role: .destructive) {
                    Task { await vm.deleteSchedule() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All shifts and assignments for this week will be permanently deleted.")
            }
            .alert("Scheduling Warnings", isPresented: .constant(!vm.warnings.isEmpty)) {
                Button("OK") { vm.warnings = [] }
            } message: {
                Text(vm.warnings.map { w in
                    let roleLabel = w.requiredRole.isEmpty ? "Any Role" : w.requiredRole
                    return "\(w.weekday) \(w.startTime)–\(w.endTime) (\(roleLabel)): \(w.filled)/\(w.needed) filled"
                }.joined(separator: "\n"))
            }
            .alert("Error", isPresented: .constant(vm.error != nil)) {
                Button("OK") { vm.error = nil }
            } message: {
                Text(vm.error ?? "")
            }
            .sheet(isPresented: $showExportSheet) {
                ExportSheetView(
                    weekStart: vm.selectedWeekStart,
                    service: vm.service,
                    hasUnsavedEdits: vm.isDirty,
                    onSaveBeforeBulkSend: { await vm.autoSave() }
                )
            }
            .task {
                await vm.loadSchedule()
                await refreshEmployeeCount()
            }
            .onReceive(NotificationCenter.default.publisher(for: .autorotaDataChanged)) { _ in
                Task { await refreshEmployeeCount() }
            }
        }
    }

    private func refreshEmployeeCount() async {
        do {
            let n = try await countEmployeesAsync()
            await MainActor.run { employeeCount = Int(n) }
        } catch {
            // Keep `-1` (unknown) so the no-schedule CUV renders without
            // suppressing the prerequisite empty state on next refresh.
            await MainActor.run {
                if employeeCount < 0 { employeeCount = -1 }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let n = try? await countEmployeesAsync() {
                await MainActor.run { employeeCount = Int(n) }
            }
        }
    }

    // MARK: - Top-of-page tip

    /// `safeAreaInset(edge: .top)` content. Reserves the tip's space without
    /// reflowing siblings — an inline TipView in the body cascaded into a
    /// sidebar reflow on macOS `.sidebarAdaptable` (same regression fixed for
    /// `EmployeeListView`).
    @ViewBuilder
    private var rotaTopTip: some View {
        if !vm.isLoading {
            if vm.schedule != nil {
                TipView(shareTip)
                    .padding(.horizontal)
                    .padding(.top, 4)
            } else if employeeCount != 0 {
                TipView(twoPassTip)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Toolbar menu

    /// Mirrors `EmployeeListView`'s primary-action component: an `ellipsis`
    /// `Menu` (or a plain checkmark `Button` while editing) anchored in the
    /// navigation toolbar. Surfaces Generate / Edit / Share / Delete on every
    /// platform — without this the macOS Rota page has no Generate affordance.
    @ViewBuilder
    private var overflowMenu: some View {
        if vm.isEditMode {
            Button {
                vm.exitEditMode()
            } label: {
                Image(systemName: "checkmark")
            }
            .accessibilityLabel("Done editing")
        } else {
            Menu {
                ForEach(overflowActions) { action in
                    Button(role: action.role) {
                        action.action()
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More actions")
        }
    }

    // MARK: - Overflow menu actions

    private var overflowActions: [RotaOverflowAction] {
        var actions: [RotaOverflowAction] = []

        if vm.isEditMode {
            // No overflow actions in edit mode — checkmark button exits
        } else {
            if vm.schedule != nil {
                actions.append(RotaOverflowAction(
                    title: "Delete schedule",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    vm.showDeleteScheduleConfirmation = true
                })
                actions.append(RotaOverflowAction(
                    title: "Edit",
                    systemImage: "pencil"
                ) {
                    Task { await vm.enterEditMode() }
                })
                actions.append(RotaOverflowAction(
                    title: "Share",
                    systemImage: "square.and.arrow.up"
                ) {
                    showExportSheet = true
                })
            }
            actions.append(RotaOverflowAction(
                title: "Generate",
                systemImage: "wand.and.stars"
            ) {
                Task { await vm.runSchedule() }
            })
        }

        return actions
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
            .accessibilityIdentifier("rota.prevWeek")
            Spacer()
            HStack(spacing: 8) {
                Text("Week of \(selectedWeek)")
                    .font(.subheadline.bold())
                    .accessibilityIdentifier("rota.weekTitle")
                CategoryBadge(category: category)
            }
            Spacer()
            Button(action: { selectedWeek = shifted(by: 1) }) {
                Image(systemName: "chevron.right")
            }
            .accessibilityIdentifier("rota.nextWeek")
        }
    }

    private func shifted(by weeks: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = fmt.date(from: selectedWeek) else { return selectedWeek }
        let cal = Calendar(identifier: .iso8601)
        // `cal.date(byAdding:)` only fails for arithmetically impossible
        // additions (year overflow, etc.). Treat that as "stay on the
        // current week" so the picker doesn't crash on extreme inputs;
        // log so the silent fallback is debuggable.
        guard let shifted = cal.date(byAdding: .weekOfYear, value: weeks, to: date) else {
            Logger.weekPicker.warning(
                "cal.date(byAdding: .weekOfYear, value: \(weeks)) returned nil; staying on \(selectedWeek)"
            )
            return selectedWeek
        }
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

/// Discriminator for the schedule grid's sheet — replaces three separate
/// `.sheet(item:)` modifiers, only one of which would ever fire on the same
/// view. Stacking multiple `.sheet(item:)` modifiers risks SwiftUI dropping
/// later assignments when a prior sheet is mid-dismiss.
private enum ScheduleSheet: Identifiable {
    case employeePicker(FfiShiftInfo)
    case timeEdit(FfiShiftInfo)
    case addShift(SheetDate)

    var id: String {
        switch self {
        case .employeePicker(let s): return "emp-\(s.id)"
        case .timeEdit(let s):       return "time-\(s.id)"
        case .addShift(let d):       return "add-\(d.id)"
        }
    }
}

private struct ScheduleGridView: View {
    let vm: RotaViewModel
    let schedule: FfiWeekSchedule

    @State private var activeSheet: ScheduleSheet?
    @State private var shiftToDelete: Int64?
    @State private var showUnlockPastConfirmation = false

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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .employeePicker(let shift):
                EmployeePickerSheet(vm: vm, shift: shift)
            case .timeEdit(let shift):
                ShiftTimeEditSheet(vm: vm, shift: shift)
            case .addShift(let date):
                AddShiftSheet(vm: vm, date: date.id)
            }
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
        .alert(
            "Edit past rota?",
            isPresented: $showUnlockPastConfirmation
        ) {
            Button("Edit", role: .destructive) {
                vm.pastUnlocked = true
            }
            Button("Cancel", role: .cancel) {
                vm.isEditMode = false
            }
        } message: {
            Text("This rota is from a past week. Are you sure you want to make changes?")
        }
        .onChange(of: vm.isEditMode) { _, new in
            if new && vm.weekCategory == .past && !vm.pastUnlocked {
                showUnlockPastConfirmation = true
            }
        }
    }

    // MARK: Portrait layout

    private var portraitContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                ForEach(vm.allWeekdays, id: \.self) { day in
                    let shifts = vm.shiftsByDay.first(where: { $0.weekday == day })?.shifts ?? []
                    Section {
                        ForEach(shifts, id: \.id) { shift in
                            let locked = vm.isShiftLocked(shift)
                            ShiftCard(
                                shift: shift,
                                assignments: vm.assignments(for: shift.id),
                                vm: vm,
                                isEditMode: vm.isEditMode,
                                isLocked: locked,
                                onAddEmployee: { activeSheet = .employeePicker(shift) },
                                onEditTimes: { activeSheet = .timeEdit(shift) },
                                onDeleteShift: { shiftToDelete = shift.id }
                            )
                        }
                        if shifts.isEmpty && !vm.isEditMode {
                            Text("No shifts")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .italic()
                                .padding(.horizontal)
                        }
                        if vm.isEditMode && !vm.isDayLocked(day) {
                            Button {
                                activeSheet = .addShift(SheetDate(vm.dateForWeekday(day)))
                            } label: {
                                Label("Add Shift", systemImage: "plus.circle")
                                    .font(.subheadline)
                            }
                            .padding(.horizontal)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(day)
                                .font(.headline)
                            DayFlourish(isToday: vm.isDayToday(day), isPast: vm.isDayPast(day))
                            Spacer()
                        }
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

    // MARK: Landscape layout (weekly columns)

    private func landscapeContent(availableWidth: CGFloat) -> some View {
        let columnMinWidth: CGFloat = 150
        let columnSpacing: CGFloat = 8
        let outerPadding: CGFloat = 8
        let count = CGFloat(max(vm.allWeekdays.count, 1))
        let totalSpacing = (count - 1) * columnSpacing + outerPadding * 2
        let columnWidth = max(columnMinWidth, (availableWidth - totalSpacing) / count)

        return ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(vm.allWeekdays, id: \.self) { day in
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
            HStack(spacing: 6) {
                Text(day)
                    .font(.headline)
                DayFlourish(isToday: vm.isDayToday(day), isPast: vm.isDayPast(day))
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
                        onAddEmployee: { activeSheet = .employeePicker(shift) },
                        onEditTimes: { activeSheet = .timeEdit(shift) },
                        onDeleteShift: { shiftToDelete = shift.id },
                        isCompact: true
                    )
                }
            }

            if vm.isEditMode && !vm.isDayLocked(day) {
                Button {
                    activeSheet = .addShift(SheetDate(vm.dateForWeekday(day)))
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

// MARK: - Day flourish

/// Small colored dot in day headers indicating past/today. No dot for future days.
private struct DayFlourish: View {
    let isToday: Bool
    let isPast: Bool

    var body: some View {
        if let color = dotColor {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
    }

    private var dotColor: Color? {
        if isToday { return .blue }
        if isPast { return .secondary }
        return nil
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
                    .accessibilityLabel("Delete shift")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shiftA11yLabel)
    }

    private var shiftA11yLabel: String {
        let role = shift.requiredRole.isEmpty ? "any role" : shift.requiredRole
        let staffing = "\(assignments.count) of \(shift.maxEmployees) staffed"
        return "Shift \(shift.startTime) to \(shift.endTime), \(role), \(staffing)"
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
                Text(entry.employeeName)
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
        let employeeName = entry.employeeName
        return HStack {
            if canEdit {
                // Tappable name tag — initiates or cancels swap
                Button {
                    if isSwapSource {
                        vm.cancelSwap()
                    } else if !vm.hasSwapSource {
                        vm.selectSwapSource(assignmentId: entry.assignmentId, shiftId: entry.shiftId)
                    }
                } label: {
                    Text(employeeName)
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
                .accessibilityLabel(isSwapSource ? "Cancel swap for \(employeeName)" : "Start swap for \(employeeName)")
            } else {
                Text(employeeName)
                    .font(.subheadline)
                    .accessibilityLabel("Assigned: \(employeeName)")
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
                .accessibilityLabel("Remove assignment")
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
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 400, minHeight: 300, idealHeight: 450)
        #endif
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
            #if os(macOS)
            .formStyle(.grouped)
            #endif
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
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
        #if os(macOS)
        .frame(minWidth: 340, idealWidth: 400, minHeight: 200, idealHeight: 280)
        #endif
    }
}

// MARK: - Add shift sheet

private struct AddShiftSheet: View {
    let vm: RotaViewModel
    let date: String
    @Environment(\.dismiss) private var dismiss
    // `Calendar.current.date(bySettingHour:...)` only returns nil if the
    // resulting time doesn't exist (e.g. spring-forward DST gap). The 09:00
    // / 17:00 defaults are picked specifically so this can't happen on any
    // real-world day; if it ever does, we fall back to "now" rather than
    // force-unwrap and crash.
    @State private var startDate = AddShiftSheet.defaultTime(hour: 9)
    @State private var endDate = AddShiftSheet.defaultTime(hour: 17)
    @State private var selectedRole: String = ""

    private static func defaultTime(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
            ?? Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start Time", selection: $startDate, displayedComponents: .hourAndMinute)
                DatePicker("End Time", selection: $endDate, displayedComponents: .hourAndMinute)
                Picker("Role", selection: $selectedRole) {
                    Text("Any Role").tag("")
                    ForEach(vm.roles, id: \.id) { role in
                        Text(role.name).tag(role.name)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
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
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 420, minHeight: 260, idealHeight: 340)
        #endif
    }
}

// MARK: - Identifiable conformances for sheet bindings

extension FfiShiftInfo: @retroactive Identifiable {}

/// Wrapper to make a date string usable with `.sheet(item:)`.
private struct SheetDate: Identifiable {
    let id: String
    init(_ date: String) { self.id = date }
}
