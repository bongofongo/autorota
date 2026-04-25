import Foundation
import Observation

@MainActor
@Observable
final class LicenseService {
    private(set) var state: LicenseState = .unset
    private let backend: LicenseBackend

    init(backend: LicenseBackend) {
        self.backend = backend
    }

    func refresh() async {
        let newState = await backend.loadInitialState()
        applyState(newState)
    }

    func startTrial() async throws {
        let newState = try await backend.startTrial()
        applyState(newState)
    }

    func purchase(_ tier: Tier) async throws {
        let newState = try await backend.purchase(tier)
        applyState(newState)
    }

    func restorePurchases() async throws {
        let newState = try await backend.restorePurchases()
        applyState(newState)
    }

    func displayPrice(for tier: Tier) -> String {
        backend.displayPrice(for: tier)
    }

    /// Test-only: force a state for previews / debug menu without going through
    /// the backend.
    func forceState(_ newState: LicenseState) {
        applyState(newState)
    }

    private func applyState(_ newState: LicenseState) {
        state = newState
        LicenseGate.shared.update(state: newState)
    }
}
