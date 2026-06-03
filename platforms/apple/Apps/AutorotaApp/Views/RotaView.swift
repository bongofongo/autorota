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
            .navigationTitle("")
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
                    title: "Swap staff",
                    systemImage: "arrow.left.arrow.right"
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
    case shiftEditor(FfiShiftInfo)
    case addShift(SheetDate)

    var id: String {
        switch self {
        case .shiftEditor(let s): return "shift-\(s.id)"
        case .addShift(let d):    return "add-\(d.id)"
        }
    }
}

private struct ScheduleGridView: View {
    let vm: RotaViewModel
    let schedule: FfiWeekSchedule

    @State private var activeSheet: ScheduleSheet?
    /// A sheet whose presentation is deferred until the past-week edit prompt is
    /// confirmed. nil when no confirmation is pending.
    @State private var pendingSheet: ScheduleSheet?
    @State private var showUnlockPastConfirmation = false

    /// Present a sheet, first prompting for confirmation if this is the first
    /// edit on a locked past week. Confirming unlocks edits for the visit.
    private func requestSheet(_ sheet: ScheduleSheet) {
        if vm.weekCategory == .past && !vm.pastUnlocked {
            pendingSheet = sheet
            showUnlockPastConfirmation = true
        } else {
            activeSheet = sheet
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .shiftEditor(let shift):
                ShiftEditorSheet(vm: vm, shift: shift)
            case .addShift(let date):
                AddShiftSheet(vm: vm, date: date.id)
            }
        }
        .alert(
            "Edit past rota?",
            isPresented: $showUnlockPastConfirmation
        ) {
            Button("Edit", role: .destructive) {
                vm.pastUnlocked = true
                if let sheet = pendingSheet {
                    pendingSheet = nil
                    activeSheet = sheet
                }
            }
            Button("Cancel", role: .cancel) {
                pendingSheet = nil
                if vm.isEditMode { vm.isEditMode = false }
            }
        } message: {
            Text("This rota is from a past week. Are you sure you want to make changes?")
        }
        .onChange(of: vm.isEditMode) { _, new in
            // Entering edit mode (for the swap gesture) on a locked past week
            // also prompts for confirmation.
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
                            ShiftCard(
                                shift: shift,
                                assignments: vm.assignments(for: shift.id),
                                vm: vm,
                                isEditMode: vm.isEditMode,
                                isLocked: vm.isShiftLocked(shift),
                                onEdit: { requestSheet(.shiftEditor(shift)) }
                            )
                        }
                        if shifts.isEmpty {
                            Text("No shifts")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .italic()
                                .padding(.horizontal)
                        }
                    } header: {
                        DayHeader(
                            day: day,
                            isToday: vm.isDayToday(day),
                            isPast: vm.isDayPast(day),
                            onAddShift: { requestSheet(.addShift(SheetDate(vm.dateForWeekday(day)))) }
                        )
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
            // Column header — tap to add a shift on this day
            DayHeader(
                day: day,
                isToday: vm.isDayToday(day),
                isPast: vm.isDayPast(day),
                onAddShift: { requestSheet(.addShift(SheetDate(vm.dateForWeekday(day)))) }
            )

            // Shifts
            let shifts = vm.shiftsByDay.first(where: { $0.weekday == day })?.shifts ?? []
            if shifts.isEmpty {
                Text("No shifts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.horizontal, 8)
            } else {
                ForEach(shifts, id: \.id) { shift in
                    ShiftCard(
                        shift: shift,
                        assignments: vm.assignments(for: shift.id),
                        vm: vm,
                        isEditMode: vm.isEditMode,
                        isLocked: vm.isShiftLocked(shift),
                        onEdit: { requestSheet(.shiftEditor(shift)) },
                        isCompact: true
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .top)
    }
}

// MARK: - Day header

/// Minimalist, Apple-Calendar-style weekday header: left-justified title over a
/// thin underline whose color encodes time alignment (past / today / future).
/// Tapping anywhere on the header adds a shift to that day.
private struct DayHeader: View {
    let day: String
    let isToday: Bool
    let isPast: Bool
    let onAddShift: () -> Void

    var body: some View {
        Button(action: onAddShift) {
            HStack(spacing: 8) {
                Text(day)
                    .font(.headline)
                    .foregroundStyle(isPast ? .secondary : .primary)
                Spacer()
                Image(systemName: "plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(underlineColor)
                    .frame(height: isToday ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background)
        .accessibilityLabel("Add shift on \(day)")
    }

    /// Muted underline tint by time alignment: today accented, past gray,
    /// future faint.
    private var underlineColor: Color {
        if isToday { return .accentColor }
        if isPast { return .secondary.opacity(0.35) }
        return .secondary.opacity(0.15)
    }
}

// MARK: - Shift card

private struct ShiftCard: View {
    let shift: FfiShiftInfo
    let assignments: [FfiScheduleEntry]
    let vm: RotaViewModel
    let isEditMode: Bool
    let isLocked: Bool
    /// Tap-to-edit: opens the unified shift editor for this shift.
    let onEdit: () -> Void
    var isCompact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(shift.startTime) – \(shift.endTime)")
                        .font(.subheadline.bold())
                    RoleTag(name: shift.requiredRole)
                }
                Spacer()

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
                        shift: shift,
                        isEditMode: isEditMode,
                        isLocked: isLocked,
                        isCompact: isCompact
                    )
                }
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
        // Tapping anywhere not occupied by an inner control (swap name tags in
        // edit mode) opens the editor.
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shiftA11yLabel)
        .accessibilityAction(named: "Edit shift") { onEdit() }
    }

    private var shiftA11yLabel: String {
        let role = shift.requiredRole.isEmpty ? "any role" : shift.requiredRole
        let staffing = "\(assignments.count) of \(shift.maxEmployees) staffed"
        return "Shift \(shift.startTime) to \(shift.endTime), \(role), \(staffing)"
    }
}

