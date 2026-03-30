import SwiftUI
import AutorotaKit

struct EmployeeDetailView: View {

    let employee: FfiEmployee
    let viewModel: EmployeeViewModel

    @AppStorage("appCurrency") private var displayCurrency: String = AppCurrency.usd.rawValue
    @Environment(ExchangeRateService.self) private var exchangeRates
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditSheet = false
    @State private var overrideVM = OverrideViewModel()
    @State private var showingAddOverride = false
    @State private var editingOverride: FfiEmployeeAvailabilityOverride? = nil

    var body: some View {
        List {
            Section("Details") {
                HStack(alignment: .center, spacing: 6) {
                    Text("Roles").foregroundStyle(.secondary)
                    Spacer()
                    if employee.roles.isEmpty {
                        Text("None").foregroundStyle(.tertiary).font(.subheadline)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(employee.roles, id: \.self) { RoleTag(name: $0) }
                        }
                    }
                }
                LabeledContent("Target hours/week",
                    value: "\(String(format: "%.1f", employee.targetWeeklyHours)) ± \(String(format: "%.1f", employee.weeklyHoursDeviation))h")
                LabeledContent("Max daily hours", value: String(format: "%.1f", employee.maxDailyHours))
                if let wage = employee.hourlyWage {
                    let from = employee.wageCurrency ?? displayCurrency
                    let converted = exchangeRates.convert(wage, from: from, to: displayCurrency)
                    let sym = exchangeRates.symbol(for: displayCurrency)
                    LabeledContent("Hourly wage", value: String(format: "%@%.2f", sym, converted))
                }
            }

            if let notes = employee.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }

            Section("Next Week's Availability") {
                let range = AvailabilityGridView.inferredVisibleRange(from: employee.availability)
                AvailabilityGridView(
                    slots: employee.availability,
                    isEditable: false,
                    visibleHourStart: range.start,
                    visibleHourEnd: range.end
                )
            }

            Section("Analytics") {
                NavigationLink {
                    EmployeeShiftHistoryView(
                        employeeId: employee.id,
                        targetWeeklyHours: employee.targetWeeklyHours,
                        hourlyWage: employee.hourlyWage,
                        wageCurrency: employee.wageCurrency
                    )
                } label: {
                    Label("View Analytics", systemImage: "chart.bar.xaxis")
                }
            }

            Section("Date Overrides") {
                if overrideVM.isLoading {
                    ProgressView()
                } else {
                    ForEach(overrideVM.employeeAvailabilityOverrides) { ovr in
                        Button { editingOverride = ovr } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ovr.date).fontWeight(.medium)
                                if let notes = ovr.notes, !notes.isEmpty {
                                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editingOverride = ovr
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                Task {
                                    await overrideVM.deleteEmployeeOverride(id: ovr.id)
                                    await overrideVM.loadForEmployee(id: employee.id)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        Task {
                            for idx in indexSet {
                                await overrideVM.deleteEmployeeOverride(
                                    id: overrideVM.employeeAvailabilityOverrides[idx].id)
                            }
                            await overrideVM.loadForEmployee(id: employee.id)
                        }
                    }
                    Button("Add Date Override") { showingAddOverride = true }
                        .foregroundStyle(.tint)
                }
            }
        }
        .navigationTitle(employee.displayName)
        .task { await overrideVM.loadForEmployee(id: employee.id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEditSheet = true }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            EmployeeEditSheet(viewModel: viewModel, existing: employee, onDelete: { dismiss() })
        }
        .sheet(isPresented: $showingAddOverride, onDismiss: { Task { await overrideVM.loadForEmployee(id: employee.id) } }) {
            EmployeeAvailabilityOverrideSheet(
                vm: overrideVM, employees: [employee], existing: nil,
                preselectedEmployeeId: employee.id
            )
        }
        .sheet(item: $editingOverride, onDismiss: { Task { await overrideVM.loadForEmployee(id: employee.id) } }) { ovr in
            EmployeeAvailabilityOverrideSheet(
                vm: overrideVM, employees: [employee], existing: ovr,
                preselectedEmployeeId: employee.id
            )
        }
    }
}

// MARK: - Edit / Create sheet

struct EmployeeEditSheet: View {

    let viewModel: EmployeeViewModel
    var existing: FfiEmployee?
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(ExchangeRateService.self) private var exchangeRates
    @AppStorage("appCurrency") private var displayCurrency: String = AppCurrency.usd.rawValue
    @State private var showingDeleteConfirmation = false

