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
                LabeledContent("Start date", value: employee.startDate)
                LabeledContent("Target hours/week", value: String(format: "%.1f", employee.targetWeeklyHours))
                LabeledContent("Deviation", value: "±\(String(format: "%.1f", employee.weeklyHoursDeviation))h")
                LabeledContent("Max daily hours", value: String(format: "%.1f", employee.maxDailyHours))
            }

            if let notes = employee.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }

            Section("Default Availability") {
                AvailabilityGridView(slots: employee.defaultAvailability, isEditable: false)
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
    @State private var availabilitySlots: [AvailabilitySlot] = []

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
                    Stepper("Target: \(String(format: "%.0f", targetHours))h/week",
                            value: $targetHours, in: 0...80, step: 1)
                    Stepper("Deviation: ±\(String(format: "%.0f", deviation))h",
                            value: $deviation, in: 0...20, step: 1)
                    Stepper("Max daily: \(String(format: "%.0f", maxDaily))h",
                            value: $maxDaily, in: 1...24, step: 1)
                }
                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("Default Availability") {
                    AvailabilityGridView(slots: availabilitySlots, isEditable: true) { updated in
                        availabilitySlots = updated
                    }
                }
            }
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
        availabilitySlots = e.defaultAvailability
    }

    private func save() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

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
            defaultAvailability: availabilitySlots,
            availability: availabilitySlots,
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
