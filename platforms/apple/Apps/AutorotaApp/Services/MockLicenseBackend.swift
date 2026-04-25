import Foundation

/// In-memory + Keychain-backed license backend. No network. Reads trial-start
/// timestamp from Keychain to compute elapsed days. `purchase` and
/// `restorePurchases` always succeed and persist a fake token.
///
/// Tests can inject a `clock` closure to control time-of-day for trial expiry.
final class MockLicenseBackend: LicenseBackend, @unchecked Sendable {
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    func loadInitialState() async -> LicenseState {
        if let token = KeychainStore.string(forKey: KeychainStore.Key.licenseToken),
           !token.isEmpty {
            let tier = KeychainStore.string(forKey: KeychainStore.Key.currentTier)
                .flatMap(Tier.init(rawValue:)) ?? .localManager
            return .purchased(tier: tier)
        }

        if let started = KeychainStore.date(forKey: KeychainStore.Key.trialStartedAt) {
            return Self.evaluateTrial(startedAt: started, now: clock())
        }

        return .unset
    }

    func startTrial() async throws -> LicenseState {
        if KeychainStore.date(forKey: KeychainStore.Key.trialStartedAt) != nil {
            throw LicenseError.trialAlreadyUsed
        }
        let now = clock()
        try KeychainStore.setDate(now, forKey: KeychainStore.Key.trialStartedAt)
        return .trial(startedAt: now, daysRemaining: LicenseDuration.trialDays)
    }

    func purchase(_ tier: Tier) async throws -> LicenseState {
        guard tier.isAvailable else {
            throw LicenseError.purchaseFailed("Tier not yet available")
        }
        try KeychainStore.setString("mock-\(UUID().uuidString)", forKey: KeychainStore.Key.licenseToken)
        try KeychainStore.setString(tier.rawValue, forKey: KeychainStore.Key.currentTier)
        return .purchased(tier: tier)
    }

    func restorePurchases() async throws -> LicenseState {
        await loadInitialState()
    }

    func displayPrice(for tier: Tier) -> String {
        PricingCatalog.displayPrice(for: tier)
    }

    static func evaluateTrial(startedAt: Date, now: Date) -> LicenseState {
        let elapsed = now.timeIntervalSince(startedAt)
        let elapsedDays = Int(elapsed / 86_400)
        let remaining = LicenseDuration.trialDays - elapsedDays
        if remaining <= 0 {
            return .expired(previousTier: .localManager)
        }
        return .trial(startedAt: startedAt, daysRemaining: remaining)
    }
}
