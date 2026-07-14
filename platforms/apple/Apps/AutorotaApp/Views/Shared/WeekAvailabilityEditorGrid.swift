import SwiftUI
import AutorotaKit

/// Date-aware week availability editor used by the mass availability picker
/// (grid cards on iPad/Mac, carousel pages on iPhone). Owns the override
/// load/merge/persist cycle for one employee + week; callers supply the
/// surrounding chrome (header, scroll container, done button).
struct WeekAvailabilityEditorGrid: View {
    let employee: FfiEmployee
    let weekStartString: String
    /// Show the hour-range picker and render all 24 rows (carousel style).
    var showRangePicker: Bool = false
    var onLassoModeChange: ((Bool) -> Void)? = nil

    @State private var overrideVM = OverrideViewModel()
    @State private var slots: [AvailabilitySlot] = []
    @State private var visibleRange: (start: Int, end: Int)

    init(
        employee: FfiEmployee,
        weekStartString: String,
        showRangePicker: Bool = false,
        onLassoModeChange: ((Bool) -> Void)? = nil
    ) {
        self.employee = employee
        self.weekStartString = weekStartString
        self.showRangePicker = showRangePicker
        self.onLassoModeChange = onLassoModeChange
        self._visibleRange = State(
            initialValue: AvailabilityGridView.inferredVisibleRange(from: employee.defaultAvailability)
        )
    }

    private var weekDays: [(weekday: String, date: Date, iso: String)] {
        AvailabilityWeekMath.weekDays(from: weekStartString)
    }

    private var overrideByIso: [String: FfiEmployeeAvailabilityOverride] {
        Dictionary(overrideVM.employeeAvailabilityOverrides.map { ($0.date, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    private func mergedSlots() -> [AvailabilitySlot] {
        AvailabilityWeekMath.merge(
            days: weekDays,
            overrides: overrideByIso,
            defaultAvailability: employee.defaultAvailability
        )
    }

    private var outlinedWeekdays: Set<String> {
        Set(weekDays.compactMap { overrideByIso[$0.iso]?.source == "exception" ? $0.weekday : nil })
    }

    private var weekdaySubheaders: [String: String] {
        Dictionary(uniqueKeysWithValues: weekDays.map { ($0.weekday, AvailabilityWeekMath.dayNumber(for: $0.date)) })
    }

    var body: some View {
        AvailabilityGridView(
            slots: slots,
            isEditable: true,
            visibleHourStart: visibleRange.start,
            visibleHourEnd: visibleRange.end,
            showRangePicker: showRangePicker,
            onChange: { newSlots in
                slots = newSlots
                Task { await persistEdits(newSlots) }
            },
            onVisibleRangeChange: showRangePicker
                ? { start, end in visibleRange = (start, end) }
                : nil,
            onLassoModeChange: onLassoModeChange,
            outlinedWeekdays: outlinedWeekdays,
            weekdaySubheaders: weekdaySubheaders
        )
        .task {
            await overrideVM.loadForEmployee(id: employee.id)
            slots = mergedSlots()
        }
    }

    private func persistEdits(_ newSlots: [AvailabilitySlot]) async {
        await AvailabilityWeekMath.persistWeekEdits(
            newSlots: newSlots,
            days: weekDays,
            overrideByIso: overrideByIso,
            defaultAvailability: employee.defaultAvailability,
            employeeId: employee.id,
            overrideVM: overrideVM
        )
        await overrideVM.loadForEmployee(id: employee.id)
    }
}
