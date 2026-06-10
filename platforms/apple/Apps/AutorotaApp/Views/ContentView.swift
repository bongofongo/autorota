import SwiftUI

struct ContentView: View {
    @State private var layoutManager = TabLayoutManager()
    @State private var bridge = RotaUIBridge()
    @State private var employeeBridge = EmployeeUIBridge()
    @State private var menuNav = MenuNavigationBridge()
    @State private var selection: TabSelection = .page(.rota)
    @State private var lastPage: TabPage = .rota
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Set by `AutorotaAppApp` when the user accepts the iCloud sync prompt.
    /// Onboarding skips the slide deck and lands directly on `TierPickView`.
    /// Cleared as soon as it is consumed below so a manual replay from
    /// settings still shows the slides.
    @AppStorage("pendingOnboardingTierOnly") private var pendingOnboardingTierOnly = false
    @State private var showOnboarding = false
    @State private var onboardingStartPage = 0
    @Environment(LicenseService.self) private var license
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    #if os(iOS)
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if license.state.isReadOnly {
                ReadOnlyBanner()
            }
            tabView
        }
        .onAppear {
            if !hasCompletedOnboarding || license.state == .unset {
                onboardingStartPage = pendingOnboardingTierOnly ? Int.max : 0
                pendingOnboardingTierOnly = false
                showOnboarding = true
            }
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if !completed {
                onboardingStartPage = 0
                showOnboarding = true
            }
        }
        .onChange(of: employeeBridge.requestNewEmployeeSheet) { _, requested in
            if requested {
                // If Employees lives in the overflow Menu (iOS/iPad), TabView
                // would silently drop a `.page(.employees)` selection because
                // it's not registered as a Tab. Route through the Menu and
                // push EmployeeListView via MenuNavigationBridge.
                if layoutManager.tabBarPages.contains(.employees) {
                    selection = .page(.employees)
                } else {
                    menuNav.pendingDestination = .employees
                    selection = .page(.settings)
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showOnboarding) {
            if license.state != .unset {
                hasCompletedOnboarding = true
            }
        } content: {
            OnboardingView(isPresented: $showOnboarding, startPage: onboardingStartPage)
                .environment(employeeBridge)
                .interactiveDismissDisabled()
        }
        #else
        .sheet(isPresented: $showOnboarding) {
            if license.state != .unset {
                hasCompletedOnboarding = true
            }
        } content: {
            OnboardingView(isPresented: $showOnboarding, startPage: onboardingStartPage)
                .environment(employeeBridge)
                .interactiveDismissDisabled()
                .presentationBackgroundInteraction(.disabled)
        }
        #endif
    }

    @ViewBuilder
    private var tabView: some View {
        #if os(iOS)
        if isPad {
            iPadAdaptiveTabView
        } else {
            systemTabView
        }
        #else
        systemTabView
        #endif
    }

    @ViewBuilder
    private var systemTabView: some View {
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
        }
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        .toolbar(bridge.isEditMode ? .hidden : .visible, for: .tabBar)
        #endif
        #if os(macOS)
        .tabViewStyle(.sidebarAdaptable)
        #endif
        .environment(layoutManager)
        .environment(bridge)
        .environment(employeeBridge)
        .environment(menuNav)
        .onChange(of: selection) { _, new in
            handleSelectionChange(new)
        }
    }

    /// Leaving the Rota page exits its swap/edit mode — same effect as the
    /// checkmark. Setting the shared flag drives `RotaView.exitEditMode()`.
    private func handleSelectionChange(_ new: TabSelection) {
        if case .page(let p) = new { lastPage = p }
        if new != .page(.rota) && bridge.isEditMode {
            bridge.isEditMode = false
        }
    }

    #if os(iOS)
    /// iPad layout: render pages directly via a ZStack-based switcher (no
    /// `TabView`, so iPadOS 26's floating top tab bar never appears) and
    /// overlay a floating glass bottom bar matching the iPhone tab bar.
    /// Slide Over presents a compact h-size class — fall back to the system
    /// `TabView` there since the overlay would crowd the narrow window.
    @ViewBuilder
    private var iPadAdaptiveTabView: some View {
        if horizontalSizeClass == .compact {
            systemTabView
        } else {
            ZStack(alignment: .bottom) {
                iPadPagesContainer
                if !bridge.isEditMode {
                    FloatingTabBar(
                        pages: layoutManager.tabBarPages,
                        selection: $selection
                    )
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.35), value: bridge.isEditMode)
        }
    }

    /// Manual page switcher: keeps every page alive in a ZStack (matching
    /// `TabView` state-preservation semantics) but hides inactive ones via
    /// opacity + `allowsHitTesting`. Avoids the system `TabView` so no top
    /// tab bar can render on iPad.
    @ViewBuilder
    private var iPadPagesContainer: some View {
        ZStack {
            ForEach(layoutManager.tabBarPages) { page in
                page.destinationView
                    .opacity(activePage == page ? 1 : 0)
                    .allowsHitTesting(activePage == page)
            }
        }
        .environment(layoutManager)
        .environment(bridge)
        .environment(employeeBridge)
        .environment(menuNav)
        .onChange(of: selection) { _, new in
            handleSelectionChange(new)
        }
    }

    private var activePage: TabPage {
        if case .page(let p) = selection { return p }
        return lastPage
    }
    #endif
}

enum TabSelection: Hashable {
    case page(TabPage)
    case dots
}
