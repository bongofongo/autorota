import SwiftUI
import AutorotaKit

/// Tap-to-place sandbox for the "Custom" export layout: a live template
/// table, two side-by-side buckets (row headers | cells) where placed pills
/// stack in a column, a tray of consumable field pills, and tap-only role
/// pills that place into an export-order box — top-to-bottom order is the
/// section order in the export.
///
/// No drag gestures: tap a field pill to select it, then tap a highlighted
/// bucket (or the tray) to place it.
struct ExportSandboxView: View {
    @Bindable var viewModel: ExportSandboxViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let guidance = viewModel.guidanceText {
                Label(guidance, systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            MockExportTableView(viewModel: viewModel)

            buckets
            fieldTray
            roleTray
        }
        .sensoryFeedback(.error, trigger: viewModel.rejectionMessage) { _, new in new != nil }
        .task { await viewModel.loadRoles() }
    }

    // MARK: - Buckets

    /// Side-by-side tap targets mirroring the table: row headers on the
    /// left, cells on the right. Placed pills stack in a column inside each.
    private var buckets: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            bucket(
                title: String(localized: "Row headers"),
                systemImage: "list.bullet",
                fields: viewModel.layout.rows,
                zone: .rows
            )
            bucket(
                title: String(localized: "Cells"),
                systemImage: "tablecells",
                fields: viewModel.layout.cells,
                zone: .cells
            )
        }
    }

    private func bucket(
        title: String,
        systemImage: String,
        fields: [ExportField],
        zone: ExportSandboxViewModel.Zone
    ) -> some View {
        let active = viewModel.canPlaceSelected(in: zone)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
            if fields.isEmpty || active {
                Text(active ? "Tap to place here" : "Tap a pill below, then tap here")
                    .font(.caption2)
                    .foregroundStyle(active ? Color.accentColor : Color(.tertiaryLabel))
            }
            ForEach(fields) { field in
                pill(for: field)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SurfaceRadius.small, style: .continuous)
                .fill(active
                    ? Color.accentColor.opacity(0.12)
                    : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SurfaceRadius.small, style: .continuous)
                .strokeBorder(
                    active ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: [5, 4])
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { viewModel.placeSelected(in: zone) }
        .accessibilityAddTraits(active ? .isButton : [])
        .accessibilityHint(active ? Text("Places the selected pill here") : Text(""))
        .animation(.easeInOut(duration: 0.15), value: active)
    }

    // MARK: - Trays

    private var fieldTray: some View {
        let active = viewModel.canPlaceSelected(in: .tray)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(active ? "Fields — tap to return here" : "Fields")
                .font(.caption)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
            if viewModel.trayFields.isEmpty && !active {
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
        // Tapping the tray returns the selected placed pill.
        .onTapGesture { viewModel.placeSelected(in: .tray) }
        .animation(.easeInOut(duration: 0.15), value: active)
    }

    private var roleTray: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Role sections")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Tap a role to split the export into one table per role, top to bottom. Tap a placed role to remove it.")
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

    /// Unplaced role pills: one tap places the role as a section.
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
                .accessibilityLabel(Text(role.name))
                .accessibilityHint(Text("Adds a section for this role"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Placed role sections in export order, top to bottom. Tap a pill to
    /// remove it; order is the order roles were added.
    private var roleOrderZone: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(String(localized: "Export order"), systemImage: "arrow.up.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
            if viewModel.layout.sections.isEmpty {
                Text("Tap a role to add it")
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
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SurfaceRadius.small, style: .continuous)
                .strokeBorder(
                    Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
    }

    private func placedRolePill(_ section: ExportRoleSection, index: Int) -> some View {
        let count = viewModel.layout.sections.count
        return Button {
            viewModel.removeSection(id: section.id)
        } label: {
            ExportPillView(
                label: "\(index + 1). \(section.name)",
                systemImage: "person.text.rectangle",
                tint: .purple
            )
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("\(section.name), position \(index + 1) of \(count)"))
        .accessibilityHint(Text("Removes this role section"))
    }

    // MARK: - Pieces

    /// A field pill: tap to select, then tap a bucket to place it.
    private func pill(for field: ExportField) -> some View {
        Button {
            viewModel.toggleSelection(field)
        } label: {
            ExportPillView(
                label: field.label,
                systemImage: field.systemImage,
                selected: viewModel.selectedField == field
            )
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(field.label))
        .accessibilityHint(Text(viewModel.selectedField == field
            ? "Selected. Tap a destination to place it."
            : "Selects this field"))
    }

    private func flowRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) { content() }
        }
    }
}
