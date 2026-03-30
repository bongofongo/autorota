import SwiftUI

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
    @Environment(TabLayoutManager.self) private var layoutManager

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
            .navigationTitle("Menu")
        }
    }
}
