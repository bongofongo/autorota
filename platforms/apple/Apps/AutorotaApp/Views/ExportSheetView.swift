import SwiftUI
import AutorotaKit
import UniformTypeIdentifiers

/// Share pull-up shown from the Rota tab. Layout / profile / cell content
/// come from the Export (settings) tab; here the user picks:
///   1. Scope — full rota vs. one employee
///   2. Format — pdf / xlsx / csv / markdown / json (+ ics / text for employee)
///   3. Preview (inline with the format row), Export, or direct send via the
///      employee's preferred contact channel (iMessage / WhatsApp / Email).
struct ExportSheetView: View {
    let weekStart: String
    let service: AutorotaServiceProtocol
    @Environment(\.dismiss) private var dismiss

    // MARK: - Settings (from Export tab)

    // Full View defaults
    @AppStorage("exportDefaultLayout") private var fullLayout: String = "employee_by_weekday"

    // Employee exports have a fixed shape: shift name + times, never wages.
    private let empProfile = "staff_schedule"

    // Text-message body template (shared with the future bulk-send feature)
    @AppStorage(BulkSendSettings.weekHeaderKey)   private var msgWeekHeader: Bool = true
    @AppStorage(BulkSendSettings.shiftLineKey)    private var msgShiftLine: Bool = true
    @AppStorage(BulkSendSettings.customPrefixKey) private var msgCustomPrefix: String = ""
    @AppStorage(BulkSendSettings.customSuffixKey) private var msgCustomSuffix: String = ""

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

    @State private var scope: Scope = .fullRota
    @State private var selectedEmployeeId: Int64?
    @State private var format: String = "pdf"

    // MARK: - Export state

    @State private var employees: [FfiEmployee] = []
    @State private var loadingEmployees = false
    @State private var weekSchedule: FfiWeekSchedule?
    @State private var isExporting = false
    @State private var error: String?
    @State private var exportURLs: [URL] = []
    @State private var showShareSheet = false
    @State private var tempDir: URL?

    // Preview state
    @State private var isPreviewing = false
    @State private var previewPayload: PreviewPayload?

