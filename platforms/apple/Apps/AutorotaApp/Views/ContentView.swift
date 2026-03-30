import SwiftUI

struct ContentView: View {
    @State private var layoutManager = TabLayoutManager()

    var body: some View {
        TabView {
            ForEach(layoutManager.tabBarPages) { page in
                page.destinationView
                    .tabItem {
                        Label(page.title, systemImage: page.systemImage)
                    }
                    .tag(page)
            }
        }
        #if os(macOS)
        .tabViewStyle(.sidebarAdaptable)
        #endif
        .environment(layoutManager)
    }
}
