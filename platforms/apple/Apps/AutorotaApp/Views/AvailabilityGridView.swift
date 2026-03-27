import SwiftUI
import AutorotaKit

/// A 7-column × 24-row grid showing availability state per weekday/hour.
/// When `isEditable` is true, tapping a cell cycles through No → Maybe → Yes.
/// Supports rectangle drag-selection for bulk toggling.
struct AvailabilityGridView: View {

    let slots: [AvailabilitySlot]
    let isEditable: Bool
    var visibleHourStart: Int = 6
    var visibleHourEnd: Int = 22
    var showRangePicker: Bool = false
    /// When set, only show columns for the specified weekday(s). Pass a single weekday to render a single-day column.
    var limitToWeekdays: [String]? = nil
    var onChange: (([AvailabilitySlot]) -> Void)?
    var onVisibleRangeChange: ((Int, Int) -> Void)?
    var onSelectionModeChange: ((Bool) -> Void)?
    var onReset: (() -> Void)?

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private var displayedWeekdays: [String] {
        guard let limit = limitToWeekdays else { return Self.weekdays }
        return Self.weekdays.filter { limit.contains($0) }
    }
    private static let allHours = Array(0...23)
    private static let hourLabelWidth: CGFloat = 30
    private static let spacing: CGFloat = 2
    private static let rowHeight: CGFloat = 18
    private static let headerHeight: CGFloat = 16

    // Selection state
    @State private var isSelectionModeActive = false
    @State private var dragAnchorCell: (col: Int, row: Int)?
    @State private var dragCurrentCell: (col: Int, row: Int)?

    // Build a lookup for fast access
    private var lookup: [String: String] {
        Dictionary(slots.map { ("\($0.weekday):\($0.hour)", $0.state) }, uniquingKeysWith: { a, _ in a })
    }

    /// Hours actually rendered: all 24 when editing (out-of-range are dimmed), only the visible range when read-only.
    private var displayedHours: [Int] {
        showRangePicker ? Self.allHours : Array(visibleHourStart...max(visibleHourStart, visibleHourEnd))
    }

