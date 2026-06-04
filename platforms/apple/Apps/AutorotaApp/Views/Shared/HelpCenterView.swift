import SwiftUI
import TipKit

/// Help hub pushed from the Menu landing: the full guide plus ways to learn about
/// or get help with the app.
struct HelpCenterView: View {
    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    HelpView()
                } label: {
                    Label("Help & Guide", systemImage: "book")
                }
                Button {
                    try? Tips.resetDatastore()
                } label: {
                    Label("Replay Tooltips", systemImage: "arrow.counterclockwise.circle")
                }
                .tint(.primary)
            } footer: {
                Text("Re-show the in-app tips you've already dismissed.")
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Help")
    }
}
