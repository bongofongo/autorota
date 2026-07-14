import Foundation

/// Locale → display-price mapping for the MVP. Static placeholders until
/// `LiveLicenseBackend` returns `Product.displayPrice` from real StoreKit.
enum PricingCatalog {
    static func displayPrice(for tier: Tier, locale: Locale = .current) -> String {
        guard tier == .localManager else { return "" }
        let region = locale.region?.identifier ?? "US"
        switch region {
        case "GB":
            return "£6.99"
        default:
            return "$6.99"
        }
    }
}