    private var selectionRect: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int)? {
        guard let anchor = dragAnchorCell, let current = dragCurrentCell else { return nil }
        return (
            min(anchor.col, current.col),
            max(anchor.col, current.col),
            min(anchor.row, current.row),
            max(anchor.row, current.row)
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            if isEditable {
                toolbarRow
            }

            GeometryReader { geometry in
                let cellWidth = cellWidth(for: geometry.size.width)
                ZStack(alignment: .topLeading) {
                    // The grid itself
                    gridContent(cellWidth: cellWidth)

                    // Selection highlight overlay
                    if isSelectionModeActive, let rect = selectionRect {
                        selectionHighlight(rect: rect, cellWidth: cellWidth)
                            .allowsHitTesting(false)
                    }

                    // Gesture capture layer (only in selection mode)
                    if isSelectionModeActive {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 3, coordinateSpace: .named("availGrid"))
                                    .onChanged { value in
                                        if dragAnchorCell == nil {
                                            dragAnchorCell = cellAt(point: value.startLocation, cellWidth: cellWidth)
                                        }
                                        dragCurrentCell = cellAt(point: value.location, cellWidth: cellWidth)
                                    }
                                    .onEnded { _ in
                                        // Selection stays — user taps inside to toggle or outside to clear
                                    }
                            )
                            .onTapGesture { location in
                                handleTapInSelectionMode(at: location, cellWidth: cellWidth)
                            }
                    }
                }
                .coordinateSpace(name: "availGrid")
            }
            .frame(height: gridHeight)
        }
    }

    // MARK: - Grid content

    private func gridContent(cellWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            // Header row
            HStack(spacing: Self.spacing) {
                Text("").frame(width: Self.hourLabelWidth)
                ForEach(displayedWeekdays, id: \.self) { day in
                    Text(day)
                        .font(.caption2.bold())
                        .frame(width: cellWidth)
                        .multilineTextAlignment(.center)
                }
            }

            // Hour rows
            ForEach(displayedHours, id: \.self) { hour in
                let inRange = hour >= visibleHourStart && hour <= visibleHourEnd
                HStack(spacing: Self.spacing) {
                    Text(String(format: "%02d", hour))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.hourLabelWidth, alignment: .trailing)

                    ForEach(displayedWeekdays, id: \.self) { day in
                        let key = "\(day):\(hour)"
                        let state = inRange ? (lookup[key] ?? "Maybe") : "No"
                        CellView(
                            state: state,
                            isEditable: isEditable && inRange && !isSelectionModeActive,
                            isDimmed: !inRange,
                            cellWidth: cellWidth
                        ) {
                            if isEditable && inRange && !isSelectionModeActive {
                                toggle(weekday: day, hour: hour)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Toolbar with selection toggle and range picker

    private var toolbarRow: some View {
        HStack {
            if let onReset {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            if showRangePicker {
                rangePickerContent
            }
            Spacer()
            Button {
                isSelectionModeActive.toggle()
                if !isSelectionModeActive {
                    dragAnchorCell = nil
                    dragCurrentCell = nil
                }
                onSelectionModeChange?(isSelectionModeActive)
            } label: {
                Image(systemName: "rectangle.dashed")
                    .foregroundStyle(isSelectionModeActive ? .white : .secondary)
                    .padding(6)
                    .background(isSelectionModeActive ? Color.blue : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.borderless)
        }
    }

    private var rangePickerContent: some View {
        HStack(spacing: 4) {
            Text("Hours:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("From", selection: Binding(
                get: { visibleHourStart },
                set: { onVisibleRangeChange?($0, visibleHourEnd) }
            )) {
                ForEach(0...23, id: \.self) { h in
                    Text(String(format: "%02d", h)).tag(h)
                }
            }
            .labelsHidden()

            Text("-")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("To", selection: Binding(
                get: { visibleHourEnd },
                set: { onVisibleRangeChange?(visibleHourStart, $0) }
            )) {
                ForEach(0...23, id: \.self) { h in
                    Text(String(format: "%02d", h)).tag(h)
                }
            }
            .labelsHidden()
        }
    }

    // MARK: - Selection highlight

    private func selectionHighlight(
        rect: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int),
        cellWidth: CGFloat
    ) -> some View {
        let verticalPadding: CGFloat = 4
        let x = Self.hourLabelWidth + Self.spacing + CGFloat(rect.minCol) * (cellWidth + Self.spacing)
        let y = verticalPadding + Self.headerHeight + Self.spacing + CGFloat(rect.minRow) * (Self.rowHeight + Self.spacing)
        let w = CGFloat(rect.maxCol - rect.minCol + 1) * (cellWidth + Self.spacing) - Self.spacing
        let h = CGFloat(rect.maxRow - rect.minRow + 1) * (Self.rowHeight + Self.spacing) - Self.spacing

        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.blue.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.blue.opacity(0.4), lineWidth: 1.5)
            )
            .frame(width: w, height: h)
            .position(x: x + w / 2, y: y + h / 2)
    }

    // MARK: - Coordinate mapping

    private func cellAt(point: CGPoint, cellWidth: CGFloat) -> (col: Int, row: Int)? {
        let verticalPadding: CGFloat = 4
        let adjustedX = point.x - Self.hourLabelWidth - Self.spacing
        let adjustedY = point.y - verticalPadding - Self.headerHeight - Self.spacing

        let col = Int(adjustedX / (cellWidth + Self.spacing))
        let row = Int(adjustedY / (Self.rowHeight + Self.spacing))

        let clampedCol = max(0, min(displayedWeekdays.count - 1, col))
        let clampedRow = max(0, min(displayedHours.count - 1, row))
        return (clampedCol, clampedRow)
    }

    // MARK: - Selection tap handling

    private func handleTapInSelectionMode(at location: CGPoint, cellWidth: CGFloat) {
        guard let tapped = cellAt(point: location, cellWidth: cellWidth),
              let rect = selectionRect else {
            // No selection — start fresh or ignore
            return
        }

        if tapped.col >= rect.minCol && tapped.col <= rect.maxCol &&
           tapped.row >= rect.minRow && tapped.row <= rect.maxRow {
            toggleSelectedCells(rect: rect)
        } else {
            // Tap outside — clear selection
            dragAnchorCell = nil
            dragCurrentCell = nil
        }
    }

    private func toggleSelectedCells(rect: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int)) {
        var stateCounts: [String: Int] = ["Yes": 0, "Maybe": 0, "No": 0]
        var cellKeys: [(weekday: String, hour: Int)] = []

        for rowIdx in rect.minRow...rect.maxRow {
            guard rowIdx < displayedHours.count else { continue }
            let hour = displayedHours[rowIdx]
            guard hour >= visibleHourStart && hour <= visibleHourEnd else { continue }
            for col in rect.minCol...rect.maxCol {
                let day = displayedWeekdays[col]
                let key = "\(day):\(hour)"
                let state = lookup[key] ?? "Maybe"
                stateCounts[state, default: 0] += 1
                cellKeys.append((day, hour))
            }
        }

        let majorityState = stateCounts.max(by: { $0.value < $1.value })?.key ?? "Maybe"
        let nextState = cycled(majorityState)

        var updated = slots
        for (day, hour) in cellKeys {
            if let idx = updated.firstIndex(where: { $0.weekday == day && $0.hour == UInt8(hour) }) {
                if nextState == "Maybe" {
                    updated.remove(at: idx)
                } else {
                    updated[idx] = AvailabilitySlot(weekday: day, hour: UInt8(hour), state: nextState)
                }
            } else if nextState != "Maybe" {
                updated.append(AvailabilitySlot(weekday: day, hour: UInt8(hour), state: nextState))
            }
        }
        onChange?(updated)
    }

    // MARK: - Single cell toggle

    private func toggle(weekday: String, hour: Int) {
        var updated = slots
        if let idx = updated.firstIndex(where: { $0.weekday == weekday && $0.hour == UInt8(hour) }) {
            let next = cycled(updated[idx].state)
            if next == "Maybe" {
                updated.remove(at: idx)
            } else {
                updated[idx] = AvailabilitySlot(weekday: weekday, hour: UInt8(hour), state: next)
            }
        } else {
            updated.append(AvailabilitySlot(weekday: weekday, hour: UInt8(hour), state: "Yes"))
        }
        onChange?(updated)
    }

    private func cycled(_ state: String) -> String {
        switch state {
        case "Yes":   return "No"
        case "No":    return "Maybe"
        default:      return "Yes"
        }
    }

    private var gridHeight: CGFloat {
        let rows = CGFloat(displayedHours.count)
        return Self.headerHeight + Self.spacing + rows * (Self.rowHeight + Self.spacing)
    }

    private func cellWidth(for totalWidth: CGFloat) -> CGFloat {
        let count = CGFloat(displayedWeekdays.count)
        let totalSpacing = Self.spacing * count
        let available = totalWidth - Self.hourLabelWidth - totalSpacing
        return max(20, available / count)
    }

    // MARK: - Static helpers

    /// Infers the visible hour range from saved slots.
    static func inferredVisibleRange(from slots: [AvailabilitySlot]) -> (start: Int, end: Int) {
        func isAllExplicitNo(hour: Int) -> Bool {
            weekdays.allSatisfy { day in
                slots.contains { $0.weekday == day && $0.hour == UInt8(hour) && $0.state == "No" }
            }
        }
        let start = (0...23).first(where: { !isAllExplicitNo(hour: $0) }) ?? 0
        let end   = (0...23).last(where:  { !isAllExplicitNo(hour: $0) }) ?? 23
        return (start, end)
    }

    /// Sets all hours outside the visible range to "No", removing any Maybe/Yes entries for those hours.
    static func slotsWithOutOfRangeSetToNo(slots: [AvailabilitySlot], start: Int, end: Int) -> [AvailabilitySlot] {
        var result = slots.filter { Int($0.hour) >= start && Int($0.hour) <= end }
        for hour in 0...23 where hour < start || hour > end {
            for day in weekdays {
                result.append(AvailabilitySlot(weekday: day, hour: UInt8(hour), state: "No"))
            }
        }
        return result
    }
}

private struct CellView: View {
    let state: String
    let isEditable: Bool
    let isDimmed: Bool
    let cellWidth: CGFloat
    let onTap: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color(for: state))
            .frame(width: cellWidth, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .opacity(isDimmed ? 0.3 : 1.0)
            .onTapGesture { if isEditable { onTap() } }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "Yes":   return .green.opacity(0.75)
        case "No":    return .red.opacity(0.55)
        default:      return .yellow.opacity(0.45)
        }
    }
}
