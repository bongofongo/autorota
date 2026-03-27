import SwiftUI
import AutorotaKit

struct ShiftTemplateListView: View {

    @State private var vm = ShiftTemplateViewModel()
    @State private var roleVM = RoleViewModel()
    @State private var showingAddTemplateSheet = false
    @State private var showingAddRoleSheet = false
    @State private var editing: FfiShiftTemplate?
    @State private var renamingRole: FfiRole?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                // ── Roles ────────────────────────────────────
                Section {
                    if roleVM.roles.isEmpty && !roleVM.isLoading {
                        Text("No roles yet")
                            .foregroundStyle(.tertiary)
                            .font(.subheadline)
                    }
                    ForEach(roleVM.roles, id: \.id) { role in
                        Text(role.name)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await roleVM.delete(id: role.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    renamingRole = role
                                    renameText = role.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                    }
                } header: {
                    Text("Roles")
                }
                .headerProminence(.increased)

                // ── Shifts ───────────────────────────────────
                Section {
                    if vm.templates.isEmpty && !vm.isLoading {
                        Text("No shift templates yet")
                            .foregroundStyle(.tertiary)
                            .font(.subheadline)
                    }
                    ForEach(vm.templates, id: \.id) { tmpl in
                        Button {
                            editing = tmpl
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tmpl.name).font(.headline).foregroundStyle(.primary)
                                Text("\(tmpl.weekdays.joined(separator: ", "))  \(tmpl.startTime)–\(tmpl.endTime)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 4) {
                                    RoleTag(name: tmpl.requiredRole)
                                    Text("\(tmpl.minEmployees)–\(tmpl.maxEmployees) staff")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            let t = vm.templates[i]
                            Task { await vm.delete(id: t.id) }
                        }
                    }
                } header: {
                    Text("Shifts")
                }
                .headerProminence(.increased)
            }
            .navigationTitle("Templates")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingAddTemplateSheet = true
                        } label: {
                            Label("New Shift", systemImage: "clock.badge.plus")
                        }
                        Button {
                            showingAddRoleSheet = true
                        } label: {
                            Label("New Role", systemImage: "tag")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddTemplateSheet) {
                ShiftTemplateEditSheet(viewModel: vm, roles: roleVM.roles)
            }
            .sheet(item: $editing) { tmpl in
                ShiftTemplateEditSheet(viewModel: vm, roles: roleVM.roles, existing: tmpl)
            }
            .sheet(isPresented: $showingAddRoleSheet) {
                AddRoleSheet(roleVM: roleVM)
            }
            .alert("Rename Role", isPresented: .constant(renamingRole != nil)) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let role = renamingRole {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty {
                            Task {
                                await roleVM.update(id: role.id, name: name)
                                await vm.load()
                            }
                        }
                    }
                    renamingRole = nil
                }
                Button("Cancel", role: .cancel) { renamingRole = nil }
            } message: {
                Text("Enter a new name for \"\(renamingRole?.name ?? "")\".")
            }
            .alert("Error", isPresented: .constant(vm.error != nil || roleVM.error != nil)) {
                Button("OK") { vm.error = nil; roleVM.error = nil }
            } message: {
                Text(vm.error ?? roleVM.error ?? "")
            }
            .task {
                await vm.load()
                await roleVM.load()
            }
        }
    }
}

// MARK: - Add Role sheet

struct AddRoleSheet: View {

    let roleVM: RoleViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Role name", text: $name)
                        .focused($focused)
                        .autocorrectionDisabled()
                }
            }
            .dismissesKeyboardOnTap()
            .navigationTitle("New Role")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            await roleVM.create(name: trimmed)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - Edit / Create sheet

struct ShiftTemplateEditSheet: View {

    let viewModel: ShiftTemplateViewModel
    let roles: [FfiRole]
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
                    if roles.isEmpty {
                        Text("No roles defined. Add roles in the Templates tab first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Required role", selection: $role) {
                            ForEach(roles, id: \.id) { r in
                                Text(r.name).tag(r.name)
                            }
                        }
                    }
                    Stepper("Min staff: \(minStaff)", value: $minStaff, in: 1...20)
                    Stepper("Max staff: \(maxStaff)", value: $maxStaff, in: 1...20)
                        .onChange(of: minStaff) { _, v in if maxStaff < v { maxStaff = v } }
                }
            }
            .dismissesKeyboardOnTap()
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
        if let t = existing {
            name = t.name
            selectedDays = Set(t.weekdays)
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            startTime = fmt.date(from: t.startTime) ?? Date()
            endTime = fmt.date(from: t.endTime) ?? Date()
            role = t.requiredRole
            minStaff = Int(t.minEmployees)
            maxStaff = Int(t.maxEmployees)
        } else if role.isEmpty, let first = roles.first {
            role = first.name
        }
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
