import Foundation
import SwiftUI
import AutorotaKit

/// Drives the drag-and-drop custom-layout sandbox on the Export tab.
///
/// The placement state lives in one `ExportCustomLayout` value; the trays are
/// derived from it, so a field pill can never appear in two zones at once.
@Observable
final class ExportSandboxViewModel {

    enum Zone: Equatable {
        case tray, rows, cells
    }

    private(set) var layout: ExportCustomLayout
    var availableRoles: [FfiRole] = []
    var rolesLoaded = false
    var rolesError: String?

    /// Set briefly after a rejected drop so the UI can explain why.
    var rejectionMessage: String?

    private let service: AutorotaServiceProtocol
    private let defaults: UserDefaults

    init(
        service: AutorotaServiceProtocol = GatedAutorotaService(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
        self.layout = ExportCustomLayout.load(from: defaults) ?? .initial
    }

    // MARK: - Derived state

    /// Field pills not yet placed in rows or cells.
    var trayFields: [ExportField] {
        ExportField.allCases.filter { !layout.rows.contains($0) && !layout.cells.contains($0) }
    }

    /// Roles not yet dragged onto the grid as sections.
    var trayRoles: [FfiRole] {
        availableRoles.filter { role in !layout.sections.contains { $0.id == role.id } }
    }

    var validationError: CustomLayoutError? {
        ExportCustomLayoutMapper.validate(layout)
    }

    var guidanceText: String? {
        rejectionMessage ?? validationError?.guidance
    }

    private func zone(of field: ExportField) -> Zone {
        if layout.rows.contains(field) { return .rows }
        if layout.cells.contains(field) { return .cells }
        return .tray
    }

    // MARK: - Field pills

    /// The employee pill may go in rows or cells. The cost pill is cells-only
    /// (it switches the export to the manager report) and may share the cells
    /// with the employee pill — the engine appends costs to names. Any other
    /// pill is blocked in whichever zone holds the employee pill, because
    /// those zones render employee names only.
    func canDrop(_ field: ExportField, in zone: Zone) -> Bool {
        switch zone {
        case .tray:
            return true
        case .rows:
            if field == .employeeName { return true }
            if field == .cost { return false }
            return self.zone(of: .employeeName) != .rows
        case .cells:
            if field == .employeeName || field == .cost { return true }
            return self.zone(of: .employeeName) != .cells
        }
    }

    /// Returns true when the drop was accepted.
    @discardableResult
    func drop(_ field: ExportField, in zone: Zone) -> Bool {
        guard canDrop(field, in: zone) else {
            rejectionMessage = if field == .cost {
                String(localized: "Cost can only go in the table cells.")
            } else if zone == .rows {
                String(localized: "Rows show employee names — put shift details in the cells.")
            } else {
                String(localized: "Cells show employee names — put shift details in the rows.")
            }
            return false
        }
        rejectionMessage = nil
        layout.rows.removeAll { $0 == field }
        layout.cells.removeAll { $0 == field }
        // A zone holding the employee pill renders names only, so any field
        // pills already there go back to the tray instead of sitting dead.
        // Cost stays: the engine appends costs to the names.
        if field == .employeeName {
            switch zone {
            case .rows: layout.rows.removeAll()
            case .cells: layout.cells.removeAll { $0 != .cost }
            case .tray: break
            }
        }
        switch zone {
        case .rows: layout.rows.append(field)
        case .cells: layout.cells.append(field)
        case .tray: break
        }
        persist()
        return true
    }

    func returnToTray(_ field: ExportField) {
        drop(field, in: .tray)
    }

    // MARK: - Role sections

    func addSection(_ role: FfiRole, at index: Int? = nil) {
        guard !layout.sections.contains(where: { $0.id == role.id }) else { return }
        let section = ExportRoleSection(id: role.id, name: role.name)
        if let index, index <= layout.sections.count {
            layout.sections.insert(section, at: index)
        } else {
            layout.sections.append(section)
        }
        persist()
    }

    func removeSection(id: Int64) {
        layout.sections.removeAll { $0.id == id }
        persist()
    }

    func moveSections(from source: IndexSet, to destination: Int) {
        layout.sections.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Roles

    /// Loads roles, refreshes persisted section names after renames, and
    /// drops sections whose role was deleted.
    func loadRoles() async {
        rolesError = nil
        do {
            availableRoles = try await service.listRoles()
            let byId = Dictionary(uniqueKeysWithValues: availableRoles.map { ($0.id, $0.name) })
            var changed = false
            layout.sections = layout.sections.compactMap { section in
                guard let name = byId[section.id] else {
                    changed = true
                    return nil
                }
                if name != section.name {
                    changed = true
                    return ExportRoleSection(id: section.id, name: name)
                }
                return section
            }
            if changed { persist() }
        } catch {
            rolesError = userFacingMessage(error)
        }
        rolesLoaded = true
    }

    // MARK: - Persistence

    private func persist() {
        layout.save(to: defaults)
    }
}
