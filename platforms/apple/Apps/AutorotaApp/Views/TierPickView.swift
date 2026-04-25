import SwiftUI

struct TierPickView: View {
    @Binding var isPresented: Bool
    @Environment(LicenseService.self) private var license
    @State private var infoTier: Tier?
    @State private var isWorking: WorkingAction?
    @State private var errorMessage: String?

    private enum WorkingAction: Equatable { case purchase, trial }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                tierCard(.localManager)
                tierCard(.employee)
                tierCard(.saas)
                if license.state != .unset {
                    Button {
                        isPresented = false
                    } label: {
                        Text("license.cta.continue_with_current")
                            .font(.body)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(24)
        }
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
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("onboarding.page.tier_pick.title")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("onboarding.page.tier_pick.body")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func tierCard(_ tier: Tier) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: tier.iconSystemName)
                    .font(.title)
                    .foregroundStyle(tier.isAvailable ? Color.accentColor : Color.secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(tier.displayNameKey)
                            .font(.title3.bold())
                        if !tier.isAvailable {
                            Text("license.tier.coming_soon")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    Text(tier.descriptionKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(tier.bulletKeys.enumerated()), id: \.offset) { _, key in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(tier.isAvailable ? Color.green : Color.secondary.opacity(0.6))
                            .font(.caption)
                        Text(key)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if tier.isAvailable {
                actionRow(for: tier)
            } else {
                Button {
                    infoTier = tier
                } label: {
                    HStack {
                        Text("license.modal.future_tier.title")
                        Spacer()
                        Image(systemName: "info.circle")
                    }
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tier.isAvailable ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func actionRow(for tier: Tier) -> some View {
        let price = license.displayPrice(for: tier)
        VStack(alignment: .leading, spacing: 8) {
            if !price.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(price)
                        .font(.title2.bold())
                    Text("license.tier.local_manager.price_note")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    runPurchase()
                } label: {
                    Group {
                        if isWorking == .purchase {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("license.cta.buy")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking != nil)

                Button {
                    runTrial()
                } label: {
                    Group {
                        if isWorking == .trial {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("license.cta.start_trial")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isWorking != nil || isTrialUsed)
            }
        }
    }

    private var isTrialUsed: Bool {
        switch license.state {
        case .trial, .expired: true
        default: false
        }
    }

    private func runPurchase() {
        isWorking = .purchase
        Task {
            defer { isWorking = nil }
            do {
                try await license.purchase(.localManager)
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runTrial() {
        isWorking = .trial
        Task {
            defer { isWorking = nil }
            do {
                try await license.startTrial()
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
