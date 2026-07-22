import SwiftUI

struct TierPickView: View {
    @Binding var isPresented: Bool
    @Environment(LicenseService.self) private var license
    @Environment(DemoModeController.self) private var demo
    @Environment(SyncPromptCoordinator.self) private var syncPrompt
    @State private var infoTier: Tier?
    @State private var isWorking: WorkingAction?
    @State private var errorMessage: String?
    @State private var showSyncPrompt = false
    /// Becomes true after the first purchase/restore failure so we can
    /// surface a local "Try offline" escape — without it, a hard-gated
    /// TierPick traps users on devices with no App Store reachability.
    @State private var offlineEscapeAvailable = false

    private enum WorkingAction: Equatable { case purchase, trial, restore }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                demoRow
                tierCard(.localManager)
                // Employee + Cloud (Multi-Site) tiers hidden for now.
                // Re-enable: tierCard(.employee); tierCard(.saas)
                // Restore Purchases hidden while the app is free.
                // Re-enable: restoreRow
                syncRestoreRow
                offlineEscapeRow
                if license.state.allowsMutation {
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
        // The launch-time iCloud-data prompt appears HERE and only here —
        // never over a demo run or arbitrary screens. Swiping it away
        // defers the decision; the syncRestoreRow stays available.
        .sheet(isPresented: $showSyncPrompt) {
            SyncPromptView(
                onAccept: {
                    syncPrompt.accept()
                    showSyncPrompt = false
                },
                onDecline: {
                    syncPrompt.decline()
                    showSyncPrompt = false
                }
            )
        }
        .onAppear {
            if syncPrompt.pending && !demo.isActive {
                showSyncPrompt = true
            }
        }
        .onChange(of: syncPrompt.pending) { _, pending in
            // The CloudKit zone check can finish after this page appeared.
            if pending && !demo.isActive {
                showSyncPrompt = true
            }
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

    /// Pre-purchase escape hatch: run the guided demo against a throwaway
    /// sample business before committing to a plan.
    private var demoRow: some View {
        Button {
            isPresented = false
            demo.enterDemo()
        } label: {
            HStack {
                Image(systemName: "play.circle.fill")
                Text("demo.cta.try_first")
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(.accentColor)
        .disabled(isWorking != nil)
        .accessibilityIdentifier("demo.cta.tryFirst")
    }

    @ViewBuilder
    private var restoreRow: some View {
        Button {
            runRestore()
        } label: {
            HStack {
                if isWorking == .restore {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                Text("license.cta.restore")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isWorking != nil)
    }

    /// Shown while iCloud data exists and hasn't been restored — whether
    /// the popup was deferred with a swipe-down OR declined ("start
    /// fresh"). Reopens the sync prompt.
    @ViewBuilder
    private var syncRestoreRow: some View {
        if syncPrompt.cloudDataAvailable {
            Button {
                showSyncPrompt = true
            } label: {
                HStack {
                    Image(systemName: "icloud.and.arrow.down")
                    Text("sync.prompt.plan_row")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(isWorking != nil)
            .accessibilityIdentifier("tierpick.syncRestore")
        }
    }

    @ViewBuilder
    private var offlineEscapeRow: some View {
        if offlineEscapeAvailable && license.state == .unset && !isTrialUsed {
            VStack(spacing: 4) {
                Button {
                    runTrial()
                } label: {
                    HStack {
                        if isWorking == .trial {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wifi.slash")
                        }
                        Text("license.cta.try_offline")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isWorking != nil)
                Text("license.cta.offline_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
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
                    if !PricingCatalog.isFree(for: tier) {
                        Text("license.tier.local_manager.price_note")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    runPurchase()
                } label: {
                    Group {
                        if isWorking == .purchase {
                            ProgressView().controlSize(.small)
                        } else if PricingCatalog.isFree(for: tier) {
                            Text("license.cta.enter")
                        } else {
                            Text("license.cta.buy")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking != nil)

                // Trial button hidden while the app is free.
                // Re-enable when paid pricing lands:
                // Button {
                //     runTrial()
                // } label: {
                //     Group {
                //         if isWorking == .trial {
                //             ProgressView().controlSize(.small)
                //         } else {
                //             Text("license.cta.start_trial")
                //         }
                //     }
                //     .frame(maxWidth: .infinity)
                // }
                // .buttonStyle(.bordered)
                // .controlSize(.large)
                // .disabled(isWorking != nil || isTrialUsed)
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
                offlineEscapeAvailable = true
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

    private func runRestore() {
        isWorking = .restore
        Task {
            defer { isWorking = nil }
            do {
                try await license.restorePurchases()
                if license.state.allowsMutation {
                    isPresented = false
                }
            } catch {
                errorMessage = error.localizedDescription
                offlineEscapeAvailable = true
            }
        }
    }
}
