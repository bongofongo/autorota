import SwiftUI
import AutorotaKit
#if os(macOS)
import UniformTypeIdentifiers
#endif

/// Share pull-up shown from the Rota tab. Layout / profile / cell content
/// come from the Export (settings) tab; here the user picks:
///   1. Scope — full rota vs. per-employee
///   2. Per-employee sub-scope — all employees vs. one employee
///   3. Format — pdf / xlsx / csv / markdown / json (and ics for per-employee)
struct ExportSheetView: View {
    let weekStart: String
    let service: AutorotaServiceProtocol
    @Environment(\.dismiss) private var dismiss

    // MARK: - Settings (from Export tab)

    @AppStorage("exportDefaultLayout") private var layout: String = "employee_by_weekday"
    @AppStorage("exportDefaultProfile") private var profile: String = "staff_schedule"
    @AppStorage("exportDefaultPdfTemplate") private var pdfTemplate: String = "weekly_grid"
    @AppStorage("exportShowShiftName") private var showShiftName: Bool = true
    @AppStorage("exportShowTimes") private var showTimes: Bool = true
    @AppStorage("exportShowRole") private var showRole: Bool = true

    // MARK: - Scope state

    enum Scope: String, CaseIterable, Identifiable {
        case fullRota, perEmployee
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fullRota: "Full View"
            case .perEmployee: "Employee View"
            }
        }
    }

    enum PerEmployeeScope: String, CaseIterable, Identifiable {
        case all, individual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All Employees"
            case .individual: "One Employee"
            }
        }
    }

    @State private var scope: Scope = .fullRota
    @State private var perEmpScope: PerEmployeeScope = .all
    @State private var selectedEmployeeId: Int64?
    @State private var format: String = "pdf"

    // MARK: - Export state

    @State private var employees: [FfiEmployee] = []
    @State private var loadingEmployees = false
    @State private var isExporting = false
    @State private var error: String?
    @State private var exportURLs: [URL] = []
    @State private var showShareSheet = false
    @State private var tempDir: URL?
    @State private var showRecipientsInfo = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("What to export")
                }

                if scope == .perEmployee {
                    Section {
                        Picker("Recipients", selection: $perEmpScope) {
                            ForEach(PerEmployeeScope.allCases) { s in Text(s.label).tag(s) }
                        }
                        .pickerStyle(.segmented)

                        if perEmpScope == .individual {
                            employeeRow
                        }
                    } header: {
                        HStack {
                            Text("Recipients")
                            Spacer()
                            Button {
                                showRecipientsInfo = true
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                            .popover(isPresented: $showRecipientsInfo, arrowEdge: .top) {
                                Text("**All Employees** generates a separate export file for every employee using this week's schedule, then shares or saves them together.")
                                    .font(.footnote)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding()
                                    .frame(width: 280)
                                    .presentationCompactAdaptation(.popover)
                            }
                        }
                    }
                }

                Section {
                    Picker("Format", selection: $format) {
                        ForEach(availableFormats) { f in
                            Text(f.label).tag(f.id)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Format")
                } footer: {
                    Text("Layout, profile, and cell content use your Export tab settings.")
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Share Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cleanup(); dismiss() }
                        .disabled(isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("Export") {
                            Task { await run() }
                        }
                        .disabled(!canExport)
                    }
                }
            }
            .alert("Export Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            #if os(iOS)
            .sheet(isPresented: $showShareSheet, onDismiss: { cleanup(); dismiss() }) {
                if !exportURLs.isEmpty {
                    ShareSheet(activityItems: exportURLs)
                }
            }
            #endif
        }
        .task { await loadEmployeesIfNeeded() }
        .onChange(of: scope) { _, new in
            if new == .perEmployee { Task { await loadEmployeesIfNeeded() } }
            clampFormat()
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 460)
        #endif
    }

    // MARK: - Employee picker row

    @ViewBuilder
    private var employeeRow: some View {
        if loadingEmployees {
            ProgressView("Loading employees…")
        } else if employees.isEmpty {
            Text("No employees found").foregroundStyle(.secondary)
        } else {
            Picker("Employee", selection: $selectedEmployeeId) {
                ForEach(employees, id: \.id) { e in
                    Text(e.displayName).tag(Optional(e.id))
                }
            }
        }
    }

    // MARK: - Format catalogue

    private struct FormatOpt: Identifiable {
        let id: String
        let label: String
    }

    private var availableFormats: [FormatOpt] {
        var list: [FormatOpt] = [
            .init(id: "pdf", label: "PDF"),
            .init(id: "xlsx", label: "Spreadsheet (XLSX)"),
            .init(id: "csv", label: "CSV"),
            .init(id: "markdown", label: "Markdown"),
            .init(id: "json", label: "JSON"),
        ]
        if scope == .perEmployee {
            list.append(.init(id: "ics", label: "ICS Calendar"))
        }
        return list
    }

    private func clampFormat() {
        if !availableFormats.contains(where: { $0.id == format }) {
            format = availableFormats.first?.id ?? "pdf"
        }
    }

    // MARK: - Ability gate

    private var canExport: Bool {
        if isExporting { return false }
        switch scope {
        case .fullRota:
            return true
        case .perEmployee:
            switch perEmpScope {
            case .all: return !employees.isEmpty
            case .individual: return selectedEmployeeId != nil
            }
        }
    }

    // MARK: - Loading

    private func loadEmployeesIfNeeded() async {
        if !employees.isEmpty || loadingEmployees { return }
        loadingEmployees = true
        do {
            employees = try await service.listEmployees()
            if selectedEmployeeId == nil {
                selectedEmployeeId = employees.first?.id
            }
        } catch {
            self.error = userFacingMessage(error)
        }
        loadingEmployees = false
    }

    // MARK: - Export dispatch

    private func run() async {
        isExporting = true
        error = nil
        defer { isExporting = false }

        do {
            let dir = try makeTempDir()
            tempDir = dir

            let urls: [URL]
            switch scope {
            case .fullRota:
                urls = [try await exportFullRota(into: dir)]
            case .perEmployee:
                switch perEmpScope {
                case .all:
                    urls = try await exportAllEmployees(into: dir)
                case .individual:
                    guard let id = selectedEmployeeId else { return }
                    urls = [try await exportOneEmployee(id: id, into: dir)]
                }
            }

            exportURLs = urls

            #if os(iOS)
            showShareSheet = true
            #else
            try saveOnMac(urls: urls)
            cleanup()
            dismiss()
            #endif
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    private func exportFullRota(into dir: URL) async throws -> URL {
        let config = FfiExportConfig(
            layout: layout,
            format: format,
            profile: profile,
            showShiftName: showShiftName,
            showTimes: showTimes,
            showRole: showRole,
            pdfTemplate: format == "pdf" ? pdfTemplate : nil
        )
        let result = try await service.exportWeekSchedule(weekStart: weekStart, config: config)
        return try writeResult(result, into: dir)
    }

    private func exportOneEmployee(id: Int64, into dir: URL) async throws -> URL {
        let (start, end) = weekRange()
        let config = FfiEmployeeExportConfig(
            employeeId: id,
            startDate: start,
            endDate: end,
            format: format,
            profile: profile,
            showShiftName: showShiftName,
            showTimes: showTimes,
            showRole: showRole,
            timezoneId: TimeZone.current.identifier
        )
        let result = try await service.exportEmployeeSchedule(config: config)
        return try writeResult(result, into: dir)
    }

    private func exportAllEmployees(into dir: URL) async throws -> [URL] {
        var urls: [URL] = []
        let (start, end) = weekRange()
        for e in employees {
            let config = FfiEmployeeExportConfig(
                employeeId: e.id,
                startDate: start,
                endDate: end,
                format: format,
                profile: profile,
                showShiftName: showShiftName,
                showTimes: showTimes,
                showRole: showRole,
                timezoneId: TimeZone.current.identifier
            )
            let result = try await service.exportEmployeeSchedule(config: config)
            urls.append(try writeResult(result, into: dir))
        }
        return urls
    }

    // MARK: - File I/O

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autorota-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeResult(_ result: FfiExportResult, into dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(result.filename)
        if isBinary(format: format) {
            guard let data = Data(base64Encoded: result.data) else {
                throw ExportSheetError.invalidBinaryPayload
            }
            try data.write(to: url, options: .atomic)
        } else {
            try result.data.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private func isBinary(format: String) -> Bool {
        format == "pdf" || format == "xlsx"
    }

    private func weekRange() -> (String, String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let start = fmt.date(from: weekStart),
              let end = Calendar.current.date(byAdding: .day, value: 6, to: start) else {
            return (weekStart, weekStart)
        }
        return (weekStart, fmt.string(from: end))
    }

    private func cleanup() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
        }
        exportURLs = []
    }

    #if os(macOS)
    private func saveOnMac(urls: [URL]) throws {
        if urls.count == 1, let only = urls.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = only.lastPathComponent
            panel.allowedContentTypes = allowedContentTypes(for: format)
            if panel.runModal() == .OK, let dest = panel.url {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: only, to: dest)
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            if panel.runModal() == .OK, let dest = panel.url {
                for url in urls {
                    let target = dest.appendingPathComponent(url.lastPathComponent)
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: url, to: target)
                }
            }
        }
    }

    private func allowedContentTypes(for format: String) -> [UTType] {
        switch format {
        case "csv": return [.commaSeparatedText]
        case "json": return [.json]
        case "pdf": return [.pdf]
        case "xlsx":
            return [UTType(filenameExtension: "xlsx") ?? .spreadsheet]
        case "markdown":
            return [UTType(filenameExtension: "md") ?? .plainText]
        case "ics":
            return [UTType(filenameExtension: "ics") ?? .calendarEvent]
        default: return []
        }
    }
    #endif
}

private enum ExportSheetError: LocalizedError {
    case invalidBinaryPayload

    var errorDescription: String? {
        switch self {
        case .invalidBinaryPayload:
            return "The exported binary payload could not be decoded."
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
