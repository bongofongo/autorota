import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RotaView()
                .tabItem {
                    Label("Rota", systemImage: "calendar")
                }

            EmployeeListView()
                .tabItem {
                    Label("Employees", systemImage: "person.2")
                }

            ShiftTemplateListView()
                .tabItem {
                    Label("Templates", systemImage: "clock")
                }
        }
    }
}
