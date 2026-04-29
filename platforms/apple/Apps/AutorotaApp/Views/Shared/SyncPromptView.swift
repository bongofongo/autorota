import SwiftUI

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
