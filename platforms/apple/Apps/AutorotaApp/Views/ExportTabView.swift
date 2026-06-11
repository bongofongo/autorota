import SwiftUI

/// Settings page that configures how full-rota exports look. The share
/// pull-up on the Rota tab reads these defaults and only asks the user to
/// pick a scope and format. Per-employee exports have a fixed layout (shift
/// name + times) and are configured in the share sheet itself.
///
/// A top-level toggle switches between the two fixed templates and the
/// custom sandbox layout. The last-used template is remembered separately so
/// flipping to Custom and back doesn't lose it.
struct ExportTabView: View {

    // MARK: - Full View defaults

    @AppStorage("exportDefaultLayout") private var fullLayout: String = "employee_by_weekday"
    @AppStorage("exportLastTemplate") private var lastTemplate: String = "employee_by_weekday"

    private let service: AutorotaServiceProtocol

    @State private var previewRequest: PreviewRequest?
    @State private var sandboxViewModel: ExportSandboxViewModel
    @Environment(\.isMenuPushed) private var isMenuPushed

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
        self.service = service
        _sandboxViewModel = State(initialValue: ExportSandboxViewModel(service: service))
    }

    var body: some View {
        OptionalNavigationStack(embed: !isMenuPushed) {
            Form {
                modeSection
                if mode.wrappedValue == .custom {
                    sandboxSection
                } else {
                    templateSection
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Export Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $previewRequest) { request in
                ExportPreviewSheet(scope: .full, service: service, layoutOverride: request.layout)
            }
            .onAppear {
                // Track the template the share sheet last used so toggling
                // back from Custom restores it.
                if fullLayout != FullExportConfigBuilder.customLayoutPref {
                    lastTemplate = fullLayout
                }
            }
        }
    }

    // MARK: - Mode toggle

    private enum Mode: String, CaseIterable {
        case template
        case custom
    }

    private var mode: Binding<Mode> {
        Binding(
            get: {
                fullLayout == FullExportConfigBuilder.customLayoutPref ? .custom : .template
            },
            set: { newMode in
                switch newMode {
                case .custom: fullLayout = FullExportConfigBuilder.customLayoutPref
                case .template: fullLayout = lastTemplate
                }
            }
        )
    }

    private var modeSection: some View {
        Section {
            Picker("Layout", selection: mode) {
                Text("Custom").tag(Mode.custom)
                Text("Template").tag(Mode.template)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("Applied when exporting the whole rota as one file.")
        }
    }

    // MARK: - Templates

    private struct Template {
        let tag: String
        let name: LocalizedStringKey
        let detail: LocalizedStringKey
        let systemImage: String
    }

    private let templates: [Template] = [
        Template(
            tag: "employee_by_weekday",
            name: "By Employee",
            detail: "One row per employee. Cells show their shifts and times.",
            systemImage: "person.2"
        ),
        Template(
            tag: "shift_by_weekday",
            name: "By Shift",
            detail: "One row per shift. Cells show who is working it.",
            systemImage: "tablecells"
        ),
    ]

    private var templateSection: some View {
        Section {
            ForEach(templates, id: \.tag) { template in
                templateRow(template)
            }
        } header: {
            Text("Templates")
        } footer: {
            Text("Tap a template to preview it. Columns are always Monday to Sunday.")
        }
    }

    private func templateRow(_ template: Template) -> some View {
        Button {
            previewRequest = PreviewRequest(layout: template.tag)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: template.systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .foregroundStyle(.primary)
                    Text(template.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows a sample PDF of this template"))
    }

    // MARK: - Custom sandbox

    private var sandboxSection: some View {
        Section {
            ExportSandboxView(viewModel: sandboxViewModel)
                .padding(.vertical, Spacing.xs)

            Button {
                previewRequest = PreviewRequest(layout: FullExportConfigBuilder.customLayoutPref)
            } label: {
                Label("Preview PDF", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Custom Layout")
        } footer: {
            Text("Tap a pill, then tap the row headers or the table cells to place it. Columns are always Monday to Sunday.")
        }
    }
}

private struct PreviewRequest: Identifiable {
    let layout: String
    var id: String { layout }
}
