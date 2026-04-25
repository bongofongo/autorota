import Foundation

/// Locale → display-price mapping for the MVP. Static placeholders until
/// `LiveLicenseBackend` returns `Product.displayPrice` from real StoreKit.
enum PricingCatalog {
    static func displayPrice(for tier: Tier, locale: Locale = .current) -> String {
        guard tier == .localManager else { return "" }
        let region = locale.region?.identifier ?? "US"
        switch region {
        case "GB":
            return "£15.99"
        case "DE", "FR", "ES", "IT", "NL", "IE", "AT", "BE", "PT", "FI", "GR":
            return "€17.99"
        case "IN":
            return "₹1,499"
        case "BD":
            return "৳2,199"
        case "CN":
            return "¥139"
        case "TW", "HK":
            return "NT$599"
        case "SA", "AE":
            return "ر.س 74.99"
        default:
            return "$19.99"
        }
    }
}
