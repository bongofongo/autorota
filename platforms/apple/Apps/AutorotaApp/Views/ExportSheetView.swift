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
    @State private var pdfTemplate: String

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
        _pdfTemplate = State(initialValue: defaults.string(forKey: "exportDefaultPdfTemplate") ?? "weekly_grid")
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
                        Text("PDF").tag("pdf")
                    }
                    .pickerStyle(.segmented)
                }

                if format == "pdf" {
                    Section("PDF Template") {
                        Picker("Template", selection: $pdfTemplate) {
                            Text("Weekly Grid").tag("weekly_grid")
                            Text("Per Employee").tag("per_employee")
                            Text("By Role").tag("by_role")
                        }
                        .pickerStyle(.segmented)
                    }
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

        // Persist current selections so they become the defaults next time.
        let defaults = UserDefaults.standard
        defaults.set(layout, forKey: "exportDefaultLayout")
        defaults.set(format, forKey: "exportDefaultFormat")
        defaults.set(profile, forKey: "exportDefaultProfile")
        defaults.set(showShiftName, forKey: "exportShowShiftName")
        defaults.set(showTimes, forKey: "exportShowTimes")
        defaults.set(showRole, forKey: "exportShowRole")
        defaults.set(pdfTemplate, forKey: "exportDefaultPdfTemplate")

        let config = FfiExportConfig(
            layout: layout,
            format: format,
            profile: profile,
            showShiftName: showShiftName,
            showTimes: showTimes,
            showRole: showRole,
            pdfTemplate: format == "pdf" ? pdfTemplate : nil
        )

        do {
            let result = try await service.exportWeekSchedule(weekStart: weekStart, config: config)

            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(result.filename)

            // PDF exports arrive base64-encoded so they fit the String-typed
            // FFI contract. CSV/JSON are UTF-8 text as before.
            if format == "pdf" {
                guard let pdfData = Data(base64Encoded: result.data) else {
                    throw ExportSheetError.invalidPdfPayload
                }
                try pdfData.write(to: fileURL, options: .atomic)
            } else {
                try result.data.write(to: fileURL, atomically: true, encoding: .utf8)
            }

            exportFileURL = fileURL

            #if os(iOS)
            showShareSheet = true
            #else
            let panel = NSSavePanel()
            panel.nameFieldStringValue = result.filename
            panel.allowedContentTypes = allowedContentTypes(for: format)
            if panel.runModal() == .OK, let dest = panel.url {
                // The user may have picked a destination that already exists
                // (the panel warns but lets them proceed); overwrite it.
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: fileURL, to: dest)
            }
            dismiss()
            #endif
        } catch {
            self.error = userFacingMessage(error)
        }

        isExporting = false
    }

    #if os(macOS)
    private func allowedContentTypes(for format: String) -> [UTType] {
        switch format {
        case "csv": return [.commaSeparatedText]
        case "json": return [.json]
        case "pdf": return [.pdf]
        default: return []
        }
    }
    #endif
}

private enum ExportSheetError: LocalizedError {
    case invalidPdfPayload

    var errorDescription: String? {
        switch self {
        case .invalidPdfPayload:
            return "The exported PDF payload could not be decoded."
        }
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
