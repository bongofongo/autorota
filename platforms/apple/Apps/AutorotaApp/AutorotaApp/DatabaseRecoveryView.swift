import SwiftUI
import AutorotaKit

/// Shown when both the initial DB open and the post-quarantine retry failed.
/// Offers the user a hard reset (rename the file out of the way and restart
/// the open) and a copy-able error string they can email to support.
struct DatabaseRecoveryView: View {
    let errorMessage: String

    @State private var resetAttempted = false
    @State private var resetError: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("Couldn't open your data")
                .font(.title2.weight(.semibold))

            Text("Autorota tried to open your local database and recover from corruption, but neither attempt succeeded. Resetting will move the corrupt file aside so the app can start fresh — your data will be preserved on disk and a future version may be able to import it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 4) {
                Text("Error detail")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(errorMessage)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal)

            if let resetError {
                Text("Reset failed: \(resetError)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                attemptReset()
            } label: {
                Label(resetAttempted ? "Quit and reopen Autorota" : "Reset & start fresh",
                      systemImage: resetAttempted ? "arrow.clockwise" : "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            Button("Email support") {
                let subject = "Autorota database recovery"
                let body = "Error detail:\n\(errorMessage)"
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: "mailto:support@toadmountain.com?subject=\(subject)&body=\(body)") {
                    openURL(url)
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            Spacer()
        }
        .padding(.top, 32)
    }

    private func attemptReset() {
        if resetAttempted {
            // Second tap = user has acknowledged; ask iOS to terminate the
            // process so the next launch retries init from a clean slate.
            exit(0)
        }
        do {
            let url = try autorotaDefaultDBURL()
            _ = try autorotaQuarantineDatabase(at: url)
            resetAttempted = true
            resetError = nil
        } catch {
            resetError = "\(error)"
        }
    }
}

#Preview {
    DatabaseRecoveryView(errorMessage: "DbConnectionFailed: file is not a database (code 26)")
}
