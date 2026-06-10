import Foundation
import AutorotaKit

/// A draggable field pill in the custom export sandbox.
enum ExportField: String, Codable, CaseIterable, Identifiable {
    case shiftName
    case time
    case role
    case employeeName
    /// Cells-only. Placing it switches the export to the manager report
    /// (per-assignment costs + daily/weekly totals); otherwise the export is
    /// the staff schedule with no wage data.
    case cost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shiftName: return String(localized: "Shift name")
        case .time: return String(localized: "Time")
        case .role: return String(localized: "Role")
        case .employeeName: return String(localized: "Employee name")
        case .cost: return String(localized: "Cost")
        }
    }
}

/// A role the user dragged onto the sandbox as a section separator. Keyed by
/// role id so renames survive; `name` is refreshed against `listRoles()` on
/// load and is what the export engine receives.
struct ExportRoleSection: Codable, Equatable, Identifiable {
    let id: Int64
    var name: String
}

/// Persisted custom-layout configuration: which field pills sit in the row
/// header column vs. the table cells, plus ordered role sections. Column
/// headers are always Mon–Sun and are not represented here.
struct ExportCustomLayout: Codable, Equatable {
    var rows: [ExportField] = []
    var cells: [ExportField] = []
    var sections: [ExportRoleSection] = []

    static let storageKey = "exportCustomLayout"

    /// Starting point when the user first opens the sandbox: the same shape
    /// as the By Employee preset, so the initial state is always valid.
    static let initial = ExportCustomLayout(
        rows: [.employeeName],
        cells: [.shiftName, .time],
        sections: []
    )

    static func load(from defaults: UserDefaults = .standard) -> ExportCustomLayout? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ExportCustomLayout.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// Why a custom layout can't be exported yet.
enum CustomLayoutError: Error, Equatable {
    /// The employee-name pill is in the tray; the engine needs it in rows or cells.
    case employeeUnplaced
    /// Employee in rows but no pill in cells.
    case cellsEmpty
    /// Employee in cells but no pill in rows.
    case rowsEmpty

    var guidance: String {
        switch self {
        case .employeeUnplaced:
            return String(localized: "Drag the Employee name pill into the rows or the cells.")
        case .cellsEmpty:
            return String(localized: "Drag at least one pill into the table cells.")
        case .rowsEmpty:
            return String(localized: "Drag at least one pill into the row headers.")
        }
    }
}

/// Pure mapping from sandbox placements to the FFI export config. The engine
/// has two layouts; the employee pill's zone picks which one:
/// - employee in rows  → employee_by_weekday, cell pills become show_* flags
/// - employee in cells → shift_by_weekday, row pills become rowContent flags
/// The cost pill in cells selects the manager-report profile (per-assignment
/// costs + totals); without it the export is the staff schedule.
enum ExportCustomLayoutMapper {

    static func validate(_ layout: ExportCustomLayout) -> CustomLayoutError? {
        if layout.rows.contains(.employeeName) {
            return layout.cells.isEmpty ? .cellsEmpty : nil
        }
        if layout.cells.contains(.employeeName) {
            return layout.rows.isEmpty ? .rowsEmpty : nil
        }
        return .employeeUnplaced
    }

    static func profile(for layout: ExportCustomLayout) -> String {
        layout.cells.contains(.cost) ? "manager_report" : "staff_schedule"
    }

    static func ffiConfig(
        _ layout: ExportCustomLayout,
        format: String
    ) throws -> FfiExportConfig {
        if let error = validate(layout) { throw error }

        let sections = layout.sections.isEmpty ? nil : layout.sections.map(\.name)
        let profile = profile(for: layout)

        if layout.rows.contains(.employeeName) {
            return FfiExportConfig(
                layout: "employee_by_weekday",
                format: format,
                profile: profile,
                showShiftName: layout.cells.contains(.shiftName),
                showTimes: layout.cells.contains(.time),
                showRole: layout.cells.contains(.role),
                pdfTemplate: nil,
                roleSections: sections,
                rowContent: nil
            )
        }

        return FfiExportConfig(
            layout: "shift_by_weekday",
            format: format,
            profile: profile,
            showShiftName: false,
            showTimes: false,
            showRole: false,
            pdfTemplate: nil,
            roleSections: sections,
            rowContent: FfiRowContent(
                showShiftName: layout.rows.contains(.shiftName),
                showTimes: layout.rows.contains(.time),
                showRole: layout.rows.contains(.role)
            )
        )
    }
}
