import SwiftUI
import AutorotaKit

struct EmployeeListView: View {

    @State private var vm = EmployeeViewModel()
    @State private var showingAddSheet = false
    @State private var showingAvailability = false
    @State private var selectedEmployee: FfiEmployee?
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
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                EmployeeEditSheet(viewModel: vm)
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
            .task { await vm.load() }
        }
    }
}
