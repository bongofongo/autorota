import SwiftUI

/// Settings page that configures how full-rota exports look. The share
/// pull-up on the Rota tab reads these defaults and only asks the user to
/// pick a scope and format. Per-employee exports have a fixed layout (shift
/// name + times) and are configured in the share sheet itself.
struct ExportTabView: View {

    // MARK: - Full View defaults

    @AppStorage("exportDefaultLayout") private var fullLayout: String = "employee_by_weekday"

    private let service: AutorotaServiceProtocol

    @State private var previewScope: ExportPreviewSheet.Scope?
    @State private var sandboxViewModel: ExportSandboxViewModel
    @Environment(\.isMenuPushed) private var isMenuPushed

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
        self.service = service
        _sandboxViewModel = State(initialValue: ExportSandboxViewModel(service: service))
    }

    var body: some View {
        OptionalNavigationStack(embed: !isMenuPushed) {
            Form {
                fullViewSection
                if fullLayout == FullExportConfigBuilder.customLayoutPref {
                    sandboxSection
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Export Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $previewScope) { scope in
                ExportPreviewSheet(scope: scope, service: service)
            }
        }
    }

    // MARK: - Full View

    private var fullViewSection: some View {
        Section {
            Picker("Layout", selection: $fullLayout) {
                Text("By Employee").tag("employee_by_weekday")
                Text("By Shift").tag("shift_by_weekday")
                Text("Custom").tag(FullExportConfigBuilder.customLayoutPref)
            }
            .pickerStyle(.segmented)

            Button {
                previewScope = .full
            } label: {
                Label("Preview PDF", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Full View")
        } footer: {
            Text("Applied when exporting the whole rota as one file.")
        }
    }

    // MARK: - Custom sandbox

    private var sandboxSection: some View {
        Section {
            ExportSandboxView(viewModel: sandboxViewModel)
                .padding(.vertical, Spacing.xs)
        } header: {
            Text("Custom Layout")
        } footer: {
            Text("Drag pills into the row headers or the table cells. Columns are always Monday to Sunday.")
        }
    }
}

extension ExportPreviewSheet.Scope: Identifiable {
    public var id: String { rawValue }
}
