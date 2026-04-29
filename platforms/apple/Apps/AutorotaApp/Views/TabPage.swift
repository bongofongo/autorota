import SwiftUI
#if os(iOS)
import UIKit
#endif

enum TabPage: String, CaseIterable, Codable, Identifiable {
    case rota
    case employees
    case templates
    case overrides
    case history
    case analytics
    case export
    case settings

    var id: String { rawValue }

    /// Localized title for `Tab` / `Label` initializers (which accept
    /// `LocalizedStringKey` and auto-resolve via the active bundle).
    var title: LocalizedStringKey {
        switch self {
        case .rota: "Rota"
        case .employees: "Employees"
        case .templates: "Shifts"
        case .overrides: "Exceptions"
        case .history: "Edit Log"
        case .analytics: "Analytics"
        case .export: "Export"
        case .settings: "Menu"
        }
    }

    /// Resolved title `String` for runtime contexts that need an actual string
    /// (e.g. parameterized accessibility labels).
    var titleString: String {
        switch self {
        case .rota: String(localized: "Rota")
        case .employees: String(localized: "Employees")
        case .templates: String(localized: "Shifts")
        case .overrides: String(localized: "Exceptions")
        case .history: String(localized: "Edit Log")
        case .analytics: String(localized: "Analytics")
        case .export: String(localized: "Export")
        case .settings: String(localized: "Menu")
        }
    }

    var systemImage: String {
        switch self {
        case .rota: "calendar"
        case .employees: "person.2"
        case .templates: "clock"
        case .overrides: "exclamationmark.circle"
        case .history: "clock.arrow.circlepath"
        case .analytics: "chart.bar"
        case .export: "square.and.arrow.up"
        case .settings: "line.3.horizontal"
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .rota: RotaView()
        case .employees: EmployeeListView()
        case .templates: ShiftTemplateListView()
        case .overrides: OverridesTabView()
        case .history: EditLogView()
        case .analytics: AnalyticsView()
        case .export: ExportTabView()
        case .settings: SettingsView()
        }
    }

    /// Pages the user can add/remove from the tab bar. Settings is always pinned.
    static let configurablePages: [TabPage] = [.rota, .employees, .templates, .overrides, .history, .analytics, .export]

    #if os(iOS)
    /// iPad has more room than iPhone — give it 4 slots and a richer default.
    static var defaultTabBar: [TabPage] {
        UIDevice.current.userInterfaceIdiom == .pad
            ? [.rota, .employees, .templates, .overrides]
            : [.rota, .employees, .templates]
    }
    static var maxConfigurable: Int {
        UIDevice.current.userInterfaceIdiom == .pad ? 4 : 3
    }
    #else
    static let defaultTabBar: [TabPage] = [.rota, .employees, .templates, .overrides]
    static let maxConfigurable = 4
    #endif
}

@Observable
class TabLayoutManager {
    /// User-configurable pages (excludes Settings which is always pinned last).
    private(set) var configurableTabBarPages: [TabPage]

    /// Full tab bar: configurable pages + Settings pinned at the end.
    /// macOS shows the full sidebar (all configurable pages) so the overflow
    /// Menu is unnecessary — every page lives directly in the sidebar.
    var tabBarPages: [TabPage] {
        #if os(macOS)
        TabPage.configurablePages + [.settings]
        #else
        configurableTabBarPages + [.settings]
        #endif
    }

    var hiddenPages: [TabPage] {
        #if os(macOS)
        []
        #else
        TabPage.configurablePages.filter { !configurableTabBarPages.contains($0) }
        #endif
    }

    private static let storageKey = "tabBarLayout"

    init() {
        if let data = UserDefaults.standard.string(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([TabPage].self, from: Data(data.utf8)) {
            self.configurableTabBarPages = decoded.filter { $0 != .settings }
        } else {
            self.configurableTabBarPages = TabPage.defaultTabBar
        }
    }

    func addToTabBar(_ page: TabPage) {
        guard page != .settings,
              !configurableTabBarPages.contains(page),
              configurableTabBarPages.count < TabPage.maxConfigurable else { return }
        configurableTabBarPages.append(page)
        persist()
    }

    func removeFromTabBar(_ page: TabPage) {
        guard page != .settings else { return }
        configurableTabBarPages.removeAll { $0 == page }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tabBarPages),
           let string = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(string, forKey: Self.storageKey)
        }
    }
}
