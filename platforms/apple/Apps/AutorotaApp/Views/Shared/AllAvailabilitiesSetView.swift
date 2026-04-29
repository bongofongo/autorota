import SwiftUI

/// Shown when all employee availabilities have been marked done for the week.
struct AllAvailabilitiesSetView: View {
    var body: some View {
        Spacer()
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("All availabilities set for next week")
                .font(.headline)
            Text("You can review or edit any employee from the picker below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        Spacer()
    }
}
