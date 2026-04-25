import SwiftUI

struct ReadOnlyBanner: View {
    @Environment(LicenseService.self) private var license
    @State private var isUpgrading = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("license.banner.read_only.title")
                    .font(.subheadline.weight(.semibold))
                Text("license.banner.read_only.body")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                runUpgrade()
            } label: {
                if isUpgrading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("license.banner.read_only.cta")
                        .font(.callout.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isUpgrading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.18))
        .overlay(Divider(), alignment: .bottom)
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

    private func runUpgrade() {
        isUpgrading = true
        Task {
            defer { isUpgrading = false }
            do {
                try await license.purchase(.localManager)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
