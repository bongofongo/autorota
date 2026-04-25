import Foundation
import SwiftUI

/// Persistent in-app locale override. `nil` means follow system; otherwise the
/// stored BCP-47 identifier overrides date/number formatting via `\.locale`
/// and selects which `.lproj` bundle SwiftUI loads at startup.
///
/// Live `\.locale` env updates take effect immediately. `Bundle.main`
/// `.localizedString(...)` lookups are pinned at app launch via the
/// `AppleLanguages` UserDefaults key, so a relaunch is required for catalog
/// strings to switch fully — Settings shows a note explaining this.
@Observable
final class LocaleManager {
    static let storageKey = "selectedLocaleIdentifier"
    static let appleLanguagesKey = "AppleLanguages"

    /// Locales the app declares support for. Order drives the picker.
    /// Keep in sync with `knownRegions` in the Xcode project + the
    /// xcstrings catalog locales.
    static let supportedLocales: [String] = [
        "en",
        "zh-Hans",
        "zh-Hant",
        "ar",
        "bn",
        "hi",
        "es",
    ]

    /// `nil` = match system. Stored value is one of `supportedLocales`.
    var selectedIdentifier: String? {
        didSet { persist() }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        if let stored, Self.supportedLocales.contains(stored) {
            selectedIdentifier = stored
        } else {
            selectedIdentifier = nil
        }
    }

    /// The locale to apply via `.environment(\.locale, ...)`. When the user
    /// has chosen "match system", returns `Locale.current`.
    var effectiveLocale: Locale {
        if let id = selectedIdentifier {
            return Locale(identifier: id)
        }
        return Locale.current
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let id = selectedIdentifier {
            defaults.set(id, forKey: Self.storageKey)
            defaults.set([id], forKey: Self.appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        }
    }
}
