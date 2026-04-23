import SwiftUI

/// Settings page that configures how each rota export looks. The actual
/// "export" action lives on the Rota tab's Share sheet, which reads these
/// defaults and only asks the user to pick a format.
struct ExportTabView: View {

    @AppStorage("exportDefaultLayout") private var layout: String = "employee_by_weekday"
    @AppStorage("exportDefaultProfile") private var profile: String = "staff_schedule"
    @AppStorage("exportDefaultPdfTemplate") private var pdfTemplate: String = "weekly_grid"
    @AppStorage("exportShowShiftName") private var showShiftName: Bool = true
    @AppStorage("exportShowTimes") private var showTimes: Bool = true
    @AppStorage("exportShowRole") private var showRole: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Layout", selection: $layout) {
                        Text("By Employee").tag("employee_by_weekday")
                        Text("By Shift").tag("shift_by_weekday")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Layout")
                } footer: {
                    Text("How rows and columns are arranged in the exported schedule.")
                }

                Section {
                    Picker("Profile", selection: $profile) {
                        Text("Staff Schedule").tag("staff_schedule")
                        Text("Manager Report").tag("manager_report")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Manager Report includes wages and cost totals.")
                }

                Section {
                    Toggle("Shift Name", isOn: $showShiftName)
                    Toggle("Times", isOn: $showTimes)
                    Toggle("Role", isOn: $showRole)
                } header: {
                    Text("Cell Content")
                } footer: {
                    Text("What each assignment cell shows.")
                }

                Section {
                    Picker("Template", selection: $pdfTemplate) {
                        Text("Weekly Grid").tag("weekly_grid")
                        Text("Per Employee").tag("per_employee")
                        Text("By Role").tag("by_role")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("PDF Template")
                } footer: {
                    Text("Applied when exporting as PDF.")
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
