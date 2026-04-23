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

    @AppStorage("empExportDefaultProfile") private var empProfile: String = "staff_schedule"
    @AppStorage("empExportShowShiftName") private var empShowShiftName: Bool = true
    @AppStorage("empExportShowTimes") private var empShowTimes: Bool = true
    @AppStorage("empExportShowRole") private var empShowRole: Bool = true

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

            Picker("Profile", selection: $fullProfile) {
                Text("Staff Schedule").tag("staff_schedule")
                Text("Manager Report").tag("manager_report")
            }
            .pickerStyle(.segmented)

            Toggle("Shift Name", isOn: $fullShowShiftName)
            Toggle("Times", isOn: $fullShowTimes)
            Toggle("Role", isOn: $fullShowRole)

            Picker("PDF Template", selection: $fullPdfTemplate) {
                Text("Weekly Grid").tag("weekly_grid")
                Text("Per Employee").tag("per_employee")
                Text("By Role").tag("by_role")
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
            Picker("Profile", selection: $empProfile) {
                Text("Staff Schedule").tag("staff_schedule")
                Text("Manager Report").tag("manager_report")
            }
            .pickerStyle(.segmented)

            Toggle("Shift Name", isOn: $empShowShiftName)
            Toggle("Times", isOn: $empShowTimes)
            Toggle("Role", isOn: $empShowRole)
        } header: {
            Text("Employee View")
        } footer: {
            Text("Applied when exporting per-employee schedules, whether for all employees or a single one.")
        }
    }
}
