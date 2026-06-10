import SwiftUI
import AutorotaKit

/// Drag-and-drop sandbox for the "Custom" export layout: a live template
/// table, two side-by-side drop zones (row headers | cells) where placed
/// pills stack in a column, a tray of consumable field pills, and role pills
/// that place into an export-order box on tap — top-to-bottom order is the
/// section order in the export.
struct ExportSandboxView: View {
    @Bindable var viewModel: ExportSandboxViewModel

    @State private var rowsZoneTargeted = false
    @State private var cellsZoneTargeted = false
    @State private var roleZoneTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let guidance = viewModel.guidanceText {
                Label(guidance, systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            MockExportTableView(viewModel: viewModel)

            dropZones
            fieldTray
            roleTray
        }
        .sensoryFeedback(.error, trigger: viewModel.rejectionMessage) { _, new in new != nil }
        .task { await viewModel.loadRoles() }
    }

    // MARK: - Drop zones

    /// Side-by-side drop targets mirroring the table: row headers on the
    /// left, cells on the right. Placed pills stack in a column inside each.
    private var dropZones: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            dropZone(
                title: String(localized: "Row headers"),
                systemImage: "list.bullet",
                fields: viewModel.layout.rows,
                zone: .rows,
                targeted: $rowsZoneTargeted
            )
            dropZone(
                title: String(localized: "Cells"),
                systemImage: "tablecells",
                fields: viewModel.layout.cells,
                zone: .cells,
                targeted: $cellsZoneTargeted
            )
        }
    }

    private func dropZone(
        title: String,
        systemImage: String,
        fields: [ExportField],
        zone: ExportSandboxViewModel.Zone,
        targeted: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            if fields.isEmpty {
                Text("Drop a pill here")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(fields) { field in
                pill(for: field)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SurfaceRadius.small, style: .continuous)
                .fill(targeted.wrappedValue
                    ? Color.accentColor.opacity(0.15)
                    : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SurfaceRadius.small, style: .continuous)
                .strokeBorder(
                    targeted.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .contentShape(Rectangle())
        .dropDestination(for: ExportPillPayload.self) { items, _ in
            guard let item = items.first, case .field(let field) = item.kind else { return false }
            return viewModel.drop(field, in: zone)
        } isTargeted: { targeted.wrappedValue = $0 }
    }

    // MARK: - Trays

    private var fieldTray: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Fields")
                .font(.caption)
                .foregroundStyle(.secondary)
            if viewModel.trayFields.isEmpty {
                Text("All fields placed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                flowRow {
                    ForEach(viewModel.trayFields) { field in
                        pill(for: field)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        // Dragging a pill back to the tray un-places it.
        .dropDestination(for: ExportPillPayload.self) { items, _ in
            guard let item = items.first, case .field(let field) = item.kind else { return false }
            viewModel.returnToTray(field)
            return true
        }
    }

    private var roleTray: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Role sections")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Tap or drag a role into the order box to split the export into one table per role, top to bottom.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let error = viewModel.rolesError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if !viewModel.rolesLoaded {
                ProgressView()
                    .controlSize(.small)
            } else if viewModel.availableRoles.isEmpty {
                Text("No roles defined yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    availableRoleColumn
                    roleOrderZone
                }
            }
        }
    }

    /// Unplaced role pills: one tap (or a drag into the order box) places
    /// the role as a section.
    private var availableRoleColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if viewModel.trayRoles.isEmpty {
                Text("All roles placed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(viewModel.trayRoles, id: \.id) { role in
                Button {
                    viewModel.addSection(role)
                } label: {
                    ExportPillView(
                        label: role.name,
                        systemImage: "person.text.rectangle",
                        tint: .purple
                    )
                }
                .buttonStyle(.borderless)
                .draggable(ExportPillPayload.role(role))
                .accessibilityLabel(Text(role.name))
                .accessibilityHint(Text("Adds a section for this role"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Placed role sections in export order, top to bottom. Drop target for
    /// role pills; reorder/remove via each pill's menu.
    private var roleOrderZone: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(String(localized: "Export order"), systemImage: "arrow.up.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
            if viewModel.layout.sections.isEmpty {
                Text("Drop a role here")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(viewModel.layout.sections.enumerated()), id: \.element.id) { index, section in
                placedRolePill(section, index: index)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SurfaceRadius.small, style: .continuous)
                .fill(roleZoneTargeted
                    ? Color.purple.opacity(0.15)
                    : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SurfaceRadius.small, style: .continuous)
                .strokeBorder(
                    roleZoneTargeted ? Color.purple : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .contentShape(Rectangle())
        .dropDestination(for: ExportPillPayload.self) { items, _ in
            guard let item = items.first, case .role(let id, let name) = item.kind else { return false }
            viewModel.addSection(FfiRole(id: id, name: name))
            return true
        } isTargeted: { roleZoneTargeted = $0 }
    }

    private func placedRolePill(_ section: ExportRoleSection, index: Int) -> some View {
        let count = viewModel.layout.sections.count
        return Menu {
            Button("Move Up") {
                viewModel.moveSections(from: IndexSet(integer: index), to: index - 1)
            }
            .disabled(index == 0)
            Button("Move Down") {
                viewModel.moveSections(from: IndexSet(integer: index), to: index + 2)
            }
            .disabled(index == count - 1)
            Button("Remove", role: .destructive) {
                viewModel.removeSection(id: section.id)
            }
        } label: {
            ExportPillView(
                label: "\(index + 1). \(section.name)",
                systemImage: "person.text.rectangle",
                tint: .purple
            )
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("\(section.name), position \(index + 1) of \(count)"))
    }

    // MARK: - Pieces

    /// A field pill: draggable, and tappable for a menu fallback so the
    /// sandbox stays usable without drag gestures. A tap `Menu` (not
    /// `contextMenu`) because Form rows merge multiple context menus into
    /// the row's first one.
    private func pill(for field: ExportField) -> some View {
        Menu {
            if viewModel.canDrop(field, in: .rows) {
                Button("Move to Row Headers") { viewModel.drop(field, in: .rows) }
            }
            if viewModel.canDrop(field, in: .cells) {
                Button("Move to Cells") { viewModel.drop(field, in: .cells) }
            }
            Button("Return to Tray") { viewModel.returnToTray(field) }
        } label: {
            ExportPillView(label: field.label, systemImage: field.systemImage)
        }
        .buttonStyle(.borderless)
        .draggable(ExportPillPayload.field(field))
        .accessibilityLabel(Text(field.label))
    }

    private func flowRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) { content() }
        }
    }
}
