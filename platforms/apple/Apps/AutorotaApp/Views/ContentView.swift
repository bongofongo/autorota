import SwiftUI

struct ContentView: View {
    @State private var layoutManager = TabLayoutManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

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
        .onAppear {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showOnboarding) {
            hasCompletedOnboarding = true
        } content: {
            OnboardingView(isPresented: $showOnboarding)
                .interactiveDismissDisabled()
        }
        #else
        .sheet(isPresented: $showOnboarding) {
            hasCompletedOnboarding = true
        } content: {
            OnboardingView(isPresented: $showOnboarding)
                .interactiveDismissDisabled()
        }
        #endif
    }
}
