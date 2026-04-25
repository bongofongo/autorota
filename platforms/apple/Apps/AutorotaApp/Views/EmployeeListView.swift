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
    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.employees.isEmpty {
                    ProgressView("Loading…")
                } else if vm.employees.isEmpty {
                    ContentUnavailableView("No Employees", systemImage: "person.slash")
                } else {
                    List {
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
                        }
                    }
                }
            }
            .navigationTitle("Employees")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("Add employee", systemImage: "person.badge.plus")
                        }
                        Button {
                            showingAvailability = true
                        } label: {
                            Label("Weekly availability", systemImage: "calendar.badge.clock")
                        }
                        Button {
                            showingImport = true
                        } label: {
                            Label("Import employees…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
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
                    Task { await vm.load() }
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
            .alert("Error", isPresented: .constant(vm.error != nil), actions: {
                Button("OK") { vm.error = nil }
            }, message: {
                Text(vm.error ?? "")
            })
            .task {
                await vm.load()
                consumePendingNewEmployeeRequest()
            }
            .onChange(of: employeeBridge.requestNewEmployeeSheet) { _, _ in
                consumePendingNewEmployeeRequest()
            }
        }
    }

    private func consumePendingNewEmployeeRequest() {
        guard employeeBridge.requestNewEmployeeSheet else { return }
        showingAddSheet = true
        employeeBridge.requestNewEmployeeSheet = false
    }
}
