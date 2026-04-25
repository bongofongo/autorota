import SwiftUI

struct SubscriptionSettingsSection: View {
    @Environment(LicenseService.self) private var license
    @State private var infoTier: Tier?
    @State private var isWorking: WorkingAction?
    @State private var errorMessage: String?

    private enum WorkingAction: Equatable { case purchase, restore }

    var body: some View {
        Section {
            currentTierRow
                .sheet(item: $infoTier) { tier in
                    TierInfoModal(tier: tier)
                }
                .alert(
                    "license.error.title",
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } }
                    )
                ) {
                    Button("onboarding.alert.ok") { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }

            if case .trial(_, let daysRemaining) = license.state {
                trialCountdown(daysRemaining: daysRemaining)
            }

            if showsUpgrade {
                Button {
                    runPurchase()
                } label: {
                    HStack {
                        Label("license.cta.upgrade", systemImage: "arrow.up.circle.fill")
                        Spacer()
                        if isWorking == .purchase {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isWorking != nil)
                .tint(.primary)
            }

            Button {
                runRestore()
            } label: {
                HStack {
                    Label("license.cta.restore", systemImage: "arrow.clockwise")
                    Spacer()
                    if isWorking == .restore {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isWorking != nil)
            .tint(.primary)

            #if os(iOS)
            if case .purchased = license.state,
               let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                Link(destination: url) {
                    Label("license.cta.manage_subscription", systemImage: "creditcard")
                }
                .tint(.primary)
            }
            #endif

            futureTierRow(.employee)
            futureTierRow(.saas)

            #if DEBUG
            debugMenu
            #endif
        } header: {
            Text("license.section.title")
        }
    }

    @ViewBuilder
    private var currentTierRow: some View {
        let tier = license.state.currentTier ?? .localManager
        HStack {
            Label(tier.displayNameKey, systemImage: tier.iconSystemName)
            Spacer()
            stateBadge
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch license.state {
        case .unset:
            Text("license.state.unset")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case .trial(_, let days):
            Text("license.state.trial.\(days)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .purchased:
            Text("license.state.purchased")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .expired:
            Text("license.state.expired")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    private func trialCountdown(daysRemaining: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(LicenseDuration.trialDays - daysRemaining), total: Double(LicenseDuration.trialDays))
            Text("license.trial.days_remaining.\(daysRemaining)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func futureTierRow(_ tier: Tier) -> some View {
        Button {
            infoTier = tier
        } label: {
            HStack {
                Label(tier.displayNameKey, systemImage: tier.iconSystemName)
                Spacer()
                Text("license.tier.coming_soon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
    }

    private var showsUpgrade: Bool {
        switch license.state {
        case .unset, .trial, .expired: true
        case .purchased: false
        }
    }

    private func runPurchase() {
        isWorking = .purchase
        Task {
            defer { isWorking = nil }
            do {
                try await license.purchase(.localManager)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runRestore() {
        isWorking = .restore
        Task {
            defer { isWorking = nil }
            do {
                try await license.restorePurchases()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    #if DEBUG
    @ViewBuilder
    private var debugMenu: some View {
        DisclosureGroup("DEBUG · License") {
            Button("Force unset") { license.forceState(.unset) }
            Button("Force trial (7d)") {
                license.forceState(.trial(startedAt: Date(), daysRemaining: 7))
            }
            Button("Force trial (1d)") {
                license.forceState(.trial(startedAt: Date(), daysRemaining: 1))
            }
            Button("Force expired") {
                license.forceState(.expired(previousTier: .localManager))
            }
            Button("Force purchased") {
                license.forceState(.purchased(tier: .localManager))
            }
            Button("Reset Keychain") {
                try? KeychainStore.delete(KeychainStore.Key.licenseToken)
                try? KeychainStore.delete(KeychainStore.Key.trialStartedAt)
                try? KeychainStore.delete(KeychainStore.Key.currentTier)
                license.forceState(.unset)
            }
        }
    }
    #endif
}
