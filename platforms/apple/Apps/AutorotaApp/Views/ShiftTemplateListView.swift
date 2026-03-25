import SwiftUI
import AutorotaKit

struct ShiftTemplateListView: View {

    @State private var vm = ShiftTemplateViewModel()
    @State private var showingAddSheet = false
    @State private var editing: FfiShiftTemplate?

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.templates.isEmpty {
                    ProgressView("Loading…")
                } else if vm.templates.isEmpty {
                    ContentUnavailableView("No Templates", systemImage: "clock.slash")
                } else {
                    List {
                        ForEach(vm.templates, id: \.id) { tmpl in
                            Button {
                                editing = tmpl
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tmpl.name).font(.headline).foregroundStyle(.primary)
                                    Text("\(tmpl.weekdays.joined(separator: ", "))  \(tmpl.startTime)–\(tmpl.endTime)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(tmpl.requiredRole) · \(tmpl.minEmployees)–\(tmpl.maxEmployees) staff")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                let t = vm.templates[i]
                                Task { await vm.delete(id: t.id) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Shift Templates")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { showingAddSheet = true }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                ShiftTemplateEditSheet(viewModel: vm)
            }
            .sheet(item: $editing) { tmpl in
                ShiftTemplateEditSheet(viewModel: vm, existing: tmpl)
            }
            .alert("Error", isPresented: .constant(vm.error != nil)) {
                Button("OK") { vm.error = nil }
            } message: {
                Text(vm.error ?? "")
            }
            .task { await vm.load() }
        }
    }
}

// MARK: - Edit / Create sheet

struct ShiftTemplateEditSheet: View {

    let viewModel: ShiftTemplateViewModel
    var existing: FfiShiftTemplate?

    @Environment(\.dismiss) private var dismiss

    private static let allDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    @State private var name = ""
    @State private var selectedDays: Set<String> = []
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var role = ""
    @State private var minStaff = 1
    @State private var maxStaff = 1

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Template name", text: $name)
                }
                Section("Days") {
                    ForEach(Self.allDays, id: \.self) { day in
                        Toggle(day, isOn: Binding(
                            get: { selectedDays.contains(day) },
                            set: { on in
                                if on { selectedDays.insert(day) }
                                else { selectedDays.remove(day) }
                            }
                        ))
                    }
                }
                Section("Times") {
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                Section("Role & Staffing") {
                    TextField("Required role", text: $role)
                    Stepper("Min staff: \(minStaff)", value: $minStaff, in: 1...20)
                    Stepper("Max staff: \(maxStaff)", value: $maxStaff, in: 1...20)
                        .onChange(of: minStaff) { _, v in if maxStaff < v { maxStaff = v } }
                }
            }
            .navigationTitle(isEditing ? "Edit Template" : "New Template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || selectedDays.isEmpty || role.isEmpty)
                }
            }
            .onAppear { prefill() }
        }
    }

    private func prefill() {
        guard let t = existing else { return }
        name = t.name
        selectedDays = Set(t.weekdays)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        startTime = fmt.date(from: t.startTime) ?? Date()
        endTime = fmt.date(from: t.endTime) ?? Date()
        role = t.requiredRole
        minStaff = Int(t.minEmployees)
        maxStaff = Int(t.maxEmployees)
    }

    private func save() {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let orderedDays = Self.allDays.filter { selectedDays.contains($0) }

        let tmpl = FfiShiftTemplate(
            id: existing?.id ?? 0,
            name: name,
            weekdays: orderedDays,
            startTime: fmt.string(from: startTime),
            endTime: fmt.string(from: endTime),
            requiredRole: role,
            minEmployees: UInt32(minStaff),
            maxEmployees: UInt32(maxStaff),
            deleted: false
        )
        Task {
            if isEditing { await viewModel.update(tmpl) }
            else { await viewModel.create(tmpl) }
            dismiss()
        }
    }
}

extension FfiShiftTemplate: @retroactive Identifiable {}
