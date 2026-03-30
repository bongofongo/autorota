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
    @State private var showingTmplSheet = false
    @State private var editingTmplOverride: FfiShiftTemplateOverride? = nil

    private var employeeLookup: [Int64: String] {
        Dictionary(uniqueKeysWithValues: employeeVM.employees.map { ($0.id, $0.displayName) })
    }

    private var templateLookup: [Int64: String] {
        Dictionary(uniqueKeysWithValues: templateVM.templates.map { ($0.id, $0.name) })
    }

    var body: some View {
        NavigationStack {
            List {
                // Employee availability overrides
                Section {
                    ForEach(vm.employeeAvailabilityOverrides) { ovr in
                        Button { editingEmpOverride = ovr } label: {
                            EmpOverrideRow(ovr: ovr, employeeLookup: employeeLookup)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editingEmpOverride = ovr
                            } label: {
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
                    .onDelete { indexSet in
                        Task {
                            for idx in indexSet {
                                await vm.deleteEmployeeOverride(id: vm.employeeAvailabilityOverrides[idx].id)
                            }
                            await vm.loadAll()
                        }
                    }
                } header: {
                    HStack {
                        Text("Employee Availability")
                        Spacer()
                        Button { showingEmpSheet = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                    }
                }

                // Shift template overrides
                Section {
                    ForEach(vm.shiftTemplateOverrides) { ovr in
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
                                await vm.deleteTemplateOverride(id: vm.shiftTemplateOverrides[idx].id)
                            }
                            await vm.loadAll()
                        }
                    }
                } header: {
                    HStack {
                        Text("Shifts")
                        Spacer()
                        Button { showingTmplSheet = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Overrides")
            .task {
                await vm.loadAll()
                await employeeVM.load()
                await templateVM.load()
            }
            .sheet(isPresented: $showingEmpSheet, onDismiss: { Task { await vm.loadAll() } }) {
                EmployeeAvailabilityOverrideSheet(vm: vm, employees: employeeVM.employees, existing: nil)
            }
            .sheet(item: $editingEmpOverride, onDismiss: { Task { await vm.loadAll() } }) { ovr in
                EmployeeAvailabilityOverrideSheet(vm: vm, employees: employeeVM.employees, existing: ovr)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(templateLookup[ovr.templateId] ?? "Template #\(ovr.templateId)")
                    .fontWeight(.medium)
                if ovr.cancelled {
                    Text("CANCELLED")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(ovr.date).font(.subheadline).foregroundStyle(.secondary)
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
    var preselectedEmployeeId: Int64? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selectedEmployeeId: Int64?
    @State private var date = Date()
    @State private var slots: [AvailabilitySlot] = []
    @State private var notes = ""
    @State private var selectionModeActive = false

    // Date range state (create-only)
    @State private var isDateRange = false
    @State private var endDate: Date = Calendar.current.date(byAdding: .day, value: 6, to: Date()) ?? Date()
    @State private var slotsByDate: [String: [AvailabilitySlot]] = [:]
    @State private var currentDateIndex = 0

    private var isEditing: Bool { existing != nil }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

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
        let end = cal.startOfDay(for: endDate > date ? endDate : date)
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
        (6...21).map { AvailabilitySlot(weekday: weekday, hour: UInt8($0), state: "No") }
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
                        Toggle("Date Range", isOn: $isDateRange.animation())
                            .onChange(of: isDateRange) { _, _ in currentDateIndex = 0 }
                    }
                    DatePicker(isDateRange ? "Start" : "Date",
                               selection: $date, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .onChange(of: date) { _, _ in
                            currentDateIndex = min(currentDateIndex, max(0, datesInRange.count - 1))
                        }
                    if isDateRange {
                        DatePicker("End", selection: $endDate, displayedComponents: .date)
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
            }
            .scrollDisabled(selectionModeActive)
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(isEditing ? "Edit Override" : "New Override")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(selectedEmployeeId == nil)
                }
            }
            .onAppear { prefill() }
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
                onSelectionModeChange: { selectionModeActive = $0 }
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

                Spacer()

                VStack(spacing: 2) {
                    Text(Self.displayFmt.string(from: currentRangeDate))
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
                onSelectionModeChange: { selectionModeActive = $0 }
            )
        } header: {
            Text("Availability for \(currentWeekday)")
        }
    }

    // MARK: - Prefill / Save

    private func prefill() {
        if let preId = preselectedEmployeeId { selectedEmployeeId = preId }
        guard let ovr = existing else { return }
        selectedEmployeeId = ovr.employeeId
        let parsedDate = Self.dateFmt.date(from: ovr.date) ?? Date()
        date = parsedDate
        let wd = weekday(for: parsedDate)
        slots = ovr.availability.map { AvailabilitySlot(weekday: wd, hour: $0.hour, state: $0.state) }
        notes = ovr.notes ?? ""
    }

    private func save() {
        guard let empId = selectedEmployeeId else { return }

        if isDateRange {
            Task {
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
                        notes: notes.isEmpty ? nil : notes
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
                notes: notes.isEmpty ? nil : notes
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

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    Picker("Template", selection: $selectedTemplateId) {
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
                Section("Override") {
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
            .navigationTitle(isEditing ? "Edit Override" : "New Override")
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
