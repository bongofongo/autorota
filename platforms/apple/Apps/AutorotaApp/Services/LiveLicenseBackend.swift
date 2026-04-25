import Foundation
import StoreKit

/// StoreKit 2 backend. **Stub for MVP** — App Store Connect product is not yet
/// configured, so all calls currently delegate to a wrapped `MockLicenseBackend`
/// while keeping the real verification scaffolding in place behind
/// `// TODO(storekit)` markers. Flip the body of each method when the product
/// ID + .storekit config land.
final class LiveLicenseBackend: LicenseBackend, @unchecked Sendable {
    static let productId = "com.toadmountain.autorota.local_manager"

    private let fallback = MockLicenseBackend()

    func loadInitialState() async -> LicenseState {
        // TODO(storekit): verify AppTransaction.shared signature and replace.
        // do {
        //     let result = try await AppTransaction.shared
        //     if case .verified = result { return .purchased(tier: .localManager) }
        // } catch { }
        return await fallback.loadInitialState()
    }

    func startTrial() async throws -> LicenseState {
        // Trial state is local-only — Apple manages subscription introductory
        // offers, but a "free 7-day trial of a paid one-time purchase" has no
        // first-class StoreKit equivalent. Keep the trial timer in Keychain.
        try await fallback.startTrial()
    }

    func purchase(_ tier: Tier) async throws -> LicenseState {
        // TODO(storekit): real Product.purchase flow.
        // guard let product = try await Product.products(for: [Self.productId]).first else {
        //     throw LicenseError.purchaseFailed("Product not found")
        // }
        // let result = try await product.purchase()
        // switch result {
        // case .success(let verification):
        //     guard case .verified(let transaction) = verification else {
        //         throw LicenseError.purchaseFailed("Unverified transaction")
        //     }
        //     await transaction.finish()
        //     return .purchased(tier: tier)
        // case .userCancelled:
        //     return await loadInitialState()
        // case .pending:
        //     throw LicenseError.purchaseFailed("Pending approval")
        // @unknown default:
        //     throw LicenseError.purchaseFailed("Unknown StoreKit result")
        // }
        return try await fallback.purchase(tier)
    }

    func restorePurchases() async throws -> LicenseState {
        // TODO(storekit): try await AppStore.sync(); then re-evaluate entitlements.
        try await fallback.restorePurchases()
    }

    func displayPrice(for tier: Tier) -> String {
        // TODO(storekit): swap for Product.displayPrice once App Store Connect
        // product is configured.
        PricingCatalog.displayPrice(for: tier)
    }
}
