import SwiftUI
import AutorotaKit

/// Illustrative fixture for the sandbox's live mock table. Mirrors the
/// canonical Rust preview fixture in `crates/autorota-core/src/sample.rs`
/// (Alice/Bob, Morning/Evening shifts) — kept in Swift so the sandbox renders
/// without an FFI round-trip. The Preview PDF button shows the real render.
enum SandboxSampleData {
    struct SampleShift {
        let name: String
        let time: String
        let role: String
        let employee: String
        let cost: String
        /// 0 = Monday … 6 = Sunday
        let day: Int
    }

    static let shifts: [SampleShift] = [
        SampleShift(name: "Morning", time: "07:00–12:00", role: "Barista", employee: "Alice", cost: "$75", day: 0),
        SampleShift(name: "Evening", time: "17:00–22:00", role: "Chef", employee: "Bob", cost: "$90", day: 2),
        SampleShift(name: "Morning", time: "07:00–12:00", role: "Barista", employee: "Bob", cost: "$60", day: 4),
    ]

    static let employees = ["Alice", "Bob"]

    /// Unique (name, time, role) slots in start-time order.
    static let slots: [SampleShift] = [shifts[0], shifts[1]]
}

/// The sandbox's template table: locked Mon–Sun column headers, a row-header
/// area and a cell area that double as tap targets for the selected field
/// pill, rendering live sample data from the current pill placement. Role
/// sections live in the sandbox's export-order box, not here.
struct MockExportTableView: View {
    @Bindable var viewModel: ExportSandboxViewModel

    private let weekdayLetters = ["M", "T", "W", "T", "F", "S", "S"]
    private let rowHeaderWidth: CGFloat = 86
    private let rowHeight: CGFloat = 40
    /// Narrowest a day column may get before trailing days collapse into "⋯".
    private let minCellWidth: CGFloat = 56
    private let ellipsisColumnWidth: CGFloat = 28
    private let columnSpacing: CGFloat = 1

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        table
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { availableWidth = $0 }
    }

    // MARK: - Day column fitting

    /// Day columns never shrink below `minCellWidth`. When all 7 won't fit
    /// (iPhone portrait), the trailing days collapse into one "⋯" column —
    /// the days are redundant for previewing placements.
    private var visibleDayCount: Int {
        guard availableWidth > 0 else { return 7 }
        let cellArea = availableWidth - rowHeaderWidth - columnSpacing
        let fullWidth = 7 * minCellWidth + 6 * columnSpacing
        if cellArea >= fullWidth { return 7 }
        let usable = cellArea - ellipsisColumnWidth - columnSpacing
        let count = Int(usable / (minCellWidth + columnSpacing))
        return min(max(count, 1), 6)
    }

    private var showsEllipsisColumn: Bool { visibleDayCount < 7 }

    // MARK: - Table

    private var table: some View {
        HStack(alignment: .top, spacing: 1) {
            rowHeaderColumn
            cellArea
        }
        .clipShape(RoundedRectangle(cornerRadius: SurfaceRadius.small, style: .continuous))
    }

    /// Left column: corner label + sample row labels. Tap target for the
    /// selected field pill.
    private var rowHeaderColumn: some View {
        VStack(spacing: 1) {
            Text("Rows")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: rowHeaderWidth, height: 26)
                .background(headerFill)

            ForEach(Array(rowLabels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.caption2)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .frame(width: rowHeaderWidth, height: rowHeight)
                    .background(zoneFill(active: viewModel.canPlaceSelected(in: .rows)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.placeSelected(in: .rows) }
    }

    /// Weekday header (locked) + sample cells. Tap target for the selected
    /// field pill.
    private var cellArea: some View {
        VStack(spacing: columnSpacing) {
            HStack(spacing: columnSpacing) {
                ForEach(0..<visibleDayCount, id: \.self) { day in
                    HStack(spacing: 2) {
                        Text(weekdayLetters[day])
                            .font(.caption2)
                            .fontWeight(.semibold)
                        if day == 0 {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(headerFill)
                }
                if showsEllipsisColumn {
                    ellipsisHeader
                }
            }

            ForEach(0..<rowLabels.count, id: \.self) { row in
                HStack(spacing: columnSpacing) {
                    ForEach(0..<visibleDayCount, id: \.self) { day in
                        Text(cellText(row: row, day: day))
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .frame(height: rowHeight)
                            .background(zoneFill(active: viewModel.canPlaceSelected(in: .cells)))
                    }
                    if showsEllipsisColumn {
                        ellipsisCell
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.placeSelected(in: .cells) }
    }

    /// Stand-in column for weekdays that don't fit at `minCellWidth`.
    private var ellipsisHeader: some View {
        Text("⋯")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(width: ellipsisColumnWidth)
            .frame(height: 26)
            .background(headerFill)
            .accessibilityLabel(Text("Remaining weekdays"))
    }

    private var ellipsisCell: some View {
        Text("⋯")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: ellipsisColumnWidth, height: rowHeight)
            .background(zoneFill(active: viewModel.canPlaceSelected(in: .cells)))
            .accessibilityHidden(true)
    }

    private var headerFill: some ShapeStyle {
        Color.secondary.opacity(0.12)
    }

    private func zoneFill(active: Bool) -> some ShapeStyle {
        active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.05)
    }

    // MARK: - Live sample content

    private var rowLabels: [String] {
        let layout = viewModel.layout
        if layout.rows.contains(.employeeName) {
            return SandboxSampleData.employees
        }
        if layout.cells.contains(.employeeName) {
            return SandboxSampleData.slots.map { slot in
                let parts = layout.rows.compactMap { field -> String? in
                    switch field {
                    case .shiftName: return slot.name
                    case .time: return slot.time
                    case .role: return slot.role
                    case .employeeName, .cost: return nil
                    }
                }
                return parts.isEmpty ? "—" : parts.joined(separator: "\n")
            }
        }
        // Employee pill unplaced: placeholder rows until the layout is valid.
        return ["—", "—"]
    }

    private func cellText(row: Int, day: Int) -> String {
        let layout = viewModel.layout

        if layout.rows.contains(.employeeName) {
            guard row < SandboxSampleData.employees.count else { return "" }
            let employee = SandboxSampleData.employees[row]
            let matches = SandboxSampleData.shifts.filter { $0.employee == employee && $0.day == day }
            guard !matches.isEmpty else { return "" }
            return matches.map { shift in
                layout.cells.compactMap { field -> String? in
                    switch field {
                    case .shiftName: return shift.name
                    case .time: return shift.time
                    case .role: return shift.role
                    case .cost: return shift.cost
                    case .employeeName: return nil
                    }
                }.joined(separator: "\n")
            }.joined(separator: "\n")
        }

        if layout.cells.contains(.employeeName) {
            guard row < SandboxSampleData.slots.count else { return "" }
            let slot = SandboxSampleData.slots[row]
            let matches = SandboxSampleData.shifts.filter {
                $0.name == slot.name && $0.time == slot.time && $0.day == day
            }
            let showCost = layout.cells.contains(.cost)
            return matches
                .map { showCost ? "\($0.employee) \($0.cost)" : $0.employee }
                .joined(separator: "\n")
        }

        return ""
    }
}
