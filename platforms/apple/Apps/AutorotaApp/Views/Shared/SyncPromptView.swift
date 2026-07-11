import SwiftUI
import Observation

/// Bridges the launch-time iCloud-zone check to the tier-pick page, which
/// is the ONLY place the sync prompt may appear (never mid-demo, never
/// floating over arbitrary screens). `pending` stays true until the user
/// accepts or declines, so the plan page can also offer a persistent
/// "restore from iCloud" row while the decision is open.
@MainActor
@Observable
final class SyncPromptCoordinator {
    /// Existing iCloud data was found on first launch and the user hasn't
    /// decided yet — the plan page pops the prompt.
    private(set) var pending = false
    /// iCloud data exists, whether or not the user has declined it. Keeps
    /// the plan page's "start from iCloud data" row available even after a
    /// "start fresh" choice, until the data is actually restored.
    private(set) var cloudDataAvailable = false
    /// Wired by `AutorotaAppApp` to start the sync engine + persist
    /// `sync_initialized` / `sync_disabled`.
    @ObservationIgnored var onAccept: () -> Void = {}
    @ObservationIgnored var onDecline: () -> Void = {}

    /// Undecided iCloud data: prompt + row.
    func markPending() {
        pending = true
        cloudDataAvailable = true
    }

    /// Previously declined iCloud data that still exists: row only.
    func markCloudDataAvailable() {
        cloudDataAvailable = true
    }

    func accept() {
        pending = false
        cloudDataAvailable = false
        onAccept()
    }

    func decline() {
        pending = false
        onDecline()
    }
}

struct SyncPromptView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("sync.prompt.title")
                .font(.title2.bold())

            Text("sync.prompt.body")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button(action: onAccept) {
                    Text("sync.prompt.accept")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onDecline) {
                    Text("sync.prompt.decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
        }
        .padding()
    }
}
