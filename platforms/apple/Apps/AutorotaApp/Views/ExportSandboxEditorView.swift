import SwiftUI

/// Sandbox editor pushed from the Share Schedule sheet when the Custom
/// layout is selected, so the layout can be tweaked without leaving the
/// export flow. Edits save to UserDefaults as they're made (same store the
/// Export settings tab reads), so going back lands on the share sheet with
/// the new layout already active.
struct ExportSandboxEditorView: View {
    @State private var viewModel: ExportSandboxViewModel
    @Environment(\.dismiss) private var dismiss

    init(service: AutorotaServiceProtocol) {
        _viewModel = State(initialValue: ExportSandboxViewModel(service: service))
    }

    var body: some View {
        Form {
            Section {
                ExportSandboxView(viewModel: viewModel)
                    .padding(.vertical, Spacing.xs)
            } footer: {
                Text("Tap a pill, then tap the row headers or the table cells to place it. Changes are saved automatically.")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Custom Layout")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
