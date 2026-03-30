import SwiftUI

enum TabPage: String, CaseIterable, Codable, Identifiable {
    case rota
    case employees
    case templates
    case overrides
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rota: "Rota"
        case .employees: "Employees"
        case .templates: "Templates"
        case .overrides: "Overrides"
        case .settings: "Menu"
        }
    }

    var systemImage: String {
        switch self {
        case .rota: "calendar"
        case .employees: "person.2"
        case .templates: "clock"
        case .overrides: "exclamationmark.circle"
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
        case .settings: SettingsView()
        }
    }

    /// Pages the user can add/remove from the tab bar. Settings is always pinned.
    static let configurablePages: [TabPage] = [.rota, .employees, .templates, .overrides]

    #if os(iOS)
    static let defaultTabBar: [TabPage] = [.rota, .employees, .templates]
    static let maxConfigurable = 3
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
    var tabBarPages: [TabPage] {
        configurableTabBarPages + [.settings]
    }

    var hiddenPages: [TabPage] {
        TabPage.configurablePages.filter { !configurableTabBarPages.contains($0) }
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
