import Foundation

/// Locale → display-price mapping for the MVP. Static placeholders until
/// `LiveLicenseBackend` returns `Product.displayPrice` from real StoreKit.
///
/// The Local Manager tier is currently free for early users — `displayPrice`
/// returns a localized "Free" label. Restore the region → price switch below
/// (and re-enable the `price_note`) when paid pricing lands.
enum PricingCatalog {
    static func displayPrice(for tier: Tier, locale: Locale = .current) -> String {
        guard tier == .localManager else { return "" }
        return String(localized: "license.tier.local_manager.price_free")
    }

    /// Whether the resolved price is the promotional free tier (no monetary
    /// amount). Used to hide the "one-time" note next to a "Free" price.
    static func isFree(for tier: Tier, locale: Locale = .current) -> Bool {
        tier == .localManager
    }
}
