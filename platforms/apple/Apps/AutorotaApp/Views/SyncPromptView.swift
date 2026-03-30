import SwiftUI

struct SyncPromptView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("iCloud Data Found")
                .font(.title2.bold())

            Text("Your Autorota data was found on iCloud. Would you like to download it to this device?")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button(action: onAccept) {
                    Text("Download from iCloud")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onDecline) {
                    Text("Start Fresh")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
        }
        .padding()
    }
}
