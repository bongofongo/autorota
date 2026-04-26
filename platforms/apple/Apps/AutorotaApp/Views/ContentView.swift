import SwiftUI

struct ContentView: View {
    @State private var layoutManager = TabLayoutManager()
    @State private var bridge = RotaUIBridge()
    @State private var employeeBridge = EmployeeUIBridge()
    @State private var selection: TabSelection = .page(.rota)
    @State private var lastPage: TabPage = .rota
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    #if os(iOS)
    @AppStorage("tabBarEdge") private var tabBarEdgeRaw: String = TabBarEdge.trailing.rawValue
    #endif
    @State private var showOnboarding = false
    @Environment(LicenseService.self) private var license
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    #if os(iOS)
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var tabBarEdge: TabBarEdge {
        TabBarEdge(rawValue: tabBarEdgeRaw) ?? .trailing
    }
    #endif

    /// The dots tab is only shown in portrait iPhone while the Rota tab is
    /// active. Landscape iPhone uses a floating overlay inside `RotaView`
    /// instead, because the iOS 26 floating tab bar leading-aligns in
    /// landscape when a `.search` role tab is present.
    /// Use `lastPage` (not `selection`) so the dots tab stays visible while
    /// the `.dots` selection is in flight — otherwise SwiftUI removes the tab
    /// mid-transition and auto-selects the first tab, causing a visible glitch.
    /// iPad uses the floating rail/bar instead and never renders the dots tab.
    private var showsDotsTab: Bool {
        #if os(iOS)
        if isPad { return false }
        guard verticalSizeClass == .regular else { return false }
        return lastPage == .rota
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if license.state.isReadOnly {
                ReadOnlyBanner()
            }
            tabView
        }
        .onAppear {
            if !hasCompletedOnboarding || license.state == .unset {
                showOnboarding = true
            }
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if !completed {
                showOnboarding = true
            }
        }
        .onChange(of: employeeBridge.requestNewEmployeeSheet) { _, requested in
            if requested {
                selection = .page(.employees)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showOnboarding) {
            if license.state != .unset {
                hasCompletedOnboarding = true
            }
        } content: {
            OnboardingView(isPresented: $showOnboarding)
                .environment(employeeBridge)
                .interactiveDismissDisabled()
        }
        #else
        .sheet(isPresented: $showOnboarding) {
            if license.state != .unset {
                hasCompletedOnboarding = true
            }
        } content: {
            OnboardingView(isPresented: $showOnboarding)
                .environment(employeeBridge)
                .interactiveDismissDisabled()
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
                selection = .page(.rota)
                lastPage = .rota
                if bridge.isEditMode {
                    bridge.isEditMode = false
                } else {
                    bridge.overflowOpen.toggle()
                }
            case .page(let p):
                lastPage = p
            }
        }
    }

    #if os(iOS)
    /// iPad layout: render pages directly via a ZStack-based switcher (no
    /// `TabView`, so iPadOS 26's floating top tab bar never appears) and
    /// overlay a floating glass rail (landscape) or bottom bar (portrait).
    /// Slide Over presents a compact h-size class — fall back to the system
    /// `TabView` there since the rail would crowd the narrow window.
    @ViewBuilder
    private var iPadAdaptiveTabView: some View {
        if horizontalSizeClass == .compact {
            systemTabView
        } else {
            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height
                let alignment: Alignment = isLandscape ? tabBarEdge.alignment : .bottom
                ZStack(alignment: alignment) {
                    iPadPagesContainer
                    FloatingTabBar(
                        pages: layoutManager.tabBarPages,
                        selection: $selection,
                        axis: isLandscape ? .vertical : .horizontal
                    )
                    .padding(16)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(.snappy(duration: 0.25), value: isLandscape)
            }
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
        .onChange(of: selection) { _, new in
            if case .page(let p) = new { lastPage = p }
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
