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
    @Environment(DemoModeController.self) private var demo
    @Environment(TutorialSpotlightModel.self) private var spotlightModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            if demo.isActive {
                DemoBanner()
            } else if license.state.isReadOnly {
                ReadOnlyBanner()
            }
            tabView
        }
        .onAppear {
            if (!hasCompletedOnboarding || license.state == .unset) && !demo.isActive {
                onboardingStartPage = pendingOnboardingTierOnly ? Int.max : 0
                pendingOnboardingTierOnly = false
                showOnboarding = true
            }
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if !completed && !demo.isActive {
                onboardingStartPage = 0
                showOnboarding = true
            }
        }
        .onChange(of: demo.isActive) { wasActive, active in
            // Entering demo from the tier picker dismisses onboarding;
            // leaving it with no license routes straight back to the
            // tier picker (skipping the marketing slides).
            if active {
                showOnboarding = false
            } else if wasActive && license.state == .unset {
                onboardingStartPage = Int.max
                showOnboarding = true
            }
            // Spotlight frames are only tracked mid-demo; seed the tour
            // with the tab the user is already on.
            spotlightModel.isTracking = active
            if active {
                demo.noteTutorialEvent(.tabSelected(activeTabPage))
            } else {
                spotlightModel.reset()
            }
        }
        #if os(iOS)
        .overlay {
            // ZStack + transition so guidance eases in after the page
            // settles and drops out quickly (the id remounts per sub-step,
            // so each new tooltip entry gets the full delay + fade).
            ZStack {
                if let spot = demo.currentSpotlight {
                    TutorialSpotlightHost(spotlight: spot)
                        .id(spot.instructionKey)
                        .transition(TutorialFade.transition(isFirstOfSet: spot.index == 1))
                }
            }
            .animation(
                reduceMotion ? nil : .default,
                value: demo.currentSpotlight
            )
        }
        #endif
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
                // Explicit opaque backdrop: a cover presented near another
                // sheet's dismissal can otherwise render with a clear
                // background, floating the tier picker over the app.
                .presentationBackground(Color(uiColor: .systemBackground))
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
        if case .page(let p) = new {
            lastPage = p
            demo.noteTutorialEvent(.tabSelected(p))
        }
        if new != .page(.rota) && bridge.isEditMode {
            bridge.isEditMode = false
        }
    }

    /// The page currently on screen, regardless of platform layout.
    private var activeTabPage: TabPage {
        if case .page(let p) = selection { return p }
        return lastPage
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
                    .opacity(activeTabPage == page ? 1 : 0)
                    .allowsHitTesting(activeTabPage == page)
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

    #endif
}

#if os(iOS)
/// Resolves the active spotlight target to an on-screen frame and mounts
/// the overlay. Guidance only renders in the right context: page-bound
/// targets need their tab current AND a registered frame. Tab-switch
/// prompts are never highlighted (the system tab bar can't be located
/// reliably) — they float as a hole-less tooltip and the user finds the
/// tab themselves.
private struct TutorialSpotlightHost: View {
    let spotlight: DemoSpotlight

    @Environment(TutorialSpotlightModel.self) private var model
    @Environment(DemoModeController.self) private var demo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How the active target resolves on screen.
    private enum Resolution {
        /// Dim the screen with a spotlight hole at this frame.
        case hole(CGRect)
        /// No locatable frame, but guidance is still possible — float the
        /// tooltip without a hole.
        case floating
    }

    var body: some View {
        GeometryReader { geo in
            let resolution = resolve(geo: geo)
            // ZStack + transition: guidance breathes in when the user
            // reaches the target's context and gets out of the way fast
            // when they leave it.
            ZStack {
                if let resolution {
                    TutorialSpotlightOverlay(
                        spotlight: spotlight,
                        targetFrame: {
                            if case .hole(let frame) = resolution { return frame }
                            return nil
                        }(),
                        onSkip: { demo.skipCurrentSubStep() }
                    )
                    .transition(TutorialFade.transition(isFirstOfSet: spotlight.index == 1))
                }
            }
            .animation(
                reduceMotion ? nil : .default,
                value: resolution == nil
            )
        }
    }

    /// nil = show nothing (wrong page / target off screen).
    private func resolve(geo: GeometryProxy) -> Resolution? {
        // Page-bound targets: only on their own tab, and only when the
        // target view has registered a frame (it's actually on screen) —
        // except pure prompts, which float without ever having a frame.
        if let required = spotlight.target.requiredTab {
            guard demo.currentTab == required else { return nil }
            if let frame = model.frames[spotlight.target] {
                return .hole(frame)
            }
            return spotlight.target.floatsWithoutFrame ? .floating : nil
        }
        // Tab-switch prompts: floating tooltip only, no highlight.
        return .floating
    }
}
#endif

enum TabSelection: Hashable {
    case page(TabPage)
    case dots
}
