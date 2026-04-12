import SwiftUI
import AutorotaKit

struct EmployeeListView: View {

    @State private var vm = EmployeeViewModel()
    @State private var showingAddSheet = false
    @State private var showingAvailability = false
    @State private var selectedEmployee: FfiEmployee?
    @Environment(EmployeeUIBridge.self) private var bridge
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var showsFloatingDotsButton: Bool {
        #if os(iOS)
        return verticalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        @Bindable var bridge = bridge
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
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

                if showsFloatingDotsButton {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                            bridge.overflowOpen.toggle()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 24, height: 24)
                            .padding(14)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
                }

                if bridge.overflowOpen {
                    RotaOverflowPopover(
                        actions: overflowActions,
                        isPresented: $bridge.overflowOpen
                    )
                }
            }
            .navigationTitle("Employees")
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .onDisappear {
                bridge.overflowOpen = false
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: bridge.overflowOpen)
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

    private var overflowActions: [RotaOverflowAction] {
        [
            RotaOverflowAction(
                title: "Add employee",
                systemImage: "person.badge.plus"
            ) {
                showingAddSheet = true
            },
            RotaOverflowAction(
                title: "Weekly availability",
                systemImage: "calendar.badge.clock"
            ) {
                showingAvailability = true
            },
        ]
    }
}
