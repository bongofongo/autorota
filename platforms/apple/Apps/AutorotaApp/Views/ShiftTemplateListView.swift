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
    @Environment(\.isMenuPushed) private var isMenuPushed
    @Environment(DemoModeController.self) private var demo

    private var bothLoaded: Bool {
        vm.hasLoaded && roleVM.hasLoaded
    }

    private var isFullyEmpty: Bool {
        bothLoaded && vm.templates.isEmpty && roleVM.roles.isEmpty
    }

    @ViewBuilder
    private var listContent: some View {
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
                        .contextMenu {
                            Button {
                                renamingRole = role
                                renameText = role.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                Task { await roleVM.delete(id: role.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Roles")
                    Spacer()
                    Button {
                        showingAddRoleSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add role")
                }
            }
            .headerProminence(.increased)

            // ── Shifts ───────────────────────────────────
            Section {
                if vm.templates.isEmpty && !vm.isLoading {
                    Text("No shifts yet")
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
                    .contextMenu {
                        Button {
                            editing = tmpl
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            Task { await vm.delete(id: tmpl.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
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
                HStack {
                    Text("Shifts")
                    Spacer()
                    Button {
                        showingAddTemplateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add shift")
                    .tutorialTarget(.addShiftButton)
                }
            }
            .headerProminence(.increased)
        }
    }

    var body: some View {
        OptionalNavigationStack(embed: !isMenuPushed) {
            VStack(spacing: 0) {
                Group {
                if !bothLoaded {
                    // Neutral placeholder until both VMs report hasLoaded.
                    // Avoids flashing empty list rows before the CUV settles
                    // (see IOS_BUGS.md #1).
                    Color.clear
                } else if isFullyEmpty {
                    ContentUnavailableView {
                        Label("empty.shifts.title", systemImage: "clock.badge.plus")
                    } description: {
                        Text("empty.shifts.body")
                    } actions: {
                        Button {
                            showingAddTemplateSheet = true
                        } label: {
                            Label("empty.shifts.action", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint(Text("empty.shifts.action.a11y_hint"))
                    }
                } else {
                    listContent
                }
                }
            }
            .navigationTitle("Shifts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    DataBundleToolbarMenu(
                        exportOptions: DataBundleExportOption.shiftPageOptions,
                        service: vm.service
                    ) {
                        Task {
                            await vm.load()
                            await roleVM.load()
                        }
                    }
                }
            }
            .onChange(of: showingAddTemplateSheet) { _, shown in
                if shown { demo.noteTutorialEvent(.addShiftSheetOpened) }
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
            .errorAlert(Binding(
                get: { vm.error ?? roleVM.error },
                set: { if $0 == nil { vm.error = nil; roleVM.error = nil } }
            ))
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
            #if os(macOS)
            .formStyle(.grouped)
            #endif
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
        #if os(macOS)
        .frame(minWidth: 340, idealWidth: 400, minHeight: 160, idealHeight: 200)
        #endif
    }
}

// MARK: - Edit / Create sheet

struct ShiftTemplateEditSheet: View {

    let viewModel: ShiftTemplateViewModel
    let roles: [FfiRole]
    var existing: FfiShiftTemplate?

    @Environment(\.dismiss) private var dismiss
    @Environment(DemoModeController.self) private var demo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let allDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    @State private var name = ""
    @State private var selectedDays: Set<String> = []
    @State private var startTime = ShiftTemplateEditSheet.defaultTime(hour: 9)
    @State private var endTime = ShiftTemplateEditSheet.defaultTime(hour: 17)
    @State private var minStaff = 1
    @State private var maxStaff = 1
    @State private var roleReqs: [FfiRoleRequirement] = []

    private var isEditing: Bool { existing != nil }

    private static func defaultTime(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
            ?? Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Shift name", text: $name)
                }
                Section("Days") {
                    Toggle("Everyday", isOn: Binding(
                        get: { selectedDays == Set(Self.allDays) },
                        set: { on in
                            selectedDays = on ? Set(Self.allDays) : []
                        }
                    ))
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
                RoleStaffingSection(
                    roles: roles,
                    minStaff: $minStaff,
                    maxStaff: $maxStaff,
                    roleReqs: $roleReqs
                )
            }
            .dismissesKeyboardOnTap()
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(isEditing ? "Edit Shift" : "New Shift")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || selectedDays.isEmpty)
                }
            }
            .onAppear { prefill() }
        }
        #if os(iOS)
        // The sheet covers the root spotlight overlay, so the demo tour's
        // Role & Staffing walkthrough tooltip mounts here.
        .overlay {
            ZStack {
                if let spot = demo.currentSpotlight, spot.target == .shiftRoleStaffingHint {
                    TutorialSpotlightOverlay(
                        spotlight: spot,
                        targetFrame: nil,
                        onSkip: { demo.skipCurrentSubStep() }
                    )
                    .transition(TutorialFade.transition(isFirstOfSet: false))
                }
            }
            .animation(
                reduceMotion ? nil : .default,
                value: demo.currentSpotlight
            )
        }
        #endif
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 460, idealHeight: 540)
        #endif
    }

    private func prefill() {
        if let t = existing {
            name = t.name
            selectedDays = Set(t.weekdays)
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            startTime = fmt.date(from: t.startTime) ?? Date()
            endTime = fmt.date(from: t.endTime) ?? Date()
            minStaff = Int(t.minEmployees)
            maxStaff = Int(t.maxEmployees)
            roleReqs = t.roleRequirements
        }
    }

    private func save() {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let orderedDays = Self.allDays.filter { selectedDays.contains($0) }

        let floor = roleReqs.map { Int($0.minCount) }.max() ?? 0
        let effMin = max(minStaff, floor)
        let effMax = max(maxStaff, effMin)
        let tmpl = FfiShiftTemplate(
            id: existing?.id ?? 0,
            name: name,
            weekdays: orderedDays,
            startTime: fmt.string(from: startTime),
            endTime: fmt.string(from: endTime),
            requiredRole: roleReqs.first?.role ?? "",
            minEmployees: UInt32(effMin),
            maxEmployees: UInt32(effMax),
            roleRequirements: roleReqs,
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
