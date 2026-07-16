import SwiftUI
import AutorotaKit

// MARK: - Identifiable conformance for sheet(item:)

extension FfiEmployeeAvailabilityOverride: @retroactive Identifiable {}
extension FfiShiftTemplateOverride: @retroactive Identifiable {}

// MARK: - Main tab view

struct OverridesTabView: View {

    @State private var vm = OverrideViewModel()
    @State private var employeeVM = EmployeeViewModel()
    @State private var templateVM = ShiftTemplateViewModel()
    @State private var showingEmpSheet = false
    @State private var editingEmpOverride: FfiEmployeeAvailabilityOverride? = nil
    @State private var editingEmpGroup: EmpOverrideGroup? = nil
    @State private var showingTmplSheet = false
    @State private var editingTmplOverride: FfiShiftTemplateOverride? = nil
    @State private var empViewMode: EmpViewMode = .allByDate
    @State private var expandedEmployees: Set<Int64> = []
    @State private var expandedGroups: Set<String> = []
    @Environment(\.accessibilityPalette) private var palette
    @Environment(\.isMenuPushed) private var isMenuPushed

    enum EmpViewMode: String, CaseIterable, Identifiable {
        case allByDate = "All · Soonest Date"
        case singleByDate = "Single Days · Soonest Date"
        case rangeByDate = "Date Ranges · Soonest Date"
        case allByEmployee = "All · By Employee"
        case singleByEmployee = "Single Days · By Employee"
        case rangeByEmployee = "Date Ranges · By Employee"
        var id: String { rawValue }
    }

    /// A contiguous run of overrides for the same employee on consecutive calendar days.
    struct EmpOverrideGroup: Identifiable {
        let items: [FfiEmployeeAvailabilityOverride]  // sorted by date
        var id: String { "\(items.first?.employeeId ?? 0)-\(items.first?.date ?? "")-\(items.count)" }
        var isRange: Bool { items.count > 1 }
        var employeeId: Int64 { items.first?.employeeId ?? 0 }
        var startDate: String { items.first?.date ?? "" }
        var endDate: String { items.last?.date ?? "" }
    }

    private static let isoFmt = AvailabilityWeekMath.isoFmt

    private var todayIso: String { AvailabilityWeekMath.isoFmt.string(from: Date()) }

    private func isPast(_ group: EmpOverrideGroup) -> Bool {
        (group.isRange ? group.endDate : group.startDate) < todayIso
    }

    private var employeeOverrideGroups: [EmpOverrideGroup] {
        // Exceptions tab shows only user-classified exception rows.
        // Manual per-date edits (made via the availability grid) still live
        // in the same table but are not exceptions and must not appear here.
        let exceptionsOnly = vm.employeeAvailabilityOverrides.filter { $0.source == "exception" }
        // Group by employee, then split into runs of consecutive days.
        let byEmp = Dictionary(grouping: exceptionsOnly, by: { $0.employeeId })
        var groups: [EmpOverrideGroup] = []
        let cal = Calendar(identifier: .iso8601)
        for (_, list) in byEmp {
            let sorted = list.sorted { $0.date < $1.date }
            var run: [FfiEmployeeAvailabilityOverride] = []
            for ovr in sorted {
                if let last = run.last,
                   let lastDate = Self.isoFmt.date(from: last.date),
                   let thisDate = Self.isoFmt.date(from: ovr.date),
                   let next = cal.date(byAdding: .day, value: 1, to: lastDate),
                   cal.isDate(next, inSameDayAs: thisDate) {
                    run.append(ovr)
                } else {
                    if !run.isEmpty { groups.append(EmpOverrideGroup(items: run)) }
                    run = [ovr]
                }
            }
            if !run.isEmpty { groups.append(EmpOverrideGroup(items: run)) }
        }
        return groups.sorted { $0.startDate < $1.startDate }
    }

    private var filteredEmpGroups: [EmpOverrideGroup] {
        let all = employeeOverrideGroups
        let filtered: [EmpOverrideGroup]
        switch empViewMode {
        case .allByDate, .allByEmployee: filtered = all
        case .singleByDate, .singleByEmployee: filtered = all.filter { !$0.isRange }
        case .rangeByDate, .rangeByEmployee: filtered = all.filter { $0.isRange }
        }
        if isByEmployee {
            let lookup = employeeLookup
            return filtered.sorted {
                let name0 = lookup[$0.employeeId] ?? ""
                let name1 = lookup[$1.employeeId] ?? ""
                if name0 != name1 { return name0.localizedCaseInsensitiveCompare(name1) == .orderedAscending }
                return $0.startDate < $1.startDate
            }
        }
        return filtered
    }

