import SwiftUI
import AutorotaKit

struct EmployeeDetailView: View {

    let employee: FfiEmployee
    let viewModel: EmployeeViewModel

    @State private var showingEditSheet = false

    var body: some View {
        List {
            Section("Details") {
                LabeledContent("Roles", value: employee.roles.joined(separator: ", "))
                LabeledContent("Target hours/week",
                    value: "\(String(format: "%.1f", employee.targetWeeklyHours)) ± \(String(format: "%.1f", employee.weeklyHoursDeviation))h")
                LabeledContent("Max daily hours", value: String(format: "%.1f", employee.maxDailyHours))
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
        }
        .navigationTitle(employee.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEditSheet = true }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            EmployeeEditSheet(viewModel: viewModel, existing: employee)
        }
    }
}

// MARK: - Edit / Create sheet

struct EmployeeEditSheet: View {

    let viewModel: EmployeeViewModel
    var existing: FfiEmployee?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var rolesText = ""
    @State private var startDate = Date()
    @State private var targetHours = 20.0
    @State private var deviation = 4.0
    @State private var maxDaily = 8.0
    @State private var notes = ""

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
                    TextField("Name", text: $name)
                    TextField("Roles (comma-separated)", text: $rolesText)
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                }
                Section("Hours") {
                    StepperField(label: "Target", suffix: "h/week",
                                 value: $targetHours, range: 0...80, step: 1)
                    StepperField(label: "Deviation", suffix: "h ±",
                                 value: $deviation, range: 0...20, step: 1)
                    StepperField(label: "Max daily", suffix: "h",
                                 value: $maxDaily, range: 1...24, step: 1)
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
            }
            .scrollDisabled(selectionModeActive)
            .navigationTitle(isEditing ? "Edit Employee" : "New Employee")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { prefill() }
        }
    }

    private func prefill() {
        guard let e = existing else { return }
        name = e.name
        rolesText = e.roles.joined(separator: ", ")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        startDate = fmt.date(from: e.startDate) ?? Date()
        targetHours = Double(e.targetWeeklyHours)
        deviation = Double(e.weeklyHoursDeviation)
        maxDaily = Double(e.maxDailyHours)
        notes = e.notes ?? ""
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

        let emp = FfiEmployee(
            id: existing?.id ?? 0,
            name: name.trimmingCharacters(in: .whitespaces),
            roles: rolesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            startDate: fmt.string(from: startDate),
            targetWeeklyHours: Float(targetHours),
            weeklyHoursDeviation: Float(deviation),
            maxDailyHours: Float(maxDaily),
            notes: notes.isEmpty ? nil : notes,
            bankDetails: existing?.bankDetails,
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
                .keyboardType(.decimalPad)
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
