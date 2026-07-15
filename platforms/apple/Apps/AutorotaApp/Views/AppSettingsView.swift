import SwiftUI
import AutorotaKit
#if canImport(UIKit)
import UIKit
#endif

/// Preferences page pushed from the Menu landing: appearance, language, currency,
/// accessibility, and (iOS) tab-bar layout. Lifted out of the old monolithic
/// `SettingsView` so the Menu can act as a clean hub.
struct AppSettingsView: View {
    @AppStorage("appAppearance") private var appearance: String = AppAppearance.system.rawValue
    @AppStorage("colorBlindnessMode") private var colorBlindnessMode: String = ColorBlindnessMode.none.rawValue
    @AppStorage("appCurrency") private var currency: String = AppCurrency.usd.rawValue
    @Environment(TabLayoutManager.self) private var layoutManager
    @Environment(LocaleManager.self) private var localeManager

    var body: some View {
        @Bindable var localeManager = localeManager
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            #if !os(macOS)
            Section {
                AppIconPicker()
            } header: {
                Text("App Icon")
            }
            #endif

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
                Picker("Currency", selection: $currency) {
                    ForEach(AppCurrency.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            } header: {
                Text("Currency")
            } footer: {
                Text("Used to display employee wages and totals.")
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

            #if !os(macOS)
            Section {
                DisclosureGroup("Tab Bar Layout") {
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
            #endif

            #if DEBUG
            DebugSampleSection()
            DebugResetSection()
            #endif
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Settings")
    }
}

#if !os(macOS)
/// Selectable home-screen icon designs. Each case maps to an alternate icon
/// set in the asset catalog (`nil` = the primary `AppIcon`).
enum AppIconOption: String, CaseIterable, Identifiable {
    case azure
    case jazz
    case latte

    var id: String { rawValue }

    var alternateIconName: String? {
        switch self {
        case .azure: nil
        case .jazz: "AppIconJazz"
        case .latte: "AppIconLatte"
        }
    }

    var previewImageName: String {
        switch self {
        case .azure: "AppIconPreviewDefault"
        case .jazz: "AppIconPreviewJazz"
        case .latte: "AppIconPreviewLatte"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .azure: "Default"
        case .jazz: "Jazz"
        case .latte: "Latte"
        }
    }

    static var current: AppIconOption {
        let name = UIApplication.shared.alternateIconName
        return allCases.first { $0.alternateIconName == name } ?? .azure
    }
}

struct AppIconPicker: View {
    @State private var selection: AppIconOption = .current

    var body: some View {
        HStack(spacing: 24) {
            ForEach(AppIconOption.allCases) { option in
                Button {
                    select(option)
                } label: {
                    VStack(spacing: 6) {
                        Image(option.previewImageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(
                                        selection == option ? Color.accentColor : Color.primary.opacity(0.1),
                                        lineWidth: selection == option ? 3 : 1
                                    )
                            )
                        Text(option.label)
                            .font(.caption)
                            .foregroundStyle(selection == option ? Color.accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(option.label))
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func select(_ option: AppIconOption) {
        guard option != selection else { return }
        let previous = selection
        selection = option
        // The system confirmation alert is unavoidable: it is shown on a
        // private window by SpringBoard and none of the known suppression
        // tricks work on current iOS.
        UIApplication.shared.setAlternateIconName(option.alternateIconName) { error in
            if error != nil {
                Task { @MainActor in selection = previous }
            }
        }
    }
}
#endif

struct AccessibilityPaletteSwatches: View {
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
