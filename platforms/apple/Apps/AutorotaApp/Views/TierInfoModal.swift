import SwiftUI

struct TierInfoModal: View {
    let tier: Tier
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: tier.iconSystemName)
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tier.displayNameKey)
                                .font(.title2.bold())
                            Text("license.tier.coming_soon")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    Text(tier.descriptionKey)
                        .font(.body)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(tier.bulletKeys.enumerated()), id: \.offset) { _, key in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 7)
                                Text(key)
                                    .font(.callout)
                            }
                        }
                    }

                    Text("license.modal.future_tier.body")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    Button {
                        // TODO(notify): persist user interest once a backend exists.
                    } label: {
                        Text("license.cta.notify_me")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(true)
                }
                .padding(24)
            }
            .navigationTitle(Text(tier.displayNameKey))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("onboarding.alert.ok") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 520)
        #endif
    }
}
