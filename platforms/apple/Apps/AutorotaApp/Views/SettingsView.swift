import SwiftUI
import AutorotaKit

enum AppCurrency: String, CaseIterable {
    case usd, gbp, eur

    var label: String {
        switch self {
        case .usd: String(localized: "USD ($)")
        case .gbp: String(localized: "GBP (£)")
        case .eur: String(localized: "EUR (€)")
        }
    }

    var symbol: String {
        switch self {
        case .usd: "$"
        case .gbp: "£"
        case .eur: "€"
        }
    }
}

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The Menu tab — a landing/hub. Surfaces the overflow "Other Pages" as a tappable
/// icon-tile grid, then pushes into grouped sub-pages (Settings, Help, Subscription)
/// and shows iCloud sync status inline.
struct SettingsView: View {
    @Environment(TabLayoutManager.self) private var layoutManager
    @Environment(AutorotaSyncEngine.self) private var syncEngine
    @Environment(MenuNavigationBridge.self) private var menuNav
    /// Drives programmatic pushes from `MenuNavigationBridge` (e.g. an "Add
    /// employee" CTA fired while Employees lives in the overflow Menu).
    @State private var navPath: [TabPage] = []
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var vSizeClass
    #endif

    private func consumePendingDestination() {
        guard let dest = menuNav.pendingDestination else { return }
        navPath = [dest]
        menuNav.pendingDestination = nil
    }

    /// Cap on a single tile's width so cells stay compact and the grid centers on
    /// wide screens instead of stretching edge-to-edge.
    private let maxTileWidth: CGFloat = 150

    /// 2 columns in portrait (2x2), 4 in landscape (single row of four). iPhone
    /// landscape reports a compact vertical size class; iPad/macOS stay at 2.
    private var tileColumnCount: Int {
        #if os(iOS)
        vSizeClass == .compact ? 4 : 2
        #else
        2
        #endif
    }

    private var tileColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: tileColumnCount)
    }

    /// Total grid width when every cell is at its max — used to cap then center.
    private var maxGridWidth: CGFloat {
        CGFloat(tileColumnCount) * maxTileWidth + CGFloat(tileColumnCount - 1) * Spacing.sm
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                // Overflow pages not in the tab bar, as an app-launcher grid.
                if !layoutManager.hiddenPages.isEmpty {
                    Section {
                        LazyVGrid(columns: tileColumns, spacing: Spacing.sm) {
                            ForEach(layoutManager.hiddenPages) { page in
                                Button {
                                    navPath.append(page)
                                } label: {
                                    pageTile(page)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: maxGridWidth)   // cap total width…
                        .frame(maxWidth: .infinity)       // …then center in the row
                        .padding(.vertical, Spacing.xs)
                        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
                        .listRowBackground(Color.clear)
                    }
                }

                Section {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    NavigationLink {
                        HelpCenterView()
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        SubscriptionView()
                    } label: {
                        Label("Subscription", systemImage: "creditcard")
                    }
                }
                .tint(.primary)

                Section("iCloud Sync") {
                    HStack {
                        Text("Status")
                        Spacer()
                        switch syncEngine.status {
                        case .idle:
                            Label("Synced", systemImage: "checkmark.icloud")
                                .foregroundStyle(.green)
                        case .syncing:
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Syncing...")
                            }
                            .foregroundStyle(.secondary)
                        case .error(let message):
                            Label("Error", systemImage: "exclamationmark.icloud")
                                .foregroundStyle(.red)
                                .help(message)
                        }
                    }
                }
            }
            .navigationTitle("Menu")
            .navigationDestination(for: TabPage.self) { page in
                // Reuse this stack — do not let the pushed page nest its own
                // NavigationStack (iOS 26 breaks navigation when stacks nest).
                page.destinationView
                    .environment(\.isMenuPushed, true)
            }
        }
        .onAppear { consumePendingDestination() }
        .onChange(of: menuNav.pendingDestination) { _, _ in consumePendingDestination() }
    }

    private func pageTile(_ page: TabPage) -> some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: page.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(height: 24)
            Text(page.title)
                .font(AppFont.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: SurfaceRadius.medium, style: .continuous)
                .fill(tileBackground)
        )
        .contentShape(Rectangle())
    }

    private var tileBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
