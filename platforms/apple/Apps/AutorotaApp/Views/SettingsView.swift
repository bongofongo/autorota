import SwiftUI
import TipKit
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

struct SettingsView: View {
    @AppStorage("appAppearance") private var appearance: String = AppAppearance.system.rawValue
    @AppStorage("colorBlindnessMode") private var colorBlindnessMode: String = ColorBlindnessMode.none.rawValue
    @AppStorage("appCurrency") private var currency: String = AppCurrency.usd.rawValue
    @AppStorage("exportDefaultLayout") private var exportDefaultLayout: String = "employee_by_weekday"
    @AppStorage("exportDefaultFormat") private var exportDefaultFormat: String = "csv"
    @AppStorage("exportDefaultProfile") private var exportDefaultProfile: String = "staff_schedule"
    @AppStorage("exportShowShiftName") private var exportShowShiftName: Bool = true
    @AppStorage("exportShowTimes") private var exportShowTimes: Bool = true
    @AppStorage("exportShowRole") private var exportShowRole: Bool = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @Environment(TabLayoutManager.self) private var layoutManager
    @Environment(AutorotaSyncEngine.self) private var syncEngine
    @Environment(LocaleManager.self) private var localeManager
    @Environment(LicenseService.self) private var license
    @State private var showReplayConfirm = false
    @State private var replayErrorMessage: String?
    private let exportProfileTip = ExportProfileTip()

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    var body: some View {
        @Bindable var localeManager = localeManager
        return NavigationStack {
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

                Section {
                    Picker("settings.language.title", selection: $localeManager.selectedIdentifier) {
                        Text("settings.language.match_system").tag(String?.none)
                        Text(verbatim: "English").tag(String?("en"))
                        Text(verbatim: "中文（简体）").tag(String?("zh-Hans"))
                        Text(verbatim: "中文（繁體）").tag(String?("zh-Hant"))
                        Text(verbatim: "العربية").tag(String?("ar"))
                        Text(verbatim: "বাংলা").tag(String?("bn"))
                        Text(verbatim: "हिन्दी").tag(String?("hi"))
                        Text(verbatim: "Español").tag(String?("es"))
                    }
                } header: {
                    Text("settings.language.section_header")
                } footer: {
                    Text("settings.language.restart_note")
                }

                Section {
                    Picker("Color Vision", selection: $colorBlindnessMode) {
                        ForEach(ColorBlindnessMode.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    AccessibilityPaletteSwatches(
                        palette: AccessibilityPalette.palette(
                            for: ColorBlindnessMode(rawValue: colorBlindnessMode) ?? .none
                        )
                    )
                } header: {
                    Text("Accessibility")
                } footer: {
                    Text("Adjusts availability, status, and chart colors so they remain distinguishable for the selected type of color vision.")
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
                        .popoverTip(exportProfileTip)
                        
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
                                    .accessibilityLabel("Hide \(page.titleString) from tab bar")
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
                                        .accessibilityLabel("Add \(page.titleString) to tab bar")
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
                    Button {
                        showReplayConfirm = true
                    } label: {
                        Label("settings.replay_onboarding", systemImage: "arrow.counterclockwise.circle")
                    }
                    .tint(.primary)
                }


                SubscriptionSettingsSection()

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
            .confirmationDialog(
                "settings.replay_onboarding.confirm.title",
                isPresented: $showReplayConfirm,
                titleVisibility: .visible
            ) {
                Button("settings.replay_onboarding.keep_data") {
                    replayOnboarding(reseed: false)
                }
                Button("settings.replay_onboarding.reset_sample", role: .destructive) {
                    replayOnboarding(reseed: true)
                }
                Button("onboarding.alert.cancel", role: .cancel) {}
            } message: {
                Text("settings.replay_onboarding.confirm.body")
            }
            .alert(
                "settings.replay_onboarding.error.title",
                isPresented: Binding(
                    get: { replayErrorMessage != nil },
                    set: { if !$0 { replayErrorMessage = nil } }
                )
            ) {
                Button("onboarding.alert.ok") { replayErrorMessage = nil }
            } message: {
                Text(replayErrorMessage ?? "")
            }
        }
    }

    private func replayOnboarding(reseed: Bool) {
        if reseed {
            do {
                _ = try seedSampleData(overwrite: true)
            } catch let error as FfiError {
                replayErrorMessage = localizeReplayError(error)
                return
            } catch {
                replayErrorMessage = error.localizedDescription
                return
            }
        }
        try? Tips.resetDatastore()
        hasCompletedOnboarding = false
    }

    private func localizeReplayError(_ error: FfiError) -> String {
        let code: ErrorCode
        switch error {
        case .Db(let c, _), .NotFound(let c, _), .InvalidArgument(let c, _):
            code = c
        }
        return localizeError(code: code, localeId: Locale.current.identifier)
    }
}

private struct AccessibilityPaletteSwatches: View {
    let palette: AccessibilityPalette

    var body: some View {
        HStack(spacing: 8) {
            swatch(palette.yes, label: "Yes")
            swatch(palette.maybe, label: "Maybe")
            swatch(palette.no, label: "No")
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ color: Color, label: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
