import SwiftUI

/// Settings page that configures how each export looks. Mirrors the two
/// scopes on the Rota-tab share pull-up: Full View and Employee View. The
/// share sheet reads these defaults and only asks the user to pick a scope
/// and format.
struct ExportTabView: View {

    // MARK: - Full View defaults

    @AppStorage("exportDefaultLayout") private var fullLayout: String = "employee_by_weekday"
    @AppStorage("exportDefaultProfile") private var fullProfile: String = "staff_schedule"
    @AppStorage("exportDefaultPdfTemplate") private var fullPdfTemplate: String = "weekly_grid"
    @AppStorage("exportShowShiftName") private var fullShowShiftName: Bool = true
    @AppStorage("exportShowTimes") private var fullShowTimes: Bool = true
    @AppStorage("exportShowRole") private var fullShowRole: Bool = true

    // MARK: - Employee View defaults
    //
    // Employee exports are always "staff_schedule" — employees shouldn't see
    // wage/cost data — so there is no profile picker in this section.

    @AppStorage("empExportShowShiftName") private var empShowShiftName: Bool = true
    @AppStorage("empExportShowTimes") private var empShowTimes: Bool = true

    private let service: AutorotaServiceProtocol

    @State private var previewScope: ExportPreviewSheet.Scope?

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
        self.service = service
    }

    var body: some View {
        NavigationStack {
            Form {
                fullViewSection
                employeeViewSection
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
            }
            .pickerStyle(.segmented)
            .onChange(of: fullLayout) { _, new in
                if new == "shift_by_weekday" { fullShowShiftName = false }
            }

            Picker("Profile", selection: $fullProfile) {
                Text("Staff Schedule").tag("staff_schedule")
                Text("Manager Report").tag("manager_report")
            }
            .pickerStyle(.segmented)

            Toggle("Shift Name", isOn: $fullShowShiftName)
                .disabled(fullLayout == "shift_by_weekday")
            Toggle("Times", isOn: $fullShowTimes)
            Toggle("Role", isOn: $fullShowRole)
                .disabled(fullLayout == "employee_by_weekday")

            Picker("PDF Template", selection: $fullPdfTemplate) {
                Text("Weekly Grid").tag("weekly_grid")
                Text("Per Employee").tag("per_employee")
                Text("By Role").tag("by_role")
            }

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

    // MARK: - Employee View

    private var employeeViewSection: some View {
        Section {
            Toggle("Shift Name", isOn: $empShowShiftName)
            Toggle("Times", isOn: $empShowTimes)

            Button {
                previewScope = .employee
            } label: {
                Label("Preview PDF", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Employee View")
        } footer: {
            Text("Applied when exporting per-employee schedules, whether for all employees or a single one. Wage and cost data are never included.")
        }
    }
}

extension ExportPreviewSheet.Scope: Identifiable {
    public var id: String { rawValue }
}
