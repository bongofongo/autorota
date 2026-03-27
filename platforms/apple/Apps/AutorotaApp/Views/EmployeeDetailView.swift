import SwiftUI
import AutorotaKit

struct EmployeeDetailView: View {

    let employee: FfiEmployee
    let viewModel: EmployeeViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showingEditSheet = false

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
        .navigationTitle(employee.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEditSheet = true }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            EmployeeEditSheet(viewModel: viewModel, existing: employee, onDelete: { dismiss() })
        }
    }
}

// MARK: - Edit / Create sheet

struct EmployeeEditSheet: View {

    let viewModel: EmployeeViewModel
    var existing: FfiEmployee?
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
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
            .onAppear { prefill() }
            .task { await roleVM.load() }
        }
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
    /// Dismisses the software keyboard (iOS) or resigns window first responder (macOS)
    /// when the user taps on a non-interactive area of this view.
    func dismissesKeyboardOnTap() -> some View {
        onTapGesture {
            #if canImport(UIKit)
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
            #elseif canImport(AppKit)
            NSApp.keyWindow?.makeFirstResponder(nil)
            #endif
        }
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
