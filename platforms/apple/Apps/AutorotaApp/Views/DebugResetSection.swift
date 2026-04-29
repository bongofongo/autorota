#if DEBUG
import SwiftUI
import AutorotaKit

struct DebugResetSection: View {
    @Environment(AutorotaSyncEngine.self) private var syncEngine
    @Environment(LicenseService.self) private var license
    @State private var showConfirm = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                showConfirm = true
            } label: {
                Label("Reset App to Fresh State", systemImage: "trash")
            }
            .alert("Reset and quit?", isPresented: $showConfirm) {
                Button("Reset & Quit", role: .destructive) { performReset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes all local data and quits. Reopen to start onboarding from scratch.")
            }
        } header: {
            Text("DEBUG · App")
        } footer: {
            Text("Wipes database, license, and onboarding state, then quits. App preferences (theme, currency, language) are kept.")
        }
    }

    private func performReset() {
        syncEngine.stop()
        try? setSyncMetadata(key: "ck_engine_state", value: "")

        if let url = try? autorotaDefaultDBURL() {
            _ = try? autorotaQuarantineDatabase(at: url)
        }

        try? KeychainStore.delete(KeychainStore.Key.licenseToken)
        try? KeychainStore.delete(KeychainStore.Key.trialStartedAt)
        try? KeychainStore.delete(KeychainStore.Key.currentTier)

        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "pendingOnboardingTierOnly")
        UserDefaults.standard.synchronize()

        exit(0)
    }
}
#endif
