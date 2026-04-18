import SwiftUI

struct ContentView: View {
    @State private var layoutManager = TabLayoutManager()
    @State private var bridge = RotaUIBridge()
    @State private var employeeBridge = EmployeeUIBridge()
    @State private var selection: TabSelection = .page(.rota)
    @State private var lastPage: TabPage = .rota
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// The dots tab is only shown in portrait iPhone while the Rota tab is
    /// active. Landscape iPhone uses a floating overlay inside `RotaView`
    /// instead, because the iOS 26 floating tab bar leading-aligns in
    /// landscape when a `.search` role tab is present.
    /// Use `lastPage` (not `selection`) so the dots tab stays visible while
    /// the `.dots` selection is in flight — otherwise SwiftUI removes the tab
    /// mid-transition and auto-selects the first tab, causing a visible glitch.
    private var showsDotsTab: Bool {
        #if os(iOS)
        guard verticalSizeClass == .regular else { return false }
        return lastPage == .rota || lastPage == .employees
        #else
        return false
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(layoutManager.tabBarPages) { page in
                Tab(
                    page.title,
                    systemImage: page.systemImage,
                    value: TabSelection.page(page)
                ) {
                    page.destinationView
                }
            }

            #if os(iOS)
            if showsDotsTab {
                Tab(
                    bridge.isEditMode ? "Done" : "More",
                    systemImage: bridge.isEditMode ? "checkmark" : "ellipsis",
                    value: TabSelection.dots,
                    role: .search
                ) {
                    // Empty destination — this tab is hijacked: tapping it
                    // just surfaces the Rota overflow menu via `bridge` and
                    // reverts selection to the previously-active page.
                    Color.clear
                }
            }
            #endif
        }
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        #if os(macOS)
        .tabViewStyle(.sidebarAdaptable)
        #endif
        .environment(layoutManager)
        .environment(bridge)
        .environment(employeeBridge)
        .onChange(of: selection) { _, new in
            switch new {
            case .dots:
                // Route the overflow menu to whichever tab is active.
                switch lastPage {
                case .employees:
                    selection = .page(.employees)
                    employeeBridge.overflowOpen.toggle()
                default:
                    selection = .page(.rota)
                    lastPage = .rota
                    if bridge.isEditMode {
                        bridge.isEditMode = false
                    } else {
                        bridge.overflowOpen.toggle()
                    }
                }
            case .page(let p):
                lastPage = p
            }
        }
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

enum TabSelection: Hashable {
    case page(TabPage)
    case dots
}
