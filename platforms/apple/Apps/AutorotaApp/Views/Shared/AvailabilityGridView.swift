import SwiftUI
import AutorotaKit

/// A 7-column × 24-row grid showing availability state per weekday/hour.
/// When `isEditable` is true, tapping a cell cycles through No → Maybe → Yes.
/// Multi-select: the toolbar's lasso toggle turns drags into a rectangle
/// selection (callers pause scrolling via `onLassoModeChange` while it's
/// on); on release the selection persists — tap inside to bulk-cycle, tap
/// outside to clear. A hold-then-drag activation shipped briefly but was
/// shelved for fighting page scrolling — see
/// docs/availability-hold-drag-lasso.md before re-adding it.
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
    /// Called when the sticky lasso toggle flips, so enclosing scroll views
    /// can disable scrolling while plain drags are drawing selections.
    var onLassoModeChange: ((Bool) -> Void)?
    var onReset: (() -> Void)?
    /// Weekdays whose columns should be outlined (e.g. days with an override on the current week).
    var outlinedWeekdays: Set<String> = []
    /// Color used for the outline around `outlinedWeekdays` columns.
    var columnOutlineColor: Color = .orange
    /// Weekdays whose cells are rendered read-only even when `isEditable` is true (e.g. past dates).
    var readOnlyWeekdays: Set<String> = []
    /// Optional per-weekday header labels (e.g. date strings "20"). Rendered beneath the day name.
    var weekdaySubheaders: [String: String] = [:]

    private static let weekdays = AvailabilityWeekMath.weekdayOrder
    private static let subheaderHeight: CGFloat = 12

    /// Header row height including the optional subheader (date number).
    private var effectiveHeaderHeight: CGFloat {
        weekdaySubheaders.isEmpty ? Self.headerHeight : Self.headerHeight + Self.subheaderHeight
    }

    private var displayedWeekdays: [String] {
        guard let limit = limitToWeekdays else { return Self.weekdays }
        return Self.weekdays.filter { limit.contains($0) }
    }
    private static let allHours = Array(0...23)
    private static let hourLabelWidth: CGFloat = 30
    private static let spacing: CGFloat = 2
    private static let rowHeight: CGFloat = 18
    private static let headerHeight: CGFloat = 16

    // Selection state. Flipping the sticky lasso toggle in the toolbar
    // makes drags draw a selection; it persists until the user taps
    // inside (apply) or outside (clear).
    @State private var lassoToggleActive = false
    @State private var dragAnchorCell: (col: Int, row: Int)?
    @State private var dragCurrentCell: (col: Int, row: Int)?
    /// True once a drag has actually moved (new lasso in progress). The
    /// first movement replaces any prior selection.
    @State private var lassoDidDrag = false

    private var hasSelection: Bool { selectionRect != nil }

    // Build a lookup for fast access
    private var lookup: [String: String] {
        Dictionary(slots.map { ("\($0.weekday):\($0.hour)", $0.state) }, uniquingKeysWith: { a, _ in a })
    }

    /// Hours actually rendered: all 24 when editing (out-of-range are dimmed), only the visible range when read-only.
    private var displayedHours: [Int] {
        showRangePicker ? Self.allHours : Self.hoursInRange(start: visibleHourStart, end: visibleHourEnd)
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
                    gridContent(cellWidth: cellWidth)

                    // Selection highlight overlay
                    if let rect = selectionRect {
                        selectionHighlight(rect: rect, cellWidth: cellWidth)
                            .allowsHitTesting(false)
                    }

                    // Unified touch layer: tap cycles a cell (or applies /
                    // clears an active selection). With the sticky lasso
                    // toggle on, drags select (the container disables
                    // scrolling via onLassoModeChange); with it off, drags
                    // pass through to the enclosing scroll view.
                    if isEditable {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                handleTap(at: location, cellWidth: cellWidth)
                            }
                            .gesture(plainLassoDrag(cellWidth: cellWidth), isEnabled: lassoToggleActive)
                    }
                }
                .coordinateSpace(name: "availGrid")
            }
            .frame(height: gridHeight)
        }
    }

    // MARK: - Lasso gesture

    // A hold-then-drag activation (no toggle needed) shipped briefly and
    // was shelved for interfering with page scrolling; its full
    // implementation is preserved in docs/availability-hold-drag-lasso.md.

    /// Drag lasso while the sticky toggle is on.
    private func plainLassoDrag(cellWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("availGrid"))
            .onChanged { value in
                if !lassoDidDrag {
                    lassoDidDrag = true
                    dragAnchorCell = cellAt(point: value.startLocation, cellWidth: cellWidth)
                }
                dragCurrentCell = cellAt(point: value.location, cellWidth: cellWidth)
            }
            .onEnded { _ in
                if lassoDidDrag, hasSelection {
                    NotificationCenter.default.post(name: .autorotaTutorialAction, object: TutorialAction.lassoDrawn)
                }
                lassoDidDrag = false
            }
    }

    // MARK: - Grid content

    private func gridContent(cellWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                // Header row
                HStack(spacing: Self.spacing) {
                    Text("").frame(width: Self.hourLabelWidth)
                    ForEach(displayedWeekdays, id: \.self) { day in
                        VStack(spacing: 0) {
                            Text(day)
                                .font(.caption2.bold())
                            if let sub = weekdaySubheaders[day] {
                                Text(sub)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: cellWidth, height: effectiveHeaderHeight)
                        .multilineTextAlignment(.center)
                    }
                }
                .frame(height: effectiveHeaderHeight)

                // Hour rows
                ForEach(displayedHours, id: \.self) { hour in
                    let inRange = Self.hourIsInRange(hour, start: visibleHourStart, end: visibleHourEnd)
                    HStack(spacing: Self.spacing) {
                        Text(String(format: "%02d", hour))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.hourLabelWidth, alignment: .trailing)

                        ForEach(displayedWeekdays, id: \.self) { day in
                            let key = "\(day):\(hour)"
                            let state = inRange ? (lookup[key] ?? "Maybe") : "No"
                            let dayReadOnly = readOnlyWeekdays.contains(day)
                            CellView(
                                state: state,
                                isEditable: isEditable && inRange && !dayReadOnly,
                                isDimmed: !inRange || dayReadOnly,
                                cellWidth: cellWidth,
                                weekday: day,
                                hour: hour
                            ) {
                                if isEditable && inRange && !dayReadOnly {
                                    toggle(weekday: day, hour: hour)
                                }
                            }
                            .accessibilityIdentifier("rota.gridCell.\(day).\(hour)")
                        }
                    }
                }
            }
            .padding(.vertical, 4)

            // Column outlines overlay
            if !outlinedWeekdays.isEmpty {
                columnOutlineOverlay(cellWidth: cellWidth)
                    .allowsHitTesting(false)
            }
        }
    }

    private func columnOutlineOverlay(cellWidth: CGFloat) -> some View {
        let verticalPadding: CGFloat = 4
        let rows = CGFloat(displayedHours.count)
        let totalHeight = effectiveHeaderHeight + Self.spacing + rows * (Self.rowHeight + Self.spacing) - Self.spacing
        return ZStack(alignment: .topLeading) {
            ForEach(Array(displayedWeekdays.enumerated()), id: \.offset) { idx, day in
                if outlinedWeekdays.contains(day) {
                    let x = Self.hourLabelWidth + Self.spacing + CGFloat(idx) * (cellWidth + Self.spacing)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(columnOutlineColor, lineWidth: 1.5)
                        .frame(width: cellWidth + 4, height: totalHeight + 4)
                        .position(x: x + cellWidth / 2, y: verticalPadding + totalHeight / 2)
                }
            }
        }
    }

    // MARK: - Toolbar with reset and range picker

    private var toolbarRow: some View {
        HStack {
            lassoToggleButton
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
        }
    }

    /// Sticky lasso mode: while on, plain drags draw selections and the
    /// enclosing scroll view is disabled (via `onLassoModeChange`).
    private var lassoToggleButton: some View {
        Button {
            lassoToggleActive.toggle()
            onLassoModeChange?(lassoToggleActive)
            NotificationCenter.default.post(
                name: .autorotaTutorialAction,
                object: lassoToggleActive ? TutorialAction.lassoToggledOn : TutorialAction.lassoToggledOff
            )
        } label: {
            Image(systemName: "lasso")
                .foregroundStyle(lassoToggleActive ? Color.white : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    lassoToggleActive ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Lasso selection")
        .accessibilityValue(lassoToggleActive ? "On" : "Off")
        .accessibilityIdentifier("availability.lassoToggle")
        .tutorialTarget(.lassoToggle)
    }

    private var rangePickerContent: some View {
        HStack(spacing: 4) {
            Text("Hours:")
                .font(.caption)
                .foregroundStyle(.secondary)
            hourMenu(value: visibleHourStart, accessibilityLabel: "Visible hours from") {
                onVisibleRangeChange?($0, visibleHourEnd)
            }

            Text("-")
                .font(.caption)
                .foregroundStyle(.secondary)

            hourMenu(value: visibleHourEnd, accessibilityLabel: "Visible hours to") {
                onVisibleRangeChange?(visibleHourStart, $0)
            }
        }
    }

    /// `Picker` taps get swallowed when nested in a Form row alongside other
    /// interactive views; an explicit `Menu` with borderless style reliably opens.
    private func hourMenu(value: Int, accessibilityLabel: String, onPick: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(0...23, id: \.self) { h in
                Button {
                    onPick(h)
                } label: {
                    if h == value {
                        Label(String(format: "%02d", h), systemImage: "checkmark")
                    } else {
                        Text(String(format: "%02d", h))
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(String(format: "%02d", value))
                    .font(.callout.monospacedDigit())
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Selection highlight

    private func selectionHighlight(
        rect: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int),
        cellWidth: CGFloat
    ) -> some View {
        let verticalPadding: CGFloat = 4
        let x = Self.hourLabelWidth + Self.spacing + CGFloat(rect.minCol) * (cellWidth + Self.spacing)
        let y = verticalPadding + effectiveHeaderHeight + Self.spacing + CGFloat(rect.minRow) * (Self.rowHeight + Self.spacing)
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

    /// Nearest cell, clamped into the grid. Used while dragging so a lasso
    /// that wanders past the edge still tracks the boundary cell.
    private func cellAt(point: CGPoint, cellWidth: CGFloat) -> (col: Int, row: Int)? {
        let (col, row) = rawCell(at: point, cellWidth: cellWidth)
        let clampedCol = max(0, min(displayedWeekdays.count - 1, col))
        let clampedRow = max(0, min(displayedHours.count - 1, row))
        return (clampedCol, clampedRow)
    }

    /// The cell actually under `point`, or nil when the point falls on the
    /// header row / hour-label column / outside the grid. Used for taps so a
    /// header tap can't cycle a boundary cell.
    private func strictCellAt(point: CGPoint, cellWidth: CGFloat) -> (col: Int, row: Int)? {
        let (col, row) = rawCell(at: point, cellWidth: cellWidth)
        guard (0..<displayedWeekdays.count).contains(col),
              (0..<displayedHours.count).contains(row) else { return nil }
        return (col, row)
    }

    private func rawCell(at point: CGPoint, cellWidth: CGFloat) -> (col: Int, row: Int) {
        let verticalPadding: CGFloat = 4
        let adjustedX = point.x - Self.hourLabelWidth - Self.spacing
        let adjustedY = point.y - verticalPadding - effectiveHeaderHeight - Self.spacing
        // floor() so slightly-negative offsets (header / label gutter) map to
        // -1 and fail the strict bounds check instead of truncating to 0.
        let col = Int(floor(adjustedX / (cellWidth + Self.spacing)))
        let row = Int(floor(adjustedY / (Self.rowHeight + Self.spacing)))
        return (col, row)
    }

    // MARK: - Tap handling

    /// Single entry point for taps on the touch layer: with an active
    /// selection, a tap inside applies the majority cycle and a tap outside
    /// clears it; with no selection, a tap cycles the cell under the finger.
    private func handleTap(at location: CGPoint, cellWidth: CGFloat) {
        let tapped = strictCellAt(point: location, cellWidth: cellWidth)

        if let rect = selectionRect {
            if let tapped,
               tapped.col >= rect.minCol && tapped.col <= rect.maxCol &&
               tapped.row >= rect.minRow && tapped.row <= rect.maxRow {
                toggleSelectedCells(rect: rect)
            } else {
                dragAnchorCell = nil
                dragCurrentCell = nil
            }
            return
        }

        guard let tapped else { return }
        let day = displayedWeekdays[tapped.col]
        let hour = displayedHours[tapped.row]
        guard Self.hourIsInRange(hour, start: visibleHourStart, end: visibleHourEnd),
              !readOnlyWeekdays.contains(day) else { return }
        toggle(weekday: day, hour: hour)
    }

    private func toggleSelectedCells(rect: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int)) {
        var stateCounts: [String: Int] = ["Yes": 0, "Maybe": 0, "No": 0]
        var cellKeys: [(weekday: String, hour: Int)] = []

        for rowIdx in rect.minRow...rect.maxRow {
            guard rowIdx < displayedHours.count else { continue }
            let hour = displayedHours[rowIdx]
            guard Self.hourIsInRange(hour, start: visibleHourStart, end: visibleHourEnd) else { continue }
            for col in rect.minCol...rect.maxCol {
                let day = displayedWeekdays[col]
                guard !readOnlyWeekdays.contains(day) else { continue }
                let key = "\(day):\(hour)"
                let state = lookup[key] ?? "Maybe"
                stateCounts[state, default: 0] += 1
                cellKeys.append((day, hour))
            }
        }

        let majorityState = stateCounts.max(by: { $0.value < $1.value })?.key ?? "Maybe"
        let nextState = cycled(majorityState)
        NotificationCenter.default.post(name: .autorotaTutorialAction, object: TutorialAction.lassoApplied)

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
        NotificationCenter.default.post(name: .autorotaTutorialAction, object: TutorialAction.cellCycled)
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
        return effectiveHeaderHeight + Self.spacing + rows * (Self.rowHeight + Self.spacing)
    }

    private func cellWidth(for totalWidth: CGFloat) -> CGFloat {
        let count = CGFloat(displayedWeekdays.count)
        let totalSpacing = Self.spacing * count
        let available = totalWidth - Self.hourLabelWidth - totalSpacing
        return max(20, available / count)
    }

    // MARK: - Static helpers

    /// True when `hour` falls inside the visible range. Ranges where start > end wrap past midnight (e.g. 18–02).
    static func hourIsInRange(_ hour: Int, start: Int, end: Int) -> Bool {
        start <= end ? (hour >= start && hour <= end) : (hour >= start || hour <= end)
    }

    /// Hours of the visible range in display order, wrapping past midnight when start > end.
    static func hoursInRange(start: Int, end: Int) -> [Int] {
        start <= end ? Array(start...end) : Array(start...23) + Array(0...end)
    }

    /// Infers the visible hour range from saved slots: the complement of the longest
    /// circular run of hours that are explicit "No" across all weekdays, so ranges
    /// that wrap past midnight (e.g. 18–02) round-trip through save and reload.
    static func inferredVisibleRange(from slots: [AvailabilitySlot]) -> (start: Int, end: Int) {
        func isAllExplicitNo(hour: Int) -> Bool {
            weekdays.allSatisfy { day in
                slots.contains { $0.weekday == day && $0.hour == UInt8(hour) && $0.state == "No" }
            }
        }
        let closed = Set((0...23).filter(isAllExplicitNo))
        guard !closed.isEmpty, closed.count < 24 else { return (0, 23) }

        var bestStart = 0, bestLen = 0
        for hour in closed where !closed.contains((hour + 23) % 24) {
            var len = 0
            var cursor = hour
            while closed.contains(cursor) {
                len += 1
                cursor = (cursor + 1) % 24
            }
            if len > bestLen {
                bestLen = len
                bestStart = hour
            }
        }
        return ((bestStart + bestLen) % 24, (bestStart + 23) % 24)
    }

    /// Sets all hours outside the visible range to "No", removing any Maybe/Yes entries for those hours.
    static func slotsWithOutOfRangeSetToNo(slots: [AvailabilitySlot], start: Int, end: Int) -> [AvailabilitySlot] {
        var result = slots.filter { hourIsInRange(Int($0.hour), start: start, end: end) }
        for hour in 0...23 where !hourIsInRange(hour, start: start, end: end) {
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
    let weekday: String
    let hour: Int
    let onTap: () -> Void
    @Environment(\.accessibilityPalette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color(for: state))
            .frame(width: cellWidth, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .opacity(isDimmed ? 0.3 : 1.0)
            .onTapGesture {
                guard isEditable else { return }
                onTap()
            }
            .accessibilityElement()
            .accessibilityLabel("\(weekday) \(String(format: "%02d", hour)):00")
            .accessibilityValue(state)
            .accessibilityHint(isEditable ? "Double-tap to cycle availability" : "")
            .accessibilityAddTraits(isEditable ? .isButton : [])
    }

    private func color(for state: String) -> Color {
        switch state {
        case "Yes":   return palette.yes.opacity(0.75)
        case "No":    return palette.no.opacity(0.55)
        default:      return palette.maybe.opacity(0.45)
        }
    }
}
