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
    /// Set by `RotaView` when the rota has dirty edits. Used to gate Bulk
    /// Send so the audit trail captures the version that was distributed.
    var hasUnsavedEdits: Bool = false
    /// Persists the in-memory rota as a Save snapshot. Bulk Send invokes
    /// this when the user taps "Save & continue" on the unsaved-edits alert.
    var onSaveBeforeBulkSend: (() async -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    // MARK: - Settings (from Export tab)

    // Full View defaults
    @AppStorage("exportDefaultLayout") private var fullLayout: String = "employee_by_weekday"
    @AppStorage("exportDefaultProfile") private var fullProfile: String = "staff_schedule"
    @AppStorage("exportDefaultPdfTemplate") private var fullPdfTemplate: String = "weekly_grid"
    @AppStorage("exportShowShiftName") private var fullShowShiftName: Bool = true
    @AppStorage("exportShowTimes") private var fullShowTimes: Bool = true
    @AppStorage("exportShowRole") private var fullShowRole: Bool = true

    // Employee View defaults. Profile is locked to staff_schedule — employee
    // exports never include wage/cost data.
    private let empProfile = "staff_schedule"
    @AppStorage("empExportShowShiftName") private var empShowShiftName: Bool = true
    @AppStorage("empExportShowTimes") private var empShowTimes: Bool = true
    @AppStorage("empExportShowRole") private var empShowRole: Bool = true

    // Bulk Send message-body template
    @AppStorage(BulkSendSettings.weekHeaderKey)   private var bulkWeekHeader: Bool = true
    @AppStorage(BulkSendSettings.shiftLineKey)    private var bulkShiftLine: Bool = true
    @AppStorage(BulkSendSettings.customPrefixKey) private var bulkCustomPrefix: String = ""
    @AppStorage(BulkSendSettings.customSuffixKey) private var bulkCustomSuffix: String = ""
    @State private var showBulkTemplate: Bool = false

    // MARK: - Scope state

    enum Scope: String, CaseIterable, Identifiable {
        case fullRota, perEmployee
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fullRota: String(localized: "Full View")
            case .perEmployee: String(localized: "Employee View")
            }
        }
    }

    enum PerEmployeeScope: String, CaseIterable, Identifiable {
        case all, individual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: String(localized: "All Employees")
            case .individual: String(localized: "One Employee")
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

    // Bulk Send state
    @State private var showBulkSend = false
    @State private var showUnsavedEditsAlert = false
    @State private var savingBeforeBulkSend = false

    // Preview state
    @State private var isPreviewing = false
    @State private var previewPayload: PreviewPayload?

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let title: String
        let format: String
        let result: FfiExportResult
        let footnote: String?
    }

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

                if scope == .fullRota {
                    Section {
                        Picker("Layout", selection: $fullLayout) {
                            Text("By Employee").tag("employee_by_weekday")
                            Text("By Shift").tag("shift_by_weekday")
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Layout")
                    }
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
                            .accessibilityLabel("About recipients")
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

                Section {
                    Button {
                        Task { await runPreview() }
                    } label: {
                        HStack {
                            if isPreviewing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "eye")
                            }
                            Text("Preview")
                        }
                    }
                    .disabled(isPreviewing || isExporting || !canExport)
                } footer: {
                    if scope == .perEmployee && perEmpScope == .all {
                        Text("Previews the first employee's file. The export still produces one file per employee.")
                    }
                }

                if scope == .perEmployee && perEmpScope == .all {
                    Section {
                        Button {
                            startBulkSend()
                        } label: {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                Text("Bulk Send")
                            }
                        }
                        .disabled(isExporting || isPreviewing || employees.isEmpty)
                    } footer: {
                        Text("Send each employee a markdown rota via their preferred channel (iMessage, WhatsApp, or Email). Skipped recipients are listed after.")
                    }
                }

                if scope == .perEmployee {
                    Section {
                        DisclosureGroup(isExpanded: $showBulkTemplate) {
                            Toggle("Week header", isOn: $bulkWeekHeader)
                            Toggle("Per-shift lines", isOn: $bulkShiftLine)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Prefix").font(.caption).foregroundStyle(.secondary)
                                TextField("e.g. Hi {first_name},", text: $bulkCustomPrefix, axis: .vertical)
                                    .lineLimit(1...3)
                                    #if canImport(UIKit)
                                    .textInputAutocapitalization(.sentences)
                                    #endif
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Suffix").font(.caption).foregroundStyle(.secondary)
                                TextField("e.g. Let me know if any clashes.", text: $bulkCustomSuffix, axis: .vertical)
                                    .lineLimit(1...3)
                                    #if canImport(UIKit)
                                    .textInputAutocapitalization(.sentences)
                                    #endif
                            }
                        } label: {
                            Label("Message Template", systemImage: "text.alignleft")
                        }
                    } footer: {
                        Text("Used by Bulk Send. `{first_name}`, `{last_name}`, `{name}` are substituted per recipient.")
                    }
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
            .errorAlert($error)
            #if os(iOS)
            .sheet(isPresented: $showShareSheet, onDismiss: { cleanup(); dismiss() }) {
                if !exportURLs.isEmpty {
                    ShareSheet(activityItems: exportURLs)
                }
            }
            #endif
            .sheet(item: $previewPayload) { payload in
                RotaExportPreview(
                    title: payload.title,
                    format: payload.format,
                    result: payload.result,
                    footnote: payload.footnote
                )
            }
            .sheet(isPresented: $showBulkSend) {
                BulkSendChecklistView(weekStart: weekStart, service: service)
            }
            .alert(
                "Save the rota first",
                isPresented: $showUnsavedEditsAlert
            ) {
                Button("Save & continue") {
                    Task { await saveThenBulkSend() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This rota has unsaved changes. The version that gets sent should match the saved snapshot.")
            }
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
            .init(id: "xlsx", label: String(localized: "Spreadsheet (XLSX)")),
            .init(id: "csv", label: "CSV"),
            .init(id: "markdown", label: "Markdown"),
            .init(id: "json", label: "JSON"),
        ]
        if scope == .perEmployee {
            list.append(.init(id: "ics", label: String(localized: "ICS Calendar")))
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

    // MARK: - Preview dispatch

    private func runPreview() async {
        isPreviewing = true
        error = nil
        defer { isPreviewing = false }

        do {
            switch scope {
            case .fullRota:
                let result = try await service.exportWeekSchedule(
                    weekStart: weekStart,
                    config: fullRotaConfig()
                )
                previewPayload = PreviewPayload(
                    title: "Preview · \(formatLabel(format))",
                    format: format,
                    result: result,
                    footnote: nil
                )
            case .perEmployee:
                let id: Int64?
                let footnote: String?
                switch perEmpScope {
                case .all:
                    id = employees.first?.id
                    footnote = id == nil ? nil : "Showing first employee. Export produces one file per employee."
                case .individual:
                    id = selectedEmployeeId
                    footnote = nil
                }
                guard let employeeId = id else { return }
                let result = try await service.exportEmployeeSchedule(
                    config: employeeConfig(id: employeeId)
                )
                let name = employees.first(where: { $0.id == employeeId })?.displayName ?? "Employee"
                previewPayload = PreviewPayload(
                    title: "Preview · \(name)",
                    format: format,
                    result: result,
                    footnote: footnote
                )
            }
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    private func formatLabel(_ id: String) -> String {
        availableFormats.first(where: { $0.id == id })?.label ?? id.uppercased()
    }

    private func fullRotaConfig() -> FfiExportConfig {
        FfiExportConfig(
            layout: fullLayout,
            format: format,
            profile: fullProfile,
            showShiftName: fullLayout == "shift_by_weekday" ? false : fullShowShiftName,
            showTimes: fullShowTimes,
            showRole: fullShowRole,
            pdfTemplate: format == "pdf" ? fullPdfTemplate : nil
        )
    }

    private func employeeConfig(id: Int64) -> FfiEmployeeExportConfig {
        let (start, end) = weekRange()
        return FfiEmployeeExportConfig(
            employeeId: id,
            startDate: start,
            endDate: end,
            format: format,
            profile: empProfile,
            showShiftName: empShowShiftName,
            showTimes: empShowTimes,
            showRole: empShowRole,
            timezoneId: TimeZone.current.identifier
        )
    }

    private func exportFullRota(into dir: URL) async throws -> URL {
        let result = try await service.exportWeekSchedule(
            weekStart: weekStart,
            config: fullRotaConfig()
        )
        return try writeResult(result, into: dir)
    }

    private func exportOneEmployee(id: Int64, into dir: URL) async throws -> URL {
        let result = try await service.exportEmployeeSchedule(config: employeeConfig(id: id))
        return try writeResult(result, into: dir)
    }

    private func exportAllEmployees(into dir: URL) async throws -> [URL] {
        var urls: [URL] = []
        for e in employees {
            let result = try await service.exportEmployeeSchedule(config: employeeConfig(id: e.id))
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

    // MARK: - Bulk Send

    private func startBulkSend() {
        if hasUnsavedEdits {
            showUnsavedEditsAlert = true
        } else {
            showBulkSend = true
        }
    }

    private func saveThenBulkSend() async {
        savingBeforeBulkSend = true
        defer { savingBeforeBulkSend = false }
        if let save = onSaveBeforeBulkSend {
            await save()
        }
        showBulkSend = true
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
