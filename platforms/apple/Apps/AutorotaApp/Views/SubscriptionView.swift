import SwiftUI

/// Full-page wrapper around `SubscriptionSettingsSection` so license/tier info gets
/// its own destination pushed from the Menu landing.
struct SubscriptionView: View {
    var body: some View {
        Form {
            SubscriptionSettingsSection()
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("License")
    }
}
