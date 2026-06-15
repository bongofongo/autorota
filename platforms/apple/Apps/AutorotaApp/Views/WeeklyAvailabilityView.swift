import SwiftUI
import AutorotaKit

struct WeeklyAvailabilityView: View {

    @State private var vm = EmployeeViewModel()
    @State private var progressVM = AvailabilityProgressViewModel()
    @Environment(\.dismiss) private var dismiss
    /// Tracks whether the current window is landscape (width > height).
    @State private var isLandscape = false

    /// Next Monday's date, used for the header.
    private var nextWeekStart: Date {
        let cal = Calendar.current
        let today = Date()
        let weekday = cal.component(.weekday, from: today)
        // weekday: 1=Sun, 2=Mon, ..., 7=Sat
        let daysUntilMonday = (9 - weekday) % 7
        return cal.date(byAdding: .day, value: daysUntilMonday == 0 ? 7 : daysUntilMonday, to: today)!
    }

    private var weekLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let start = nextWeekStart
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start)!
        return "Week of \(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private var weekStartString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: nextWeekStart)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    /// Grid on macOS always; on iOS only in landscape.
    private var useGridLayout: Bool {
        #if os(macOS)
        return true
        #else
        return isLandscape
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.employees.isEmpty {
                    ProgressView("Loading…")
                } else if vm.employees.isEmpty {
                    ContentUnavailableView("No Employees", systemImage: "person.slash")
                } else if useGridLayout {
                    gridLayout
                } else {
                    CarouselAvailabilityView(
                        employees: vm.employees,
                        vm: vm,
                        progressVM: progressVM,
                        weekLabel: weekLabel,
                        weekStartString: weekStartString
                    )
                }
            }
            .navigationTitle("Weekly Availability")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await vm.reload() }
            .task { await progressVM.load(weekStart: weekStartString) }
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > proxy.size.height
            } action: { newValue in
                isLandscape = newValue
            }
        }
    }

    // MARK: - Grid Layout (iPad/Mac)

    @ViewBuilder
    private var gridLayout: some View {
        if progressVM.allDone(employees: vm.employees) {
            VStack {
                Text(weekLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                AllAvailabilitiesSetView()
            }
        } else {
            ScrollView {
                Text(weekLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(vm.employees, id: \.id) { employee in
                        AvailabilityCard(
                            employee: employee,
                            vm: vm,
                            progressVM: progressVM,
                            weekStartString: weekStartString
                        )
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Card (for grid layout)

private struct AvailabilityCard: View {
    let employee: FfiEmployee
    let vm: EmployeeViewModel
    let progressVM: AvailabilityProgressViewModel
    let weekStartString: String

    @State private var overrideVM = OverrideViewModel()
    @State private var slots: [AvailabilitySlot] = []
    @State private var selectionMode = false
    private let visibleRange: (start: Int, end: Int)

    init(employee: FfiEmployee, vm: EmployeeViewModel, progressVM: AvailabilityProgressViewModel, weekStartString: String) {
        self.employee = employee
        self.vm = vm
        self.progressVM = progressVM
        self.weekStartString = weekStartString
        self.visibleRange = AvailabilityGridView.inferredVisibleRange(from: employee.defaultAvailability)
    }

    private var isDone: Bool { progressVM.isDone(employee.id) }

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(employee.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !employee.roles.isEmpty {
                        Text(employee.roles.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                // Selection mode toggle
                Button {
                    selectionMode.toggle()
                } label: {
                    Image(systemName: "rectangle.dashed")
                        .font(.body)
                        .foregroundStyle(selectionMode ? .white : .secondary)
                        .frame(width: 36, height: 36)
                        .background(selectionMode ? Color.blue : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selectionMode ? "Exit selection mode" : "Enter selection mode")
                // Done checkmark
                Button {
                    Task {
                        if isDone {
                            await progressVM.markUndone(employeeId: employee.id, weekStart: weekStartString)
                        } else {
                            await progressVM.markDone(employeeId: employee.id, weekStart: weekStartString)
                        }
                    }
                } label: {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.title3)
                        .foregroundStyle(isDone ? .green : .secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            AvailabilityGridView(
                slots: slots,
                isEditable: true,
                visibleHourStart: visibleRange.start,
                visibleHourEnd: visibleRange.end,
                onChange: { newSlots in
                    slots = newSlots
                    Task { await persistEdits(newSlots) }
                },
                showSelectionToggle: false,
                externalSelectionMode: $selectionMode,
                outlinedWeekdays: outlinedWeekdays,
                weekdaySubheaders: weekdaySubheaders
            )
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

// MARK: - Date-aware weekly availability helper

/// Shared logic for the mass availability picker: maps a week's ISO Monday
/// into per-date context, merges default availability with stored overrides,
/// and persists grid edits as per-date employee availability overrides
/// (preserving exception classification, tagging fresh rows as "manual").
enum AvailabilityWeekMath {

    static let weekdayOrder = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func weekDays(from weekStartIso: String) -> [(weekday: String, date: Date, iso: String)] {
        guard let monday = isoFmt.date(from: weekStartIso) else { return [] }
        let cal = Calendar(identifier: .iso8601)
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: monday)!
            return (weekdayOrder[i], d, isoFmt.string(from: d))
        }
    }

    static func dayNumber(for date: Date) -> String {
        String(Calendar(identifier: .iso8601).component(.day, from: date))
    }

    static func merge(
        days: [(weekday: String, date: Date, iso: String)],
        overrides: [String: FfiEmployeeAvailabilityOverride],
        defaultAvailability: [AvailabilitySlot]
    ) -> [AvailabilitySlot] {
        var out: [AvailabilitySlot] = []
        for (wd, _, iso) in days {
            if let ovr = overrides[iso] {
                for s in ovr.availability {
                    out.append(AvailabilitySlot(weekday: wd, hour: s.hour, state: s.state))
                }
            } else {
                for s in defaultAvailability where s.weekday == wd {
                    out.append(s)
                }
            }
        }
        return out
    }

    static func persistWeekEdits(
        newSlots: [AvailabilitySlot],
        days: [(weekday: String, date: Date, iso: String)],
        overrideByIso: [String: FfiEmployeeAvailabilityOverride],
        defaultAvailability: [AvailabilitySlot],
        employeeId: Int64,
        overrideVM: OverrideViewModel
    ) async {
        for (wd, _, iso) in days {
            let newDay = newSlots
                .filter { $0.weekday == wd }
                .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
                .sorted { $0.hour < $1.hour }
            let defaultDay = defaultAvailability
                .filter { $0.weekday == wd }
                .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
                .sorted { $0.hour < $1.hour }
            let existing = overrideByIso[iso]

            if newDay == defaultDay {
                // Matches default template. Silently delete stale *manual*
                // overrides, but leave explicit exceptions alone — users
                // classify those via the Exceptions UI.
                if let ex = existing, ex.source != "exception" {
                    await overrideVM.deleteEmployeeOverride(id: ex.id)
                }
                continue
            }

            let currentStored = existing?.availability.sorted { $0.hour < $1.hour } ?? defaultDay
            if newDay == currentStored { continue }

            let source = existing?.source ?? "manual"
            let ovr = FfiEmployeeAvailabilityOverride(
                id: existing?.id ?? 0,
                employeeId: employeeId,
                date: iso,
                availability: newDay,
                notes: existing?.notes,
                source: source
            )
            await overrideVM.upsertEmployeeOverride(ovr)
        }
    }
}
