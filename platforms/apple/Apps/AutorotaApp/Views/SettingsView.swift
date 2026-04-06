import SwiftUI

enum AppCurrency: String, CaseIterable {
    case usd, gbp, eur

    var label: String {
        switch self {
        case .usd: "USD ($)"
        case .gbp: "GBP (£)"
        case .eur: "EUR (€)"
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
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
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

struct SettingsView: View {
    @AppStorage("appAppearance") private var appearance: String = AppAppearance.system.rawValue
    @AppStorage("appCurrency") private var currency: String = AppCurrency.usd.rawValue
    @AppStorage("exportDefaultLayout") private var exportDefaultLayout: String = "employee_by_weekday"
    @AppStorage("exportDefaultFormat") private var exportDefaultFormat: String = "csv"
    @AppStorage("exportDefaultProfile") private var exportDefaultProfile: String = "staff_schedule"
    @AppStorage("exportShowShiftName") private var exportShowShiftName: Bool = true
    @AppStorage("exportShowTimes") private var exportShowTimes: Bool = true
    @AppStorage("exportShowRole") private var exportShowRole: Bool = true
    @Environment(TabLayoutManager.self) private var layoutManager
    @Environment(AutorotaSyncEngine.self) private var syncEngine

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    var body: some View {
        NavigationStack {
            Form {
                // Navigation links for pages not in the tab bar
                if !layoutManager.hiddenPages.isEmpty {
                    Section("Other Pages") {
                        ForEach(layoutManager.hiddenPages) { page in
                            NavigationLink {
                                page.destinationView
                            } label: {
                                Label(page.title, systemImage: page.systemImage)
                            }
                            .tint(.primary)
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Experience") {
                    Picker("Currency", selection: $currency) {
                        ForEach(AppCurrency.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    
                    DisclosureGroup("Export Defaults") {
                        Picker("Layout", selection: $exportDefaultLayout) {
                            Text("By Employee").tag("employee_by_weekday")
                            Text("By Shift").tag("shift_by_weekday")
                        }
                        
                        Picker("Format", selection: $exportDefaultFormat) {
                            Text("CSV").tag("csv")
                            Text("JSON").tag("json")
                        }
                        
                        Picker("Profile", selection: $exportDefaultProfile) {
                            Text("Staff Schedule").tag("staff_schedule")
                            Text("Manager Report").tag("manager_report")
                        }
                        
                        Toggle("Show Shift Name", isOn: $exportShowShiftName)
                        Toggle("Show Times", isOn: $exportShowTimes)
                        Toggle("Show Role", isOn: $exportShowRole)
                    }
                    
                    DisclosureGroup("Layout") {
                        Section {
                            ForEach(layoutManager.configurableTabBarPages) { page in
                                HStack {
                                    Label(page.title, systemImage: page.systemImage)
                                    Spacer()
                                    Button {
                                        withAnimation { layoutManager.removeFromTabBar(page) }
                                    } label: {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                        } header: {
                            Text("Tab Bar (\(layoutManager.configurableTabBarPages.count) of \(TabPage.maxConfigurable))")
                        }
                        
                        if !layoutManager.hiddenPages.isEmpty {
                            Section {
                                ForEach(layoutManager.hiddenPages) { page in
                                    HStack {
                                        Label(page.title, systemImage: page.systemImage)
                                        Spacer()
                                        Button {
                                            withAnimation { layoutManager.addToTabBar(page) }
                                        } label: {
                                            Image(systemName: "arrow.up.circle.fill")
                                                .foregroundStyle(layoutManager.configurableTabBarPages.count >= TabPage.maxConfigurable ? .gray : .blue)
                                        }
                                        .disabled(layoutManager.configurableTabBarPages.count >= TabPage.maxConfigurable)
                                    }
                                }
                            } header: {
                                Text("Hidden")
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        HelpView()
                    } label: {
                        Label("Help & Guide", systemImage: "questionmark.circle")
                    }
                }


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
        }
    }
}
