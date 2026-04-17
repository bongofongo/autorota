import SwiftUI
import AutorotaKit
#if os(macOS)
import UniformTypeIdentifiers
#endif

struct ExportTabView: View {

    // MARK: - Rota Export State

    @State private var rotaWeekStart: String = currentWeekStart()
    @State private var showRotaExportSheet = false

    // MARK: - Employee Export State

    @State private var vm = EmployeeExportViewModel()
    @State private var exportFileURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            Form {
                rotaExportSection
                employeeExportSection
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await vm.loadEmployees() }
            .alert("Export Error", isPresented: .constant(vm.error != nil)) {
                Button("OK") { vm.error = nil }
            } message: {
                Text(vm.error ?? "")
            }
            .sheet(isPresented: $showRotaExportSheet) {
                ExportSheetView(weekStart: rotaWeekStart, service: vm.service)
            }
            #if os(iOS)
            .sheet(isPresented: $showShareSheet) {
                if let url = exportFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
            #endif
        }
    }

    // MARK: - Rota Export Section

    private var rotaExportSection: some View {
        Section {
            HStack {
                Text("Week")
                Spacer()
                Button(action: { changeRotaWeek(by: -1) }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text(rotaWeekLabel)
                    .monospacedDigit()
                Button(action: { changeRotaWeek(by: 1) }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
            }

            Button {
                showRotaExportSheet = true
            } label: {
                Label("Export Rota Schedule…", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Rota Schedule")
        }
    }

    // MARK: - Employee Export Section

    private var employeeExportSection: some View {
        Section {
            // Employee picker
            if vm.isLoading {
                ProgressView("Loading employees…")
            } else if vm.employees.isEmpty {
                Text("No employees found")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Employee", selection: $vm.selectedEmployeeId) {
                    ForEach(vm.employees, id: \.id) { emp in
                        Text(emp.displayName).tag(Optional(emp.id))
                    }
                }
            }

            // Date mode
            Picker("Period", selection: $vm.dateMode) {
                ForEach(EmployeeExportViewModel.DateMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // Date pickers
            if vm.dateMode == .singleWeek {
                HStack {
                    Text("Week")
                    Spacer()
                    Button(action: { changeEmployeeWeek(by: -1) }) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Text(employeeWeekLabel)
                        .monospacedDigit()
                    Button(action: { changeEmployeeWeek(by: 1) }) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                DatePicker("Start", selection: $vm.startDate, displayedComponents: .date)
                DatePicker("End", selection: $vm.endDate, in: vm.startDate..., displayedComponents: .date)
            }

            // Format
            Picker("Format", selection: $vm.format) {
                Text("CSV").tag("csv")
                Text("JSON").tag("json")
                Text("PDF").tag("pdf")
            }
            .pickerStyle(.segmented)

            // Profile
            Picker("Profile", selection: $vm.profile) {
                Text("Staff Schedule").tag("staff_schedule")
                Text("Manager Report").tag("manager_report")
            }
            .pickerStyle(.segmented)

            // Cell content toggles
            Toggle("Shift Name", isOn: $vm.showShiftName)
            Toggle("Times", isOn: $vm.showTimes)
            Toggle("Role", isOn: $vm.showRole)

            // Export button
            if vm.isExporting {
                ProgressView("Exporting…")
            } else {
                Button {
                    Task { await performEmployeeExport() }
                } label: {
                    Label("Export Employee Schedule", systemImage: "square.and.arrow.up")
                }
                .disabled(!vm.canExport)
            }
        } header: {
            Text("Employee Schedule")
        }
    }

    // MARK: - Week Navigation Helpers

    private var rotaWeekLabel: String {
        formatWeekLabel(rotaWeekStart)
    }

    private var employeeWeekLabel: String {
        formatWeekLabel(vm.selectedWeekStart)
    }

    private func formatWeekLabel(_ weekStart: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: weekStart) else { return weekStart }
        let display = DateFormatter()
        display.dateFormat = "d MMM yyyy"
        return display.string(from: date)
    }

    private func changeRotaWeek(by weeks: Int) {
        rotaWeekStart = offsetWeek(rotaWeekStart, by: weeks)
    }

    private func changeEmployeeWeek(by weeks: Int) {
        vm.selectedWeekStart = offsetWeek(vm.selectedWeekStart, by: weeks)
    }

    private func offsetWeek(_ weekStart: String, by weeks: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: weekStart),
              let next = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: date) else {
            return weekStart
        }
        return fmt.string(from: next)
    }

    // MARK: - Export Execution

    private func performEmployeeExport() async {
        guard let result = await vm.performExport() else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(result.filename)

        do {
            if vm.format == "pdf" {
                guard let pdfData = Data(base64Encoded: result.data) else {
                    vm.error = "The exported PDF payload could not be decoded."
                    return
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
            panel.allowedContentTypes = allowedContentTypes(for: vm.format)
            if panel.runModal() == .OK, let dest = panel.url {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: fileURL, to: dest)
            }
            #endif
        } catch {
            vm.error = userFacingMessage(error)
        }
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

// MARK: - iOS Share Sheet (reused from ExportSheetView)

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
