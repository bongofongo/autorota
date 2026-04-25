import Foundation
import Testing
@testable import AutorotaApp

@MainActor
struct LicenseServiceTests {

    @Test
    func unsetByDefault() async {
        let backend = StubBackend(initialState: .unset)
        let service = LicenseService(backend: backend)
        await service.refresh()
        #expect(service.state == .unset)
        #expect(LicenseGate.shared.allowsMutation == false)
    }

    @Test
    func startTrialMovesToTrialState() async throws {
        let backend = StubBackend(initialState: .unset)
        let service = LicenseService(backend: backend)
        try await service.startTrial()
        if case .trial(_, let days) = service.state {
            #expect(days == LicenseDuration.trialDays)
        } else {
            Issue.record("Expected trial state, got \(service.state)")
        }
        #expect(LicenseGate.shared.allowsMutation == true)
    }

    @Test
    func purchaseMovesToPurchasedState() async throws {
        let backend = StubBackend(initialState: .unset)
        let service = LicenseService(backend: backend)
        try await service.purchase(.localManager)
        #expect(service.state == .purchased(tier: .localManager))
        #expect(LicenseGate.shared.allowsMutation == true)
    }

    @Test
    func expiredStateMakesGateReadOnly() async {
        let backend = StubBackend(initialState: .expired(previousTier: .localManager))
        let service = LicenseService(backend: backend)
        await service.refresh()
        #expect(service.state.isReadOnly)
        #expect(LicenseGate.shared.allowsMutation == false)
    }

    @Test
    func trialEvaluationExpiresAfterSevenDays() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dayLater = start.addingTimeInterval(86_400)
        let eightDaysLater = start.addingTimeInterval(8 * 86_400)

        let stillTrial = MockLicenseBackend.evaluateTrial(startedAt: start, now: dayLater)
        if case .trial(_, let days) = stillTrial {
            #expect(days == 6)
        } else {
            Issue.record("Expected trial, got \(stillTrial)")
        }

        let expired = MockLicenseBackend.evaluateTrial(startedAt: start, now: eightDaysLater)
        #expect(expired == .expired(previousTier: .localManager))
    }

    @Test
    func purchaseFailedForUnavailableTier() async {
        let backend = MockLicenseBackend()
        let service = LicenseService(backend: backend)
        await #expect(throws: LicenseError.self) {
            try await service.purchase(.employee)
        }
    }
}

/// Pure stub: returns whatever state was passed in. Bypasses Keychain so tests
/// don't pollute the simulator's keychain or interfere with each other.
private final class StubBackend: LicenseBackend, @unchecked Sendable {
    private let initialState: LicenseState
    init(initialState: LicenseState) { self.initialState = initialState }

    func loadInitialState() async -> LicenseState { initialState }
    func startTrial() async throws -> LicenseState {
        .trial(startedAt: Date(), daysRemaining: LicenseDuration.trialDays)
    }
    func purchase(_ tier: Tier) async throws -> LicenseState {
        guard tier.isAvailable else { throw LicenseError.purchaseFailed("not available") }
        return .purchased(tier: tier)
    }
    func restorePurchases() async throws -> LicenseState { initialState }
    func displayPrice(for tier: Tier) -> String { "$0" }
}
