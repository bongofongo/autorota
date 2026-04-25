import Foundation

/// Strategy interface for license persistence + purchase handling. The
/// `LicenseService` observable owns one of these and forwards calls. Two
/// concrete impls: `MockLicenseBackend` (ships now, no network) and
/// `LiveLicenseBackend` (StoreKit 2, stubbed for now).
protocol LicenseBackend: Sendable {
    func loadInitialState() async -> LicenseState
    func startTrial()        async throws -> LicenseState
    func purchase(_ tier: Tier) async throws -> LicenseState
    func restorePurchases()  async throws -> LicenseState
    func displayPrice(for tier: Tier) -> String
}