    // Direct-send state. Tracks which channel is mid-send so only that row
    // shows a spinner while all rows are disabled.
    @State private var sendingChannel: BulkSendChannel?
    #if os(iOS)
    @State private var messagePayload: MessagePayload?
    @State private var mailPayload: MailPayload?
    #endif

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let title: String
        let format: String
        let result: FfiExportResult
        let footnote: String?
    }

    #if os(iOS)
    private struct MessagePayload: Identifiable {
        let id = UUID()
        let recipient: String
        let body: String
        let attachment: MessageComposeView.Attachment?
    }

    private struct MailPayload: Identifiable {
        let id = UUID()
        let recipient: String
        let subject: String
        let body: String
        let attachment: MailComposeView.Attachment?
    }
    #endif

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
                            Text("Custom").tag(FullExportConfigBuilder.customLayoutPref)
                        }
                        .pickerStyle(.segmented)

                        if fullLayout == FullExportConfigBuilder.customLayoutPref {
                            NavigationLink {
                                ExportSandboxEditorView(service: service)
                            } label: {
                                Label("Edit Custom Layout", systemImage: "slider.horizontal.3")
                            }
                        }
                    } header: {
                        Text("Layout")
                    }
                }

                if scope == .perEmployee {
                    Section {
                        employeeRow
                    } header: {
                        Text("Employee")
                    }
                }

                Section {
                    HStack {
                        Picker("Format", selection: $format) {
                            ForEach(availableFormats) { f in
                                Text(f.label).tag(f.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Format")

                        Spacer()

                        Button {
                            Task { await runPreview() }
                        } label: {
                            HStack(spacing: 6) {
                                if isPreviewing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "eye")
                                }
                                Text("Preview")
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(isPreviewing || isExporting || !canExport)
                    }
                } header: {
                    Text("Format")
                } footer: {
                    if format != "text" {
                        Text("Layout and cell content use your Export tab settings.")
                    }
                }

                if scope == .perEmployee && format == "text" {
                    Section {
                        Toggle("Week header", isOn: $msgWeekHeader)
                        Toggle("Per-shift lines", isOn: $msgShiftLine)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Prefix").font(.caption).foregroundStyle(.secondary)
                            TextField("e.g. Hi {first_name},", text: $msgCustomPrefix, axis: .vertical)
                                .lineLimit(1...3)
                                #if canImport(UIKit)
                                .textInputAutocapitalization(.sentences)
                                #endif
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Suffix").font(.caption).foregroundStyle(.secondary)
                            TextField("e.g. Let me know if any clashes.", text: $msgCustomSuffix, axis: .vertical)
                                .lineLimit(1...3)
                                #if canImport(UIKit)
                                .textInputAutocapitalization(.sentences)
                                #endif
                        }
                    } header: {
                        Text("Message")
                    } footer: {
                        Text("`{first_name}`, `{last_name}`, `{name}` are substituted with the employee's name.")
                    }
                }

                if scope == .perEmployee, let employee = selectedEmployee {
                    let channels = directChannels(for: employee)
                    if !channels.isEmpty {
                        Section {
                            ForEach(Array(channels.enumerated()), id: \.offset) { _, channel in
                                directSendButton(employee: employee, channel: channel)
                            }
                        } header: {
                            Text("Send Directly")
                        } footer: {
                            if channels.contains(where: { whatsAppFileBlocked($0) }) {
                                Text("WhatsApp can only deliver the text message. Pick the Text format to send via WhatsApp.")
                            } else if format == "text" {
                                Text("Opens a pre-filled message to \(employee.displayName).")
                            } else {
                                Text("Attaches the exported file with the message to \(employee.displayName).")
                            }
                        }
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
            .sheet(item: $messagePayload) { payload in
                MessageComposeView(
                    recipient: payload.recipient,
                    body: payload.body,
                    attachments: payload.attachment.map { [$0] } ?? [],
                    onResult: { _ in }
                )
            }
            .sheet(item: $mailPayload) { payload in
                MailComposeView(
                    recipient: payload.recipient,
                    subject: payload.subject,
                    body: payload.body,
                    attachments: payload.attachment.map { [$0] } ?? [],
                    onResult: { _, _ in }
                )
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

    private var selectedEmployee: FfiEmployee? {
        guard let id = selectedEmployeeId else { return nil }
        return employees.first(where: { $0.id == id })
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
            list.append(.init(id: "text", label: String(localized: "Text Message")))
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
        case .fullRota: return true
        case .perEmployee: return selectedEmployeeId != nil
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

    private func loadWeekScheduleIfNeeded() async throws {
        if weekSchedule == nil {
            weekSchedule = try await service.getWeekSchedule(weekStart: weekStart)
        }
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
                guard let id = selectedEmployeeId else { return }
                let result = try await employeeExportResult(id: id)
                urls = [try writeResult(result, into: dir)]
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
                guard let id = selectedEmployeeId else { return }
                let result = try await employeeExportResult(id: id)
                let name = employees.first(where: { $0.id == id })?.displayName ?? "Employee"
                previewPayload = PreviewPayload(
                    title: "Preview · \(name)",
                    format: format,
                    result: result,
                    footnote: nil
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
        FullExportConfigBuilder.make(
            layoutPref: fullLayout,
            format: format
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
            showShiftName: true,
            showTimes: true,
            showRole: false,
            timezoneId: TimeZone.current.identifier
        )
    }

    /// Export result for one employee. The "text" format is rendered locally
    /// from the message template; everything else goes through the FFI.
    private func employeeExportResult(id: Int64) async throws -> FfiExportResult {
        if format == "text" {
            try await loadWeekScheduleIfNeeded()
            guard let employee = employees.first(where: { $0.id == id }) else {
                throw ExportSheetError.employeeNotFound
            }
            let body = MessageBodyBuilder.build(
                employee: employee,
                weekStart: weekStart,
                schedule: weekSchedule
            )
            return FfiExportResult(
                data: body,
                filename: textFilename(for: employee),
                mimeType: "text/plain"
            )
        }
        return try await service.exportEmployeeSchedule(config: employeeConfig(id: id))
    }

    private func textFilename(for employee: FfiEmployee) -> String {
        let slug = employee.displayName
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, c in
                if c == "-" && acc.hasSuffix("-") { return }
                acc.append(c)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "rota-\(slug.isEmpty ? "employee" : slug)-\(weekStart).txt"
    }

    private func exportFullRota(into dir: URL) async throws -> URL {
        let result = try await service.exportWeekSchedule(
            weekStart: weekStart,
            config: fullRotaConfig()
        )
        return try writeResult(result, into: dir)
    }

    // MARK: - Direct send

    /// Contact channels for the selected employee: the preferred channel
    /// first, plus email when an address is saved and the preferred channel
    /// isn't already email. Empty when no usable contact info is saved (the
    /// section is hidden entirely).
    private func directChannels(for employee: FfiEmployee) -> [BulkSendChannel] {
        var channels: [BulkSendChannel] = []
        if case let .ready(channel) = BulkSendDispatcher.resolveContact(employee: employee) {
            channels.append(channel)
        }
        let email = employee.email?.trimmingCharacters(in: .whitespaces) ?? ""
        let hasEmailChannel = channels.contains { if case .email = $0 { true } else { false } }
        if !email.isEmpty && !hasEmailChannel {
            channels.append(.email(address: email))
        }
        return channels
    }

    private func directSendButton(employee: FfiEmployee, channel: BulkSendChannel) -> some View {
        Button {
            Task { await sendDirectly(to: employee, via: channel) }
        } label: {
            HStack {
                if sendingChannel == channel {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: channel.icon)
                }
                Text("Send via \(channel.label)")
                Spacer()
                Text(destinationLabel(for: channel))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .disabled(!canExport || isExporting || isPreviewing || sendingChannel != nil || whatsAppFileBlocked(channel))
    }

    /// WhatsApp's URL scheme carries text only — file formats can't be
    /// attached, so the direct-send button is disabled for them.
    private func whatsAppFileBlocked(_ channel: BulkSendChannel) -> Bool {
        if case .whatsApp = channel { return format != "text" }
        return false
    }

    private func destinationLabel(for channel: BulkSendChannel) -> String {
        switch channel {
        case .iMessage(let phone), .whatsApp(let phone): phone
        case .email(let address): address
        }
    }

    private func sendDirectly(to employee: FfiEmployee, via channel: BulkSendChannel) async {
        sendingChannel = channel
        error = nil
        defer { sendingChannel = nil }

        do {
            try await loadWeekScheduleIfNeeded()
            let body = MessageBodyBuilder.build(
                employee: employee,
                weekStart: weekStart,
                schedule: weekSchedule
            )

            switch channel {
            case .iMessage(let phone):
                #if os(iOS)
                guard MessageComposeView.canSend else {
                    throw ExportSheetError.messagesUnavailable
                }
                if format == "text" {
                    messagePayload = MessagePayload(recipient: phone, body: body, attachment: nil)
                } else {
                    guard MessageComposeView.canSendAttachments else {
                        throw ExportSheetError.attachmentsUnavailable
                    }
                    let result = try await employeeExportResult(id: employee.id)
                    messagePayload = MessagePayload(
                        recipient: phone,
                        body: body,
                        attachment: MessageComposeView.Attachment(
                            data: try payloadData(result),
                            typeIdentifier: typeIdentifier(for: result.filename),
                            filename: result.filename
                        )
                    )
                }
                #endif

            case .whatsApp(let phone):
                openWhatsApp(phone: phone, body: body)

            case .email(let address):
                let attachmentResult = format == "text"
                    ? nil
                    : try await employeeExportResult(id: employee.id)
                #if os(iOS)
                guard MailComposeView.canSend else {
                    throw ExportSheetError.mailUnavailable
                }
                mailPayload = MailPayload(
                    recipient: address,
                    subject: emailSubject(),
                    body: body,
                    attachment: try attachmentResult.map {
                        MailComposeView.Attachment(
                            data: try payloadData($0),
                            mimeType: $0.mimeType,
                            fileName: $0.filename
                        )
                    }
                )
                #else
                var urls: [URL] = []
                if let result = attachmentResult {
                    let dir = try makeTempDir()
                    tempDir = dir
                    urls = [try writeResult(result, into: dir)]
                }
                if !MacMailDispatcher.compose(
                    recipient: address,
                    subject: emailSubject(),
                    body: body,
                    attachments: urls
                ) {
                    throw ExportSheetError.mailUnavailable
                }
                #endif
            }
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    private func openWhatsApp(phone: String, body: String) {
        let digits = phone.filter { $0.isNumber }
        var comps = URLComponents(string: "https://wa.me/\(digits)")
        comps?.queryItems = [URLQueryItem(name: "text", value: body)]
        guard let url = comps?.url else {
            error = String(localized: "Invalid phone number.")
            return
        }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func emailSubject() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let pretty: String
        if let date = fmt.date(from: weekStart) {
            let out = DateFormatter()
            out.dateFormat = "d MMM yyyy"
            pretty = out.string(from: date)
        } else {
            pretty = weekStart
        }
        return String(localized: "Rota for week of \(pretty)")
    }

    private func payloadData(_ result: FfiExportResult) throws -> Data {
        if isBinary(format: format) {
            guard let data = Data(base64Encoded: result.data) else {
                throw ExportSheetError.invalidBinaryPayload
            }
            return data
        }
        return Data(result.data.utf8)
    }

    private func typeIdentifier(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        return UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
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
        case "text":
            return [.plainText]
        default: return []
        }
    }
    #endif
}

private enum ExportSheetError: LocalizedError {
    case invalidBinaryPayload
    case employeeNotFound
    case messagesUnavailable
    case attachmentsUnavailable
    case mailUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidBinaryPayload:
            return String(localized: "The exported binary payload could not be decoded.")
        case .employeeNotFound:
            return String(localized: "The selected employee could not be found.")
        case .messagesUnavailable:
            return String(localized: "Messages is not available on this device.")
        case .attachmentsUnavailable:
            return String(localized: "This device can't send attachments via Messages.")
        case .mailUnavailable:
            return String(localized: "Mail is not configured on this device.")
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