    @State private var roleVM = RoleViewModel()
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var nickname = ""
    @State private var selectedRoles: Set<String> = []
    @State private var startDate = Date()
    @State private var targetHours = 20.0
    @State private var deviation = 4.0
    @State private var maxDaily = 8.0
    @State private var notes = ""
    @State private var hourlyWageText = ""
    @State private var wageCurrency: String = AppCurrency.usd.rawValue

    // Dual availability state
    @State private var defaultAvailabilitySlots: [AvailabilitySlot] = []
    @State private var nextWeekSlots: [AvailabilitySlot] = []

    // DisclosureGroup expansion state
    @State private var defaultExpanded = false
    @State private var nextWeekExpanded = true

    // Visible hour range — shared by both grids, set via the Default Availability picker
    @State private var defaultVisibleStart = 6
    @State private var defaultVisibleEnd = 22

    // Selection mode — disables Form scrolling while active
    @State private var selectionModeActive = false

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Info") {
                    TextField("First Name", text: $firstName)
                    TextField("Last Name", text: $lastName)
                    TextField("Nickname (optional)", text: $nickname)
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                }
                Section("Roles") {
                    if roleVM.roles.isEmpty {
                        Text("No roles defined. Add roles in the Templates tab.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(roleVM.roles, id: \.id) { role in
                        Toggle(role.name, isOn: Binding(
                            get: { selectedRoles.contains(role.name) },
                            set: { on in
                                if on { selectedRoles.insert(role.name) }
                                else { selectedRoles.remove(role.name) }
                            }
                        ))
                    }
                }
                Section("Hours") {
                    StepperField(label: "Target", suffix: "h/week",
                                 value: $targetHours, range: 0...80, step: 1)
                    StepperField(label: "Deviation", suffix: "h ±",
                                 value: $deviation, range: 0...20, step: 1)
                    StepperField(label: "Max daily", suffix: "h",
                                 value: $maxDaily, range: 1...24, step: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Hourly wage")
                            Spacer()
                            Text(exchangeRates.symbol(for: displayCurrency))
                                .foregroundStyle(.secondary)
                            TextField("Not set", text: $hourlyWageText)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                        HStack {
                            Text("Stored as")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $wageCurrency) {
                                ForEach(AppCurrency.allCases, id: \.rawValue) { c in
                                    Text(c.label).tag(c.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Availability") {
                    // Manual expand/collapse keeps the grid as a direct Section row
                    // (same level as read-only view), so GeometryReader gets the same width.
                    Button {
                        withAnimation { nextWeekExpanded.toggle() }
                    } label: {
                        HStack {
                            Text("Next Week").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: nextWeekExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if nextWeekExpanded {
                        AvailabilityGridView(
                            slots: nextWeekSlots,
                            isEditable: true,
                            visibleHourStart: defaultVisibleStart,
                            visibleHourEnd: defaultVisibleEnd,
                            onChange: { nextWeekSlots = $0 },
                            onSelectionModeChange: { selectionModeActive = $0 },
                            onReset: { nextWeekSlots = defaultAvailabilitySlots }
                        )
                    }

                    Button {
                        withAnimation { defaultExpanded.toggle() }
                    } label: {
                        HStack {
                            Text("Default").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: defaultExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if defaultExpanded {
                        AvailabilityGridView(
                            slots: defaultAvailabilitySlots,
                            isEditable: true,
                            visibleHourStart: defaultVisibleStart,
                            visibleHourEnd: defaultVisibleEnd,
                            showRangePicker: true,
                            onChange: { defaultAvailabilitySlots = $0 },
                            onVisibleRangeChange: { start, end in
                                defaultVisibleStart = start
                                defaultVisibleEnd = end
                            },
                            onSelectionModeChange: { selectionModeActive = $0 }
                        )
                    }
                }
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Remove Employee", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollDisabled(selectionModeActive)
            .dismissesKeyboardOnTap()
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(isEditing ? "Edit Employee" : "New Employee")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  lastName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert(
                "Remove \(existing.map { "\($0.firstName) \($0.lastName)" } ?? "Employee")?",
                isPresented: $showingDeleteConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    guard let e = existing else { return }
                    Task {
                        await viewModel.delete(id: e.id)
                        dismiss()
                        onDelete?()
                    }
                }
            } message: {
                Text("This employee will be removed from future rotas. Past and current assignments are preserved.")
            }
            .onAppear {
                if existing == nil { wageCurrency = displayCurrency }
                prefill()
            }
            .task { await roleVM.load() }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 550, idealHeight: 700)
        #endif
    }

    private func prefill() {
        guard let e = existing else { return }
        firstName = e.firstName
        lastName = e.lastName
        nickname = e.nickname ?? ""
        selectedRoles = Set(e.roles)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        startDate = fmt.date(from: e.startDate) ?? Date()
        targetHours = Double(e.targetWeeklyHours)
        deviation = Double(e.weeklyHoursDeviation)
        maxDaily = Double(e.maxDailyHours)
        notes = e.notes ?? ""
        let storedCurrency = e.wageCurrency ?? displayCurrency
        wageCurrency = storedCurrency
        if let wage = e.hourlyWage {
            let converted = exchangeRates.convert(wage, from: storedCurrency, to: displayCurrency)
            hourlyWageText = String(format: "%.2f", converted)
        } else {
            hourlyWageText = ""
        }
        defaultAvailabilitySlots = e.defaultAvailability
        nextWeekSlots = e.availability
        let range = AvailabilityGridView.inferredVisibleRange(from: e.defaultAvailability)
        defaultVisibleStart = range.start
        defaultVisibleEnd = range.end
    }

    private func save() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        let finalDefault = AvailabilityGridView.slotsWithOutOfRangeSetToNo(
            slots: defaultAvailabilitySlots, start: defaultVisibleStart, end: defaultVisibleEnd)
        let finalNextWeek = AvailabilityGridView.slotsWithOutOfRangeSetToNo(
            slots: nextWeekSlots, start: defaultVisibleStart, end: defaultVisibleEnd)

        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        let trimmedLast = lastName.trimmingCharacters(in: .whitespaces)
        let trimmedNick = nickname.trimmingCharacters(in: .whitespaces)
        let displayWage: Float? = Float(hourlyWageText.trimmingCharacters(in: .whitespaces))
        // Convert from display currency back to the employee's storage currency
        let parsedWage: Float? = displayWage.map { exchangeRates.convert($0, from: displayCurrency, to: wageCurrency) }
        let emp = FfiEmployee(
            id: existing?.id ?? 0,
            firstName: trimmedFirst,
            lastName: trimmedLast,
            nickname: trimmedNick.isEmpty ? nil : trimmedNick,
            displayName: "",  // Rust recomputes this on save
            roles: Array(selectedRoles),
            startDate: fmt.string(from: startDate),
            targetWeeklyHours: Float(targetHours),
            weeklyHoursDeviation: Float(deviation),
            maxDailyHours: Float(maxDaily),
            notes: notes.isEmpty ? nil : notes,
            bankDetails: existing?.bankDetails,
            hourlyWage: parsedWage,
            wageCurrency: parsedWage != nil ? wageCurrency : nil,
            defaultAvailability: finalDefault,
            availability: finalNextWeek,
            deleted: false
        )

        Task {
            if isEditing {
                await viewModel.update(emp)
            } else {
                await viewModel.create(emp)
            }
            dismiss()
        }
    }
}

// MARK: - Keyboard dismiss helper

extension View {
    /// Dismisses the software keyboard (iOS) when the user taps on a non-interactive area.
    /// On macOS this is a no-op — adding onTapGesture to a Form breaks click-through to controls.
    func dismissesKeyboardOnTap() -> some View {
        #if canImport(UIKit)
        onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        #else
        self
        #endif
    }
}

// MARK: - Role tag chip

struct RoleTag: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Stepper with editable text field

private struct StepperField: View {
    let label: String
    let suffix: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    @State private var textValue: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            Button {
                value = max(range.lowerBound, value - step)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)

            TextField("", text: $textValue)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .frame(width: 48)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if !focused, let parsed = Double(textValue) {
                        value = min(range.upperBound, max(range.lowerBound, parsed))
                    }
                }
                .onSubmit {
                    if let parsed = Double(textValue) {
                        value = min(range.upperBound, max(range.lowerBound, parsed))
                    }
                }

            Text(suffix)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                value = min(range.upperBound, value + step)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .onChange(of: value) { _, newVal in
            if !isFocused {
                textValue = String(format: "%.0f", newVal)
            }
        }
        .onAppear {
            textValue = String(format: "%.0f", value)
        }
    }
}