    private var isByEmployee: Bool {
        switch empViewMode {
        case .allByEmployee, .singleByEmployee, .rangeByEmployee: return true
        default: return false
        }
    }

    private var upcomingEmpGroups: [EmpOverrideGroup] {
        filteredEmpGroups.filter { !isPast($0) }
    }

    private var pastEmpGroups: [EmpOverrideGroup] {
        filteredEmpGroups.filter { isPast($0) }.sorted { $0.startDate > $1.startDate }
    }

    private func groupByEmployee(
        _ groups: [EmpOverrideGroup], descending: Bool = false
    ) -> [(employeeId: Int64, name: String, groups: [EmpOverrideGroup])] {
        let lookup = employeeLookup
        let byEmp = Dictionary(grouping: groups, by: { $0.employeeId })
        return byEmp.map { (id, groups) in
            let sorted = groups.sorted {
                descending ? $0.startDate > $1.startDate : $0.startDate < $1.startDate
            }
            return (employeeId: id, name: lookup[id] ?? "Employee #\(id)", groups: sorted)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var groupedByEmployee: [(employeeId: Int64, name: String, groups: [EmpOverrideGroup])] {
        groupByEmployee(upcomingEmpGroups)
    }

    private var groupedByEmployeePast: [(employeeId: Int64, name: String, groups: [EmpOverrideGroup])] {
        groupByEmployee(pastEmpGroups, descending: true)
    }

    private var employeeLookup: [Int64: String] {
        Dictionary(uniqueKeysWithValues: employeeVM.employees.map { ($0.id, $0.displayName) })
    }

    private var templateLookup: [Int64: String] {
        Dictionary(uniqueKeysWithValues: templateVM.templates.map { ($0.id, $0.name) })
    }

    private func availabilityColor(for slots: [DayAvailabilitySlot]) -> Color {
        palette.availabilityColor(forSlots: slots)
    }

    private var upcomingTmplOverrides: [FfiShiftTemplateOverride] {
        vm.shiftTemplateOverrides.filter { $0.date >= todayIso }.sorted { $0.date < $1.date }
    }

    private var pastTmplOverrides: [FfiShiftTemplateOverride] {
        vm.shiftTemplateOverrides.filter { $0.date < todayIso }.sorted { $0.date > $1.date }
    }

    @ViewBuilder
    private func employeeDisclosureGroup(
        _ entry: (employeeId: Int64, name: String, groups: [EmpOverrideGroup])
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedEmployees.contains(entry.employeeId) },
                set: { isExpanded in
                    if isExpanded { expandedEmployees.insert(entry.employeeId) }
                    else { expandedEmployees.remove(entry.employeeId) }
                }
            )
        ) {
            ForEach(entry.groups) { group in
                empOverrideGroupButton(group: group)
            }
        } label: {
            HStack {
                Text(entry.name).fontWeight(.medium)
                Spacer()
                Text("\(entry.groups.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func tmplOverrideRows(_ overrides: [FfiShiftTemplateOverride]) -> some View {
        ForEach(overrides) { ovr in
            Button { editingTmplOverride = ovr } label: {
                TmplOverrideRow(ovr: ovr, templateLookup: templateLookup)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    editingTmplOverride = ovr
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task {
                        await vm.deleteTemplateOverride(id: ovr.id)
                        await vm.loadAll()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .onDelete { indexSet in
            Task {
                for idx in indexSet {
                    await vm.deleteTemplateOverride(id: overrides[idx].id)
                }
                await vm.loadAll()
            }
        }
    }

    @ViewBuilder
    private func empOverrideGroupButton(group: EmpOverrideGroup) -> some View {
        if group.isRange {
            // Manual disclosure: tapping the row edits the whole range, while
            // the trailing chevron expands the group for per-day editing.
            let isExpanded = expandedGroups.contains(group.id)
            HStack(spacing: 8) {
                Button { editingEmpGroup = group } label: {
                    EmpOverrideGroupRow(group: group, employeeLookup: employeeLookup)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    if isExpanded { expandedGroups.remove(group.id) }
                    else { expandedGroups.insert(group.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse days" : "Expand days")
            }
            .contextMenu {
                Button { editingEmpGroup = group } label: {
                    Label("Edit Exception", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task {
                        for ovr in group.items {
                            await vm.deleteEmployeeOverride(id: ovr.id)
                        }
                        await vm.loadAll()
                    }
                } label: {
                    Label("Delete All (\(group.items.count))", systemImage: "trash")
                }
            }

            if isExpanded {
                ForEach(group.items) { ovr in
                    Button { editingEmpOverride = ovr } label: {
                        EmpOverrideDayRow(ovr: ovr, color: availabilityColor(for: ovr.availability))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { editingEmpOverride = ovr } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            Task {
                                await vm.deleteEmployeeOverride(id: ovr.id)
                                await vm.loadAll()
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } else {
            Button {
                if let first = group.items.first { editingEmpOverride = first }
            } label: {
                EmpOverrideGroupRow(group: group, employeeLookup: employeeLookup)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let first = group.items.first {
                    Button {
                        editingEmpOverride = first
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                Button(role: .destructive) {
                    Task {
                        for ovr in group.items {
                            await vm.deleteEmployeeOverride(id: ovr.id)
                        }
                        await vm.loadAll()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    var body: some View {
        OptionalNavigationStack(embed: !isMenuPushed) {
            List {
                // Employee availability overrides
                Section {
                    Picker("View", selection: $empViewMode) {
                        ForEach(EmpViewMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    HStack {
                        Text("Employee Exceptions")
                        Spacer()
                        Button { showingEmpSheet = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add employee exception")
                    }
                }

                if isByEmployee {
                    let grouped = groupedByEmployee
                    if grouped.isEmpty {
                        Section {
                            Text("No exceptions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(grouped, id: \.employeeId) { entry in
                            Section {
                                employeeDisclosureGroup(entry)
                            }
                        }
                    }
                } else {
                    Section {
                        let groups = upcomingEmpGroups
                        if groups.isEmpty {
                            Text("No exceptions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(groups) { group in
                                empOverrideGroupButton(group: group)
                            }
                        }
                    }
                }

                if isByEmployee {
                    let pastGrouped = groupedByEmployeePast
                    if !pastGrouped.isEmpty {
                        Section("Past") {
                            ForEach(pastGrouped, id: \.employeeId) { entry in
                                employeeDisclosureGroup(entry)
                            }
                        }
                    }
                } else if !pastEmpGroups.isEmpty {
                    Section("Past") {
                        ForEach(pastEmpGroups) { group in
                            empOverrideGroupButton(group: group)
                        }
                    }
                }

                // Shift template overrides
                Section {
                    tmplOverrideRows(upcomingTmplOverrides)
                } header: {
                    HStack {
                        Text("Shift Changes")
                        Spacer()
                        Button { showingTmplSheet = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add shift change")
                    }
                }

                if !pastTmplOverrides.isEmpty {
                    Section("Past") {
                        tmplOverrideRows(pastTmplOverrides)
                    }
                }
            }
            .navigationTitle("Exceptions")
            .errorAlert($vm.error)
            .task {
                await vm.loadAll()
                await employeeVM.reload()
                await templateVM.load()
            }
            .sheet(isPresented: $showingEmpSheet, onDismiss: { Task { await vm.loadAll() } }) {
                EmployeeAvailabilityOverrideSheet(vm: vm, employees: employeeVM.employees, existing: nil)
            }
            .sheet(item: $editingEmpOverride, onDismiss: { Task { await vm.loadAll() } }) { ovr in
                EmployeeAvailabilityOverrideSheet(vm: vm, employees: employeeVM.employees, existing: ovr)
            }
            .sheet(item: $editingEmpGroup, onDismiss: { Task { await vm.loadAll() } }) { group in
                EmployeeAvailabilityOverrideSheet(
                    vm: vm,
                    employees: employeeVM.employees,
                    existing: nil,
                    existingRange: group.items
                )
            }
            .sheet(isPresented: $showingTmplSheet, onDismiss: { Task { await vm.loadAll() } }) {
                ShiftTemplateOverrideSheet(vm: vm, templates: templateVM.templates, existing: nil)
            }
            .sheet(item: $editingTmplOverride, onDismiss: { Task { await vm.loadAll() } }) { ovr in
                ShiftTemplateOverrideSheet(vm: vm, templates: templateVM.templates, existing: ovr)
            }
        }
    }
}

// MARK: - Row helpers

private struct EmpOverrideGroupRow: View {
    let group: OverridesTabView.EmpOverrideGroup
    let employeeLookup: [Int64: String]

    private static let isoFmt = AvailabilityWeekMath.isoFmt

    private func pretty(_ iso: String) -> String {
        guard let d = Self.isoFmt.date(from: iso) else { return iso }
        return AvailabilityWeekMath.displayFmt.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(employeeLookup[group.employeeId] ?? "Employee #\(group.employeeId)")
                    .fontWeight(.medium)
                if group.isRange {
                    Text("RANGE · \(group.items.count) days")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
                Spacer()
                Text(group.isRange
                     ? "\(pretty(group.startDate)) – \(pretty(group.endDate))"
                     : pretty(group.startDate))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let notes = group.items.first?.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct EmpOverrideDayRow: View {
    let ovr: FfiEmployeeAvailabilityOverride
    let color: Color

    private static let isoFmt = AvailabilityWeekMath.isoFmt

    private var pretty: String {
        guard let d = Self.isoFmt.date(from: ovr.date) else { return ovr.date }
        return AvailabilityWeekMath.displayFmt.string(from: d)
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(pretty)
                .font(.subheadline)
            Spacer()
            if let notes = ovr.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct EmpOverrideRow: View {
    let ovr: FfiEmployeeAvailabilityOverride
    let employeeLookup: [Int64: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(employeeLookup[ovr.employeeId] ?? "Employee #\(ovr.employeeId)")
                    .fontWeight(.medium)
                Spacer()
                Text(ovr.date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let notes = ovr.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct TmplOverrideRow: View {
    let ovr: FfiShiftTemplateOverride
    let templateLookup: [Int64: String]

    private var pretty: String {
        guard let d = AvailabilityWeekMath.isoFmt.date(from: ovr.date) else { return ovr.date }
        return AvailabilityWeekMath.displayFmt.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(templateLookup[ovr.templateId] ?? "Shift #\(ovr.templateId)")
                    .fontWeight(.medium)
                if ovr.cancelled {
                    Text("CANCELLED")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(pretty).font(.subheadline).foregroundStyle(.secondary)
            }
            if !ovr.cancelled {
                HStack(spacing: 6) {
                    if let st = ovr.startTime { Text(st).font(.caption).foregroundStyle(.secondary) }
                    if ovr.startTime != nil && ovr.endTime != nil {
                        Text("–").font(.caption).foregroundStyle(.secondary)
                    }
                    if let et = ovr.endTime { Text(et).font(.caption).foregroundStyle(.secondary) }
                    if let mn = ovr.minEmployees {
                        Text("min:\(mn)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let mx = ovr.maxEmployees {
                        Text("max:\(mx)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let notes = ovr.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Employee availability override sheet

struct EmployeeAvailabilityOverrideSheet: View {

    let vm: OverrideViewModel
    let employees: [FfiEmployee]
    var existing: FfiEmployeeAvailabilityOverride?
    /// When set, the sheet edits a whole date-range exception: every per-day
    /// override row in the range (sorted by date). Mutually exclusive with
    /// `existing` (single-day edit).
    var existingRange: [FfiEmployeeAvailabilityOverride]? = nil
    var preselectedEmployeeId: Int64? = nil
    var preselectedStartDate: Date? = nil
    var preselectedEndDate: Date? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedEmployeeId: Int64?
    @State private var date = Date()
    @State private var slots: [AvailabilitySlot] = []
    @State private var notes = ""

    // Date range state (create-only)
    @State private var isDateRange = false
    @State private var endDate: Date = Date()
    @State private var slotsByDate: [String: [AvailabilitySlot]] = [:]
    @State private var currentDateIndex = 0
    @State private var showLongRangeWarning = false
    @State private var showDeleteConfirmation = false
    /// Sticky lasso toggle is on in a grid — pauses Form scrolling.
    @State private var gridLassoActive = false

    private static let softMaxDaysInRange = 84  // 12 weeks

    private var isEditing: Bool { existing != nil || existingRange != nil }

    private static let dateFmt = AvailabilityWeekMath.isoFmt

    private func weekday(for d: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let idx = cal.component(.weekday, from: d)
        let map: [Int: String] = [2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat", 1: "Sun"]
        return map[idx] ?? "Mon"
    }

    private var weekdayForDate: String { weekday(for: date) }

    private var datesInRange: [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.startOfDay(for: endDate)
        var result: [Date] = []
        var current = start
        while current <= end {
            result.append(current)
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return result
    }

    private var currentRangeDate: Date {
        let dates = datesInRange
        guard currentDateIndex < dates.count else { return date }
        return dates[currentDateIndex]
    }

    private var currentWeekday: String { weekday(for: currentRangeDate) }

    private var currentSlots: [AvailabilitySlot] {
        isDateRange ? (slotsByDate[Self.dateFmt.string(from: currentRangeDate)] ?? []) : slots
    }

    private func setCurrentSlots(_ newSlots: [AvailabilitySlot]) {
        if isDateRange {
            slotsByDate[Self.dateFmt.string(from: currentRangeDate)] = newSlots
        } else {
            slots = newSlots
        }
    }

    private func notAvailableSlots(for weekday: String) -> [AvailabilitySlot] {
        (0...23).map { AvailabilitySlot(weekday: weekday, hour: UInt8($0), state: "No") }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Employee") {
                    Picker("Employee", selection: $selectedEmployeeId) {
                        Text("Select…").tag(Optional<Int64>(nil))
                        ForEach(employees, id: \.id) { emp in
                            Text(emp.displayName).tag(Optional(emp.id))
                        }
                    }
                }

                Section("Date") {
                    if !isEditing {
                        Toggle("Date Range", isOn: reduceMotion ? $isDateRange : $isDateRange.animation())
                            .onChange(of: isDateRange) { _, newVal in
                                currentDateIndex = 0
                                if newVal {
                                    // Entering range mode — seed start date's slots from the
                                    // single-day buffer so they aren't silently discarded.
                                    let key = Self.dateFmt.string(from: date)
                                    if slotsByDate[key] == nil, !slots.isEmpty {
                                        slotsByDate[key] = slots
                                    }
                                } else {
                                    // Leaving range mode — pull the anchor date's slots back
                                    // into the single-day buffer so the user doesn't lose edits.
                                    let key = Self.dateFmt.string(from: date)
                                    slots = slotsByDate[key] ?? slots
                                }
                            }
                    }
                    DatePicker(isDateRange ? "Start" : "Date",
                               selection: $date, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .onChange(of: date) { _, newDate in
                            if endDate < newDate { endDate = newDate }
                            currentDateIndex = min(currentDateIndex, max(0, datesInRange.count - 1))
                        }
                    if isDateRange {
                        DatePicker("End", selection: $endDate, in: date..., displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .onChange(of: endDate) { _, _ in
                                currentDateIndex = min(currentDateIndex, max(0, datesInRange.count - 1))
                            }
                    }
                }

                if isDateRange {
                    rangeDateSection
                } else {
                    singleDateSection
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Exception", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(isEditing ? "Edit Exception" : "New Exception")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave() }
                        .disabled(selectedEmployeeId == nil)
                }
            }
            .onAppear { prefill() }
            .scrollDisabled(gridLassoActive)
            .onChange(of: isDateRange) { _, _ in
                // Section swap unmounts the toggled grid; never leave
                // scrolling stuck off.
                gridLassoActive = false
            }
            .alert("Long date range", isPresented: $showLongRangeWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Save anyway") { save() }
            } message: {
                Text("This exception covers \(datesInRange.count) days (more than \(Self.softMaxDaysInRange / 7) weeks). Long ranges can be hard to manage — are you sure?")
            }
            .alert("Delete exception?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteExisting() }
            } message: {
                Text("This exception will be removed. The employee's default availability applies on that date.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 500, idealHeight: 650)
        #endif
    }

    // MARK: - Single date section

    @ViewBuilder private var singleDateSection: some View {
        Section("Availability for \(weekdayForDate)") {
            Button {
                slots = notAvailableSlots(for: weekdayForDate)
            } label: {
                Label("Mark as Not Available", systemImage: "person.slash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            AvailabilityGridView(
                slots: slots,
                isEditable: true,
                visibleHourStart: 6,
                visibleHourEnd: 22,
                limitToWeekdays: [weekdayForDate],
                onChange: { slots = $0 },
                onLassoModeChange: { gridLassoActive = $0 }
            )
        }
    }

    // MARK: - Range date section

    @ViewBuilder private var rangeDateSection: some View {
        let dates = datesInRange
        Section {
            // Day navigation
            HStack {
                Button {
                    if currentDateIndex > 0 { currentDateIndex -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(currentDateIndex == 0)
                .accessibilityLabel("Previous day")

                Spacer()

                VStack(spacing: 2) {
                    Text(AvailabilityWeekMath.displayFmt.string(from: currentRangeDate))
                        .fontWeight(.medium)
                    Text("\(currentDateIndex + 1) of \(dates.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    if currentDateIndex < dates.count - 1 { currentDateIndex += 1 }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(currentDateIndex == dates.count - 1)
                .accessibilityLabel("Next day")
            }

            // Not available presets
            Button {
                setCurrentSlots(notAvailableSlots(for: currentWeekday))
            } label: {
                Label("Not Available (this date)", systemImage: "person.slash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            Button {
                for d in datesInRange {
                    slotsByDate[Self.dateFmt.string(from: d)] = notAvailableSlots(for: weekday(for: d))
                }
            } label: {
                Label("Not Available (all \(dates.count) dates)", systemImage: "person.2.slash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            // Grid for current date
            AvailabilityGridView(
                slots: currentSlots,
                isEditable: true,
                visibleHourStart: 6,
                visibleHourEnd: 22,
                limitToWeekdays: [currentWeekday],
                onChange: { setCurrentSlots($0) },
                onLassoModeChange: { gridLassoActive = $0 }
            )
        } header: {
            Text("Availability for \(currentWeekday)")
        }
    }

    // MARK: - Prefill / Save

    private func prefill() {
        if let preId = preselectedEmployeeId { selectedEmployeeId = preId }
        if let start = preselectedStartDate {
            date = start
            if let end = preselectedEndDate, end > start {
                endDate = end
                isDateRange = true
            }
        }

        // Editing a whole date-range exception: seed the range bounds and the
        // per-day grid buffer from every existing override row.
        if let range = existingRange, let first = range.first, let last = range.last {
            selectedEmployeeId = first.employeeId
            isDateRange = true
            date = Self.dateFmt.date(from: first.date) ?? Date()
            endDate = Self.dateFmt.date(from: last.date) ?? date
            for ovr in range {
                guard let d = Self.dateFmt.date(from: ovr.date) else { continue }
                let wd = weekday(for: d)
                slotsByDate[ovr.date] = ovr.availability.map {
                    AvailabilitySlot(weekday: wd, hour: $0.hour, state: $0.state)
                }
            }
            notes = first.notes ?? ""
            return
        }

        guard let ovr = existing else { return }
        selectedEmployeeId = ovr.employeeId
        let parsedDate = Self.dateFmt.date(from: ovr.date) ?? Date()
        date = parsedDate
        let wd = weekday(for: parsedDate)
        slots = ovr.availability.map { AvailabilitySlot(weekday: wd, hour: $0.hour, state: $0.state) }
        notes = ovr.notes ?? ""
    }

    private func attemptSave() {
        if isDateRange && datesInRange.count > Self.softMaxDaysInRange {
            showLongRangeWarning = true
        } else {
            save()
        }
    }

    private func deleteExisting() {
        if let range = existingRange {
            Task {
                for ovr in range {
                    await vm.deleteEmployeeOverride(id: ovr.id)
                }
                dismiss()
            }
            return
        }
        guard let ovr = existing else { return }
        Task {
            await vm.deleteEmployeeOverride(id: ovr.id)
            dismiss()
        }
    }

    private func save() {
        guard let empId = selectedEmployeeId else { return }

        if isDateRange {
            let keptDates = Set(datesInRange.map { Self.dateFmt.string(from: $0) })
            Task {
                // When editing a range, delete original days dropped from the
                // new span (the upsert below can't remove rows, only add/update).
                for ovr in existingRange ?? [] where !keptDates.contains(ovr.date) {
                    await vm.deleteEmployeeOverride(id: ovr.id)
                }
                for d in datesInRange {
                    let wd = weekday(for: d)
                    let key = Self.dateFmt.string(from: d)
                    let daySlots = (slotsByDate[key] ?? [])
                        .filter { $0.weekday == wd }
                        .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
                    let ovr = FfiEmployeeAvailabilityOverride(
                        id: 0,
                        employeeId: empId,
                        date: key,
                        availability: daySlots,
                        notes: notes.isEmpty ? nil : notes,
                        source: "exception"
                    )
                    await vm.upsertEmployeeOverride(ovr)
                }
                dismiss()
            }
        } else {
            let wd = weekdayForDate
            let daySlots = slots
                .filter { $0.weekday == wd }
                .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
            let ovr = FfiEmployeeAvailabilityOverride(
                id: existing?.id ?? 0,
                employeeId: empId,
                date: Self.dateFmt.string(from: date),
                availability: daySlots,
                notes: notes.isEmpty ? nil : notes,
                source: "exception"
            )
            Task {
                await vm.upsertEmployeeOverride(ovr)
                dismiss()
            }
        }
    }
}

// MARK: - Shift template override sheet

struct ShiftTemplateOverrideSheet: View {

    let vm: OverrideViewModel
    let templates: [FfiShiftTemplate]
    var existing: FfiShiftTemplateOverride?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplateId: Int64?
    @State private var date = Date()
    @State private var cancelled = false
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var useCustomStart = false
    @State private var useCustomEnd = false
    @State private var minEmployees = 1
    @State private var maxEmployees = 3
    @State private var useCustomMin = false
    @State private var useCustomMax = false
    @State private var notes = ""

    private var isEditing: Bool { existing != nil }

    private static let timeFmt = AvailabilityWeekMath.timeFmt

    private static let dateFmt = AvailabilityWeekMath.isoFmt

    var body: some View {
        NavigationStack {
            Form {
                Section("Shift") {
                    Picker("Shift", selection: $selectedTemplateId) {
                        Text("Select…").tag(Optional<Int64>(nil))
                        ForEach(templates, id: \.id) { t in
                            Text(t.name).tag(Optional(t.id))
                        }
                    }
                }
                Section("Date") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.compact)
                }
                Section("Changes") {
                    Toggle("Cancel this shift", isOn: $cancelled)
                    if !cancelled {
                        Toggle("Custom start time", isOn: $useCustomStart)
                        if useCustomStart {
                            DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                        }
                        Toggle("Custom end time", isOn: $useCustomEnd)
                        if useCustomEnd {
                            DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                        }
                        Toggle("Custom min staff", isOn: $useCustomMin)
                        if useCustomMin {
                            Stepper("Min: \(minEmployees)", value: $minEmployees, in: 1...20)
                        }
                        Toggle("Custom max staff", isOn: $useCustomMax)
                        if useCustomMax {
                            Stepper("Max: \(maxEmployees)", value: $maxEmployees, in: 1...20)
                        }
                    }
                }
                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(isEditing ? "Edit Shift Change" : "New Shift Change")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(selectedTemplateId == nil)
                }
            }
            .onAppear { prefill() }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 520)
        #endif
    }

    private func prefill() {
        guard let ovr = existing else { return }
        selectedTemplateId = ovr.templateId
        date = Self.dateFmt.date(from: ovr.date) ?? Date()
        cancelled = ovr.cancelled
        if let st = ovr.startTime, let d = Self.timeFmt.date(from: st) {
            startTime = d; useCustomStart = true
        }
        if let et = ovr.endTime, let d = Self.timeFmt.date(from: et) {
            endTime = d; useCustomEnd = true
        }
        if let mn = ovr.minEmployees { minEmployees = Int(mn); useCustomMin = true }
        if let mx = ovr.maxEmployees { maxEmployees = Int(mx); useCustomMax = true }
        notes = ovr.notes ?? ""
    }

    private func save() {
        guard let tmplId = selectedTemplateId else { return }
        let ovr = FfiShiftTemplateOverride(
            id: existing?.id ?? 0,
            templateId: tmplId,
            date: Self.dateFmt.string(from: date),
            cancelled: cancelled,
            startTime: useCustomStart && !cancelled ? Self.timeFmt.string(from: startTime) : nil,
            endTime: useCustomEnd && !cancelled ? Self.timeFmt.string(from: endTime) : nil,
            minEmployees: useCustomMin && !cancelled ? UInt32(minEmployees) : nil,
            maxEmployees: useCustomMax && !cancelled ? UInt32(maxEmployees) : nil,
            notes: notes.isEmpty ? nil : notes
        )
        Task {
            await vm.upsertTemplateOverride(ovr)
            dismiss()
        }
    }
}
