import SwiftUI

/// Help hub pushed from the Menu landing: the full guide plus ways to learn about
/// or get help with the app. Platform shells apply the platform's own form
/// style; see `Views/Platform/{iOS,macOS}/HelpCenterView_*.swift`.
struct HelpCenterContent: View {
    @Environment(DemoModeController.self) private var demo

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
                // The demo's home after its first full completion (until
                // then it sits on the Menu landing as "Try the Demo").
                if !demo.isActive, demo.hasEverCompletedDemo {
                    Button {
                        demo.enterDemo()
                    } label: {
                        Label("demo.help.replay", systemImage: "play.circle")
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("demo.help.replay")
                }
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
        .navigationTitle("Help")
    }
}
