import SwiftUI
import AutorotaKit
#if os(macOS)
import UniformTypeIdentifiers
#endif

struct ExportSheetView: View {
    let weekStart: String
    let service: AutorotaServiceProtocol
    @Environment(\.dismiss) private var dismiss

    // Export options — initialised from @AppStorage defaults.
    @State private var layout: String
    @State private var format: String
    @State private var profile: String
    @State private var showShiftName: Bool
    @State private var showTimes: Bool
    @State private var showRole: Bool

    @State private var isExporting = false
    @State private var error: String?
    @State private var exportFileURL: URL?
    @State private var showShareSheet = false

    init(weekStart: String, service: AutorotaServiceProtocol) {
        self.weekStart = weekStart
        self.service = service
        // Read defaults; fall back to sensible values.
        let defaults = UserDefaults.standard
        _layout = State(initialValue: defaults.string(forKey: "exportDefaultLayout") ?? "employee_by_weekday")
        _format = State(initialValue: defaults.string(forKey: "exportDefaultFormat") ?? "csv")
        _profile = State(initialValue: defaults.string(forKey: "exportDefaultProfile") ?? "staff_schedule")
        _showShiftName = State(initialValue: defaults.object(forKey: "exportShowShiftName") as? Bool ?? true)
        _showTimes = State(initialValue: defaults.object(forKey: "exportShowTimes") as? Bool ?? true)
        _showRole = State(initialValue: defaults.object(forKey: "exportShowRole") as? Bool ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Layout") {
                    Picker("Layout", selection: $layout) {
                        Text("By Employee").tag("employee_by_weekday")
                        Text("By Shift").tag("shift_by_weekday")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Format") {
                    Picker("Format", selection: $format) {
                        Text("CSV").tag("csv")
                        Text("JSON").tag("json")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Profile") {
                    Picker("Profile", selection: $profile) {
                        Text("Staff Schedule").tag("staff_schedule")
                        Text("Manager Report").tag("manager_report")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Cell Content") {
                    Toggle("Shift Name", isOn: $showShiftName)
                    Toggle("Times", isOn: $showTimes)
                    Toggle("Role", isOn: $showRole)
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Export Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("Export") {
                            Task { await performExport() }
                        }
                    }
                }
            }
            .alert("Export Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            #if os(iOS)
            .sheet(isPresented: $showShareSheet) {
                if let url = exportFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 400, idealHeight: 500)
        #endif
    }

    private func performExport() async {
        isExporting = true
        error = nil

        let config = FfiExportConfig(
            layout: layout,
            format: format,
            profile: profile,
            showShiftName: showShiftName,
            showTimes: showTimes,
            showRole: showRole
        )

        do {
            let result = try await service.exportWeekSchedule(weekStart: weekStart, config: config)

            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(result.filename)
            try result.data.write(to: fileURL, atomically: true, encoding: .utf8)

            exportFileURL = fileURL

            #if os(iOS)
            showShareSheet = true
            #else
            // macOS: use NSSavePanel via the share sheet or just reveal in Finder.
            let panel = NSSavePanel()
            panel.nameFieldStringValue = result.filename
            panel.allowedContentTypes = format == "csv"
                ? [.commaSeparatedText]
                : [.json]
            if panel.runModal() == .OK, let dest = panel.url {
                try FileManager.default.copyItem(at: fileURL, to: dest)
            }
            dismiss()
            #endif
        } catch {
            self.error = error.localizedDescription
        }

        isExporting = false
    }
}

// MARK: - iOS Share Sheet wrapper

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
