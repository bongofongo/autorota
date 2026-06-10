import SwiftUI
import AutorotaKit
#if os(macOS)
import UniformTypeIdentifiers
#endif

/// One-shot per-employee bundle: PDF + ICS + Markdown + XLSX.
/// iOS presents all four files through `UIActivityViewController`; macOS saves
/// them into a user-selected folder.
struct SendSchedulePicker: View {
    let employee: FfiEmployee
    let service: AutorotaServiceProtocol

    @Environment(\.dismiss) private var dismiss

    @State private var dateMode: DateMode = .singleWeek
    @State private var weekStart: Date = Self.currentWeekStart()
    @State private var startDate: Date = Self.currentWeekStart()
    @State private var endDate: Date = Self.currentWeekStart().addingTimeInterval(6 * 24 * 3600)

    // Employee exports have a fixed shape: shift name + times, never wages.
    private let profile = "staff_schedule"

    @State private var isWorking = false
    @State private var error: String?
    @State private var bundleURLs: [URL] = []
    @State private var showShareSheet = false
    @State private var bundleTempDir: URL?

    enum DateMode: String, CaseIterable, Identifiable {
        case singleWeek = "Week"
        case dateRange = "Date Range"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipient") {
                    HStack {
                        Text(employee.displayName).font(.headline)
                        Spacer()
                    }
                    if let phone = employee.phone, !phone.isEmpty {
                        HStack {
                            Text("Phone").foregroundStyle(.secondary)
                            Spacer()
                            Text(phone)
                        }
                    }
                    if let method = employee.preferredContact, !method.isEmpty {
                        HStack {
                            Text("Preferred").foregroundStyle(.secondary)
                            Spacer()
                            Text(prettyContact(method))
                        }
                    }
                }

                Section("Period") {
                    Picker("Period", selection: $dateMode) {
                        ForEach(DateMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)

                    if dateMode == .singleWeek {
                        DatePicker("Week of", selection: $weekStart, displayedComponents: .date)
                    } else {
                        DatePicker("Start", selection: $startDate, displayedComponents: .date)
                        DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }

                Section {
                    Text("Generates PDF, ICS calendar, Markdown summary, and XLSX spreadsheet using your Export tab Employee View settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Send Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cleanup(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await run() } }
                    }
                }
            }
            .errorAlert($error)
            #if os(iOS)
            .sheet(isPresented: $showShareSheet, onDismiss: { cleanup(); dismiss() }) {
                if !bundleURLs.isEmpty {
                    ShareSheet(activityItems: bundleURLs)
                }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 440, idealHeight: 520)
        #endif
    }

    private func run() async {
        isWorking = true
        error = nil
        defer { isWorking = false }

        let (start, end) = resolveRange()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        let config = FfiEmployeeExportConfig(
            employeeId: employee.id,
            startDate: fmt.string(from: start),
            endDate: fmt.string(from: end),
            format: "pdf", // ignored by bundle
            profile: profile,
            showShiftName: true,
            showTimes: true,
            showRole: false,
            timezoneId: TimeZone.current.identifier
        )

        do {
            let results = try await service.exportEmployeeBundle(config: config)

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("autorota-bundle-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            bundleTempDir = dir

            var urls: [URL] = []
            for r in results {
                let url = dir.appendingPathComponent(r.filename)
                if r.mimeType == "application/pdf"
                    || r.mimeType.contains("spreadsheetml") {
                    guard let data = Data(base64Encoded: r.data) else {
                        throw BundleError.invalidBinary
                    }
                    try data.write(to: url, options: .atomic)
                } else {
                    try r.data.write(to: url, atomically: true, encoding: .utf8)
                }
                urls.append(url)
            }
            bundleURLs = urls

            #if os(iOS)
            showShareSheet = true
            #else
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
            cleanup()
            dismiss()
            #endif
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    private func resolveRange() -> (Date, Date) {
        if dateMode == .singleWeek {
            let end = weekStart.addingTimeInterval(6 * 24 * 3600)
            return (weekStart, end)
        }
        return (startDate, endDate)
    }

    private func cleanup() {
        if let dir = bundleTempDir {
            try? FileManager.default.removeItem(at: dir)
            bundleTempDir = nil
        }
        bundleURLs = []
    }

    private func prettyContact(_ raw: String) -> String {
        switch raw {
        case "imessage": "iMessage"
        case "whatsapp": "WhatsApp"
        default: raw
        }
    }

    private static func currentWeekStart() -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2 // Monday
        let now = Date()
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return cal.date(from: comps) ?? now
    }
}

private enum BundleError: LocalizedError {
    case invalidBinary
    var errorDescription: String? { "A bundle file could not be decoded." }
}

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
