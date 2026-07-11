import SwiftUI
import AutorotaKit

struct EmployeeListView: View {

    @Environment(EmployeeUIBridge.self) private var employeeBridge
    @State private var vm = EmployeeViewModel()
    @State private var showingAddSheet = false
    @State private var showingAvailability = false
    @State private var selectedEmployee: FfiEmployee?
    @State private var sendScheduleTarget: FfiEmployee?
    @State private var showingImport = false
    @Environment(\.isMenuPushed) private var isMenuPushed
    var body: some View {
        OptionalNavigationStack(embed: !isMenuPushed) {
            Group {
                if vm.isLoading && vm.employees.isEmpty {
                    ProgressView("Loading…")
                } else if vm.employees.isEmpty {
                    ContentUnavailableView {
                        Label("empty.employees.title", systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text("empty.employees.body")
                    } actions: {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("empty.employees.action", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint(Text("empty.employees.action.a11y_hint"))
                    }
                } else {
                    List {
                        Section {
                            Button {
                                showingAvailability = true
                            } label: {
                                Label("Weekly availability", systemImage: "calendar.badge.clock")
                            }
                        }

                        Section {
                            ForEach(vm.employees, id: \.id) { employee in
                                NavigationLink {
                                    EmployeeDetailView(employee: employee, viewModel: vm)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(employee.displayName).font(.headline)
                                        if !employee.roles.isEmpty {
                                            HStack(spacing: 4) {
                                                ForEach(employee.roles, id: \.self) { RoleTag(name: $0) }
                                            }
                                        }
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        sendScheduleTarget = employee
                                    } label: {
                                        Label("Send schedule…", systemImage: "paperplane")
                                    }
                                }
                                #if os(iOS)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        sendScheduleTarget = employee
                                    } label: {
                                        Label("Send", systemImage: "paperplane")
                                    }
                                    .tint(.blue)
                                }
                                #endif
                                .modifier(EmployeeRowTutorialTag(nickname: employee.nickname))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Employees")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    DataBundleToolbarMenu(
                        exportOptions: DataBundleExportOption.employeePageOptions,
                        service: vm.service
                    ) {
                        Task { await vm.reload() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import employees…", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add employee", systemImage: "person.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                EmployeeEditSheet(viewModel: vm)
            }
            .sheet(isPresented: Binding(
                get: { sendScheduleTarget != nil },
                set: { if !$0 { sendScheduleTarget = nil } }
            )) {
                if let employee = sendScheduleTarget {
                    SendSchedulePicker(employee: employee, service: vm.service)
                }
            }
            .sheet(isPresented: $showingImport) {
                RosterImportView(service: vm.service) {
                    Task { await vm.reload() }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingAvailability) {
                WeeklyAvailabilityView()
            }
            #else
            .sheet(isPresented: $showingAvailability) {
                WeeklyAvailabilityView()
                    .frame(minWidth: 700, minHeight: 500)
            }
            #endif
            .errorAlert($vm.error)
            .task {
                await vm.loadIfNeeded()
                consumePendingNewEmployeeRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: .autorotaDataChanged)) { note in
                if affectsEmployees(note) {
                    Task { await vm.reload() }
                }
            }
            .onChange(of: employeeBridge.requestNewEmployeeSheet) { _, _ in
                consumePendingNewEmployeeRequest()
            }
        }
    }

    /// Reload only when a change touches employees (or roles, which render as
    /// `RoleTag`s). A `nil` payload is a legacy/full post — reload to be safe.
    private func affectsEmployees(_ note: Notification) -> Bool {
        guard let change = note.autorotaDataChange else { return true }
        return change.tables.contains(.employee) || change.tables.contains(.role)
    }

    private func consumePendingNewEmployeeRequest() {
        guard employeeBridge.requestNewEmployeeSheet else { return }
        showingAddSheet = true
        employeeBridge.requestNewEmployeeSheet = false
    }
}

/// Registers the demo tour targets on Mercury's and Mars's rows (the two
/// seeded demo-crew members the guided steps point at).
private struct EmployeeRowTutorialTag: ViewModifier {
    let nickname: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        switch nickname {
        case "Mercury": content.tutorialTarget(.mercuryRow)
        case "Mars":    content.tutorialTarget(.marsRow)
        default:        content
        }
    }
}
