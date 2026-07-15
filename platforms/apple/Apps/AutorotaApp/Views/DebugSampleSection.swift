#if DEBUG
import SwiftUI

struct DebugSampleSection: View {
    @Environment(SampleDataController.self) private var sample

    var body: some View {
        Section {
            if sample.isLoaded {
                Button(role: .destructive) {
                    sample.unload()
                } label: {
                    Label("Unload “Default” Sample", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button {
                    sample.load()
                } label: {
                    Label("Load “Default” Sample", systemImage: "tray.and.arrow.down")
                }
            }
        } header: {
            Text("DEBUG · Sample Data")
        } footer: {
            Text("Loads a throwaway 30-employee cafe dataset onto a separate database. Your real data is untouched; unloading restores it.")
        }
    }
}
#endif