// MARK: - Conflict glyph

/// Compact warning indicator shown next to a conflicted assignment in the grid.
/// Hard conflicts use an orange triangle; the soft `.maybe` hint uses an amber
/// question mark.
private struct ConflictGlyph: View {
    let reason: ConflictReason

    var body: some View {
        Image(systemName: reason.isHard ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(reason.isHard ? .orange : Color.yellow)
            .help(reason.label)
            .accessibilityLabel(reason.label)
    }
}

// MARK: - Assignment row

private struct AssignmentRow: View {
    let entry: FfiScheduleEntry
    let vm: RotaViewModel
    let shift: FfiShiftInfo
    let isEditMode: Bool
    let isLocked: Bool
    var isCompact: Bool = false

    private var isSwapSource: Bool { vm.isSwapSource(assignmentId: entry.assignmentId) }
    private var isSwapTarget: Bool { vm.isSwapTarget(entry: entry) }
    private var canEdit: Bool { isEditMode && !isLocked }
    private var conflict: ConflictReason? { vm.conflict(employeeId: entry.employeeId, shift: shift) }

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
        return HStack(spacing: 6) {
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

            if let conflict {
                ConflictGlyph(reason: conflict)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

}

// MARK: - Conflict badge (labeled)

/// Labeled conflict indicator used in the editor's assignment + picker lists.
private struct ConflictBadge: View {
    let reason: ConflictReason

    var body: some View {
        Label(reason.label, systemImage: reason.isHard ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(reason.isHard ? .orange : .secondary)
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - Role and staffing section

/// Editable "Role and staffing" form section shared by the shift editor, the
/// add-shift sheet, and the template editor. Min staff is clamped to the
/// role-derived floor (the largest role minimum); empty requirements mean a
/// wildcard shift.
struct RoleStaffingSection: View {
    let roles: [FfiRole]
    @Binding var minStaff: Int
    @Binding var maxStaff: Int
    @Binding var roleReqs: [FfiRoleRequirement]

    /// Largest single role minimum — the floor the overall min can't go below.
    private var floor: Int { roleReqs.map { Int($0.minCount) }.max() ?? 0 }
    private var effMin: Int { max(minStaff, floor) }
    private var availableRoles: [FfiRole] {
        let used = Set(roleReqs.map { $0.role })
        return roles.filter { !used.contains($0.name) }
    }

    var body: some View {
        Section {
            Stepper(
                value: Binding(get: { effMin }, set: { minStaff = $0 }),
                in: max(floor, 1)...99
            ) {
                HStack {
                    Text("Min staff")
                    Spacer()
                    Text("\(effMin)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Stepper(
                value: Binding(get: { max(maxStaff, effMin) }, set: { maxStaff = $0 }),
                in: effMin...99
            ) {
                HStack {
                    Text("Max staff")
                    Spacer()
                    Text("\(max(maxStaff, effMin))").foregroundStyle(.secondary).monospacedDigit()
                }
            }

            ForEach($roleReqs, id: \.role) { $req in
                Stepper(
                    value: Binding(
                        get: { Int(req.minCount) },
                        set: { $req.minCount.wrappedValue = UInt32(max(1, $0)) }
                    ),
                    in: 1...99
                ) {
                    HStack {
                        Text(req.role)
                        Spacer()
                        Text("min \(req.minCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        roleReqs.removeAll { $0.role == req.role }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }

            if !availableRoles.isEmpty {
                Menu {
                    ForEach(availableRoles, id: \.id) { role in
                        Button(role.name) {
                            roleReqs.append(FfiRoleRequirement(role: role.name, minCount: 1))
                        }
                    }
                } label: {
                    Label("Add role", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Role and staffing")
        } footer: {
            if roleReqs.isEmpty {
                Text("Any staff with availability can be assigned.")
            } else {
                Text("One person who holds several required roles covers each of them.")
            }
        }
    }
}

// MARK: - Unified shift editor sheet

/// Single editor for a shift: edit times, manage assigned employees (with
/// availability/overlap warnings), and delete the shift. Opened by tapping a
/// shift card. Replaces the former separate time-edit and employee-picker
/// sheets. Role/capacity are read-only here in this pass.
private struct ShiftEditorSheet: View {
    let vm: RotaViewModel
    let shift: FfiShiftInfo
    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var minStaff: Int
    @State private var maxStaff: Int
    @State private var roleReqs: [FfiRoleRequirement]
    @State private var showAddEmployee = false
    @State private var showDeleteConfirm = false

    init(vm: RotaViewModel, shift: FfiShiftInfo) {
        self.vm = vm
        self.shift = shift
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let base = Calendar.current.startOfDay(for: Date())
        _startDate = State(initialValue: fmt.date(from: shift.startTime) ?? base)
        _endDate = State(initialValue: fmt.date(from: shift.endTime) ?? base)
        _minStaff = State(initialValue: Int(shift.minEmployees))
        _maxStaff = State(initialValue: Int(shift.maxEmployees))
        _roleReqs = State(initialValue: shift.roleRequirements)
    }

    private var assignments: [FfiScheduleEntry] { vm.assignments(for: shift.id) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endDate, displayedComponents: .hourAndMinute)
                }

                RoleStaffingSection(
                    roles: vm.roles,
                    minStaff: $minStaff,
                    maxStaff: $maxStaff,
                    roleReqs: $roleReqs
                )

                Section("Assigned") {
                    if assignments.isEmpty {
                        Text("No one assigned")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(assignments, id: \.assignmentId) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.employeeName)
                                    if let conflict = vm.conflict(employeeId: entry.employeeId, shift: shift) {
                                        ConflictBadge(reason: conflict)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await vm.deleteAssignment(id: entry.assignmentId) }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(entry.employeeName)")
                            }
                        }
                    }
                    if assignments.count < Int(shift.maxEmployees) {
                        Button {
                            showAddEmployee = true
                        } label: {
                            Label("Add employee", systemImage: "plus.circle.fill")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete shift", systemImage: "trash")
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Edit Shift")
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
                        // Effective min is clamped to the role-derived floor.
                        let floor = roleReqs.map { Int($0.minCount) }.max() ?? 0
                        let effMin = max(minStaff, floor)
                        let effMax = max(maxStaff, effMin)
                        Task {
                            await vm.updateShiftTimes(id: shift.id, startTime: start, endTime: end)
                            await vm.updateShift(
                                id: shift.id,
                                minEmployees: UInt32(effMin),
                                maxEmployees: UInt32(effMax),
                                roleRequirements: roleReqs
                            )
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddEmployee) {
                AddEmployeePickerSheet(vm: vm, shift: shift)
            }
            .alert("Delete this shift?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        await vm.deleteShift(id: shift.id)
                        dismiss()
                    }
                }
            } message: {
                Text("This shift and all its assignments will be permanently deleted.")
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 440, minHeight: 360, idealHeight: 520)
        #endif
    }
}

// MARK: - Add employee picker sheet

/// Picker for adding an employee to a shift. Candidates that can't work the
/// shift (overlap / no availability / exception) show a warning but stay
/// tappable — the manager can assign anyway (warn but allow).
private struct AddEmployeePickerSheet: View {
    let vm: RotaViewModel
    let shift: FfiShiftInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let available = vm.availableEmployees(for: shift.id)
            Group {
                if available.isEmpty {
                    ContentUnavailableView(
                        "No Available Employees",
                        systemImage: "person.slash",
                        description: Text("Everyone is already assigned to this shift.")
                    )
                } else {
                    List(available, id: \.id) { employee in
                        Button {
                            Task {
                                await vm.addEmployeeToShift(shiftId: shift.id, employeeId: employee.id)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(employee.displayName)
                                Spacer()
                                if let conflict = vm.conflict(employeeId: employee.id, shift: shift) {
                                    ConflictBadge(reason: conflict)
                                }
                            }
                        }
                    }
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
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 400, minHeight: 300, idealHeight: 450)
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
    @State private var minStaff = 1
    @State private var maxStaff = 1
    @State private var roleReqs: [FfiRoleRequirement] = []

    private static func defaultTime(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
            ?? Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endDate, displayedComponents: .hourAndMinute)
                }
                RoleStaffingSection(
                    roles: vm.roles,
                    minStaff: $minStaff,
                    maxStaff: $maxStaff,
                    roleReqs: $roleReqs
                )
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
                        let floor = roleReqs.map { Int($0.minCount) }.max() ?? 0
                        let effMin = max(minStaff, floor)
                        let effMax = max(maxStaff, effMin)
                        Task {
                            await vm.createAdHocShift(
                                date: date, startTime: start,
                                endTime: end, requiredRole: "",
                                roleRequirements: roleReqs,
                                minEmployees: UInt32(effMin),
                                maxEmployees: UInt32(effMax)
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
