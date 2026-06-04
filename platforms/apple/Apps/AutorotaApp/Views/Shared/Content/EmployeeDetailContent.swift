import SwiftUI
import AutorotaKit
import TipKit

enum ContactMethod: String {
    case imessage
    case whatsapp

    var icon: String {
        switch self {
        case .imessage: "message.fill"
        case .whatsapp: "bubble.left.and.bubble.right.fill"
        }
    }

    func url(for phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        switch self {
        case .imessage:
            return URL(string: "sms:\(digits)")
        case .whatsapp:
            let bare = digits.hasPrefix("+") ? String(digits.dropFirst()) : digits
            return URL(string: "https://wa.me/\(bare)")
        }
    }
}

struct EmployeeDetailContent: View {

    let employee: FfiEmployee
    let viewModel: EmployeeViewModel

    @AppStorage("appCurrency") private var displayCurrency: String = AppCurrency.usd.rawValue
    @Environment(ExchangeRateService.self) private var exchangeRates
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditSheet = false
    @State private var overrideVM = OverrideViewModel()
    @State private var shiftVM = ShiftHistoryViewModel()
    @State private var showingAddOverride = false
    @State private var editingOverride: FfiEmployeeAvailabilityOverride? = nil
    @State private var editingOverrideGroup: OverrideGroup? = nil

    @State private var lastWeekExpanded = false
    @State private var thisWeekExpanded = false
    @State private var nextWeekExpanded = false

    @State private var showCustomRange = false
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate: Date = Date()

    @State private var availabilityWeekOffset: Int = 1

    static let weekdayOrder = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let weekRangeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private struct OverrideGroup: Identifiable {
        let items: [FfiEmployeeAvailabilityOverride]
        var id: String { "\(items.first?.date ?? "")-\(items.count)" }
        var isRange: Bool { items.count > 1 }
        var startDate: String { items.first?.date ?? "" }
        var endDate: String { items.last?.date ?? "" }
    }

    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    private var groupedOverrides: [OverrideGroup] {
        // Exceptions list shows only rows classified as exceptions; manual
        // per-date edits share the table but are hidden here.
        let exceptions = overrideVM.employeeAvailabilityOverrides.filter { $0.source == "exception" }
        let sorted = exceptions.sorted { $0.date < $1.date }
        let cal = Calendar(identifier: .iso8601)
        var groups: [OverrideGroup] = []
        var run: [FfiEmployeeAvailabilityOverride] = []
        for ovr in sorted {
            if let last = run.last,
               let lastDate = Self.isoFmt.date(from: last.date),
               let thisDate = Self.isoFmt.date(from: ovr.date),
               let next = cal.date(byAdding: .day, value: 1, to: lastDate),
               cal.isDate(next, inSameDayAs: thisDate) {
                run.append(ovr)
            } else {
                if !run.isEmpty { groups.append(OverrideGroup(items: run)) }
                run = [ovr]
            }
        }
        if !run.isEmpty { groups.append(OverrideGroup(items: run)) }
        return groups
    }

    private func pretty(_ iso: String) -> String {
        guard let d = Self.isoFmt.date(from: iso) else { return iso }
        return Self.displayFmt.string(from: d)
    }

    @ViewBuilder
    private func shiftWeekGroup(
        title: String,
        shifts: [FfiEmployeeShiftRecord],
        isExpanded: Binding<Bool>,
        showTarget: Bool
    ) -> some View {
        let totalHours = shifts.reduce(0) { $0 + $1.durationHours }
        if shifts.isEmpty {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text("No shifts").font(.subheadline).foregroundStyle(.tertiary)
            }
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(shifts, id: \.assignmentId) { record in
                    ShiftRecordRow(
                        record: record,
                        currencySymbol: currencySymbol,
                        convertedCost: convertedCost(record.shiftCost)
                    )
                }
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Text(showTarget
                         ? "\(fmtHours(totalHours)) / \(fmtHours(employee.targetWeeklyHours))"
                         : fmtHours(totalHours))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var previousWeekShifts: [FfiEmployeeShiftRecord] {
        let prevMonday = weekStart(weeksFromNow: -1)
        return shiftVM.pastShifts.filter { $0.weekStart == prevMonday }
    }

    private var nextWeekShifts: [FfiEmployeeShiftRecord] {
        let nextMonday = weekStart(weeksFromNow: 1)
        return shiftVM.plannedShifts.filter { $0.weekStart == nextMonday }
    }

    private var currencySymbol: String {
        exchangeRates.symbol(for: displayCurrency)
    }

    private func convertedCost(_ cost: Float?) -> Float? {
        cost.map { exchangeRates.convert($0, from: employee.wageCurrency ?? displayCurrency, to: displayCurrency) }
    }

    private func mondayOfWeek(offset: Int) -> Date {
        let cal = Calendar(identifier: .iso8601)
        let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        return cal.date(byAdding: .weekOfYear, value: offset, to: monday)!
    }

    private func weekDays(offset: Int) -> [(weekday: String, date: Date, iso: String)] {
        let cal = Calendar(identifier: .iso8601)
        let mon = mondayOfWeek(offset: offset)
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: mon)!
            return (Self.weekdayOrder[i], d, Self.isoFmt.string(from: d))
        }
    }

    private var overrideByDate: [String: FfiEmployeeAvailabilityOverride] {
        Dictionary(overrideVM.employeeAvailabilityOverrides.map { ($0.date, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    private func mergedActualSlots(for days: [(weekday: String, date: Date, iso: String)]) -> [AvailabilitySlot] {
        var slots: [AvailabilitySlot] = []
        for (wd, _, iso) in days {
            if let ovr = overrideByDate[iso] {
                for s in ovr.availability {
                    slots.append(AvailabilitySlot(weekday: wd, hour: s.hour, state: s.state))
                }
            } else {
                for s in employee.defaultAvailability where s.weekday == wd {
                    slots.append(AvailabilitySlot(weekday: wd, hour: s.hour, state: s.state))
                }
            }
        }
        return slots
    }

    private var todayStartOfDay: Date {
        Calendar(identifier: .iso8601).startOfDay(for: Date())
    }

    private func actualWeekLabel(days: [(weekday: String, date: Date, iso: String)]) -> String {
        guard let first = days.first?.date, let last = days.last?.date else { return "" }
        return "\(Self.weekRangeFmt.string(from: first)) – \(Self.weekRangeFmt.string(from: last))"
    }

    @ViewBuilder
    private func overrideGroupRow(_ group: OverrideGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(group.isRange
                     ? "\(pretty(group.startDate)) – \(pretty(group.endDate))"
                     : pretty(group.startDate))
                    .fontWeight(.medium)
                if group.isRange {
                    Text("RANGE · \(group.items.count) days")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
                Spacer()
            }
            if let notes = group.items.first?.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    var body: some View {
        List {
            Section("Details") {
                HStack(alignment: .center, spacing: 6) {
                    Text("Roles").foregroundStyle(.secondary)
                    Spacer()
                    if employee.roles.isEmpty {
                        Text("None").foregroundStyle(.tertiary).font(.subheadline)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(employee.roles, id: \.self) { RoleTag(name: $0) }
                        }
                    }
                }
                LabeledContent("Target hours/week",
                    value: "\(String(format: "%.1f", employee.targetWeeklyHours)) ± \(String(format: "%.1f", employee.weeklyHoursDeviation))h")
                LabeledContent("Max daily hours", value: String(format: "%.1f", employee.maxDailyHours))
                if let wage = employee.hourlyWage {
                    let from = employee.wageCurrency ?? displayCurrency
                    let converted = exchangeRates.convert(wage, from: from, to: displayCurrency)
                    let sym = exchangeRates.symbol(for: displayCurrency)
                    LabeledContent("Hourly wage", value: String(format: "%@%.2f", sym, converted))
                }
                if let phone = employee.phone, !phone.isEmpty {
                    let method = ContactMethod(rawValue: employee.preferredContact ?? "")
                    let detected = PhoneCountry.detect(from: phone)
                    let effective: PhoneCountry = detected == .other
                        ? PhoneCountry(regionCode: Locale.current.region?.identifier ?? "")
                        : detected
                    let displayFormatter = PhoneNumberFormatter(country: effective)
                    let e164 = displayFormatter.normalizeForStorage(phone)
                    let prettyPhone = displayFormatter.format(e164)
                    HStack {
                        Text("Phone").foregroundStyle(.secondary)
                        Spacer()
                        Text(prettyPhone)
                        if let method, let url = method.url(for: phone) {
                            Button {
                                appOpenURL(url)
                            } label: {
                                Image(systemName: method.icon)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if let email = employee.email, !email.isEmpty {
                    HStack {
                        Text("Email").foregroundStyle(.secondary)
                        Spacer()
                        Text(email)
                        if let url = URL(string: "mailto:\(email)") {
                            Button {
                                appOpenURL(url)
                            } label: {
                                Image(systemName: "envelope.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Shifts") {
                if shiftVM.isLoading {
                    ProgressView()
                } else {
                    let prevShifts = previousWeekShifts
                    let currShifts = shiftVM.currentWeekShifts
                    let nextShifts = nextWeekShifts

                    shiftWeekGroup(
                        title: "Last week",
                        shifts: prevShifts,
                        isExpanded: $lastWeekExpanded,
                        showTarget: false
                    )
                    shiftWeekGroup(
                        title: "This week",
                        shifts: currShifts,
                        isExpanded: $thisWeekExpanded,
                        showTarget: true
                    )
                    shiftWeekGroup(
                        title: "Next week",
                        shifts: nextShifts,
                        isExpanded: $nextWeekExpanded,
                        showTarget: false
                    )

                    Button {
                        withAnimation { showCustomRange.toggle() }
                    } label: {
                        HStack {
                            Label("Custom Range", systemImage: "calendar")
                            Spacer()
                            Image(systemName: showCustomRange ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if showCustomRange {
                        DatePicker("From", selection: $customStartDate, displayedComponents: .date)
                        DatePicker("To", selection: $customEndDate, displayedComponents: .date)

                        let startStr = Self.isoFmt.string(from: customStartDate)
                        let endStr = Self.isoFmt.string(from: customEndDate)
                        let filtered = shiftVM.shifts(from: startStr, to: endStr)

                        if filtered.isEmpty {
                            Text("No shifts in this range")
                                .foregroundStyle(.tertiary)
                                .font(.subheadline)
                        } else {
                            let grouped = Dictionary(grouping: filtered, by: \.weekStart)
                                .sorted { $0.key < $1.key }
                            let totalHours = filtered.reduce(0) { $0 + $1.durationHours }
                            let totalCost = filtered.reduce(0) { $0 + ($1.shiftCost ?? 0) }

                            ForEach(grouped, id: \.key) { weekStart, shifts in
                                let weekHours = shifts.reduce(0) { $0 + $1.durationHours }
                                DisclosureGroup {
                                    ForEach(shifts, id: \.assignmentId) { record in
                                        ShiftRecordRow(
                                            record: record,
                                            currencySymbol: currencySymbol,
                                            convertedCost: convertedCost(record.shiftCost)
                                        )
                                    }
                                } label: {
                                    HStack {
                                        Text("Week of \(pretty(weekStart))")
                                        Spacer()
                                        Text(fmtHours(weekHours))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            HStack {
                                Text("Total").fontWeight(.medium)
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(fmtHours(totalHours))
                                    if totalCost > 0 {
                                        let converted = exchangeRates.convert(
                                            totalCost,
                                            from: employee.wageCurrency ?? displayCurrency,
                                            to: displayCurrency
                                        )
                                        Text(String(format: "%@%.2f", currencySymbol, converted))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                }
            }

            if let notes = employee.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }

            Section {
                let days = weekDays(offset: availabilityWeekOffset)
                let merged = mergedActualSlots(for: days)
                let range = AvailabilityGridView.inferredVisibleRange(from: merged)
                let outlined = Set(days.filter { overrideByDate[$0.iso]?.source == "exception" }.map { $0.weekday })
                let readOnly = Set(days.filter { $0.date < todayStartOfDay }.map { $0.weekday })
                let subheaders = Dictionary(uniqueKeysWithValues: days.map { ($0.weekday, Self.weekRangeFmt.string(from: $0.date).components(separatedBy: " ").last ?? "") })

                HStack {
                    Button { availabilityWeekOffset -= 1 } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Previous week")
                    Spacer()
                    VStack(spacing: 1) {
                        Text(actualWeekLabel(days: days))
                            .font(.subheadline).fontWeight(.medium)
                        if availabilityWeekOffset == 0 {
                            Text("This week").font(.caption2).foregroundStyle(.secondary)
                        } else if availabilityWeekOffset == 1 {
                            Text("Next week").font(.caption2).foregroundStyle(.secondary)
                        } else if availabilityWeekOffset == -1 {
                            Text("Last week").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { availabilityWeekOffset += 1 } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Next week")
                }

                AvailabilityGridView(
                    slots: merged,
                    isEditable: false,
                    visibleHourStart: range.start,
                    visibleHourEnd: range.end,
                    outlinedWeekdays: outlined,
                    readOnlyWeekdays: readOnly,
                    weekdaySubheaders: subheaders
                )

                if !outlined.isEmpty {
                    HStack(spacing: 6) {
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                        Text("Orange outline = exception for that day")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Availability")
            }

            Section("Analytics") {
                NavigationLink {
                    EmployeeShiftHistoryView(
                        employeeId: employee.id,
                        targetWeeklyHours: employee.targetWeeklyHours,
                        hourlyWage: employee.hourlyWage,
                        wageCurrency: employee.wageCurrency
                    )
                } label: {
                    Label("View Analytics", systemImage: "chart.bar.xaxis")
                }
            }

            Section("Exceptions") {
                if overrideVM.isLoading {
                    ProgressView()
                } else {
                    ForEach(groupedOverrides) { group in
                        Button {
                            if group.isRange {
                                editingOverrideGroup = group
                            } else if let first = group.items.first {
                                editingOverride = first
                            }
                        } label: {
                            overrideGroupRow(group)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                if group.isRange {
                                    editingOverrideGroup = group
                                } else if let first = group.items.first {
                                    editingOverride = first
                                }
                            } label: {
                                Label(group.isRange ? "Edit Range" : "Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                Task {
                                    for ovr in group.items {
                                        await overrideVM.deleteEmployeeOverride(id: ovr.id)
                                    }
                                    await overrideVM.loadForEmployee(id: employee.id)
                                }
                            } label: {
                                Label(group.isRange ? "Delete All (\(group.items.count))" : "Delete",
                                      systemImage: "trash")
                            }
                        }
                    }
                    Button("Add Exception") { showingAddOverride = true }
                        .foregroundStyle(.tint)
                }
            }
        }
        .navigationTitle(employee.displayName)
        .task {
            await overrideVM.loadForEmployee(id: employee.id)
            await shiftVM.load(employeeId: employee.id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEditSheet = true }
            }
        }
        .sheet(isPresented: $showingEditSheet, onDismiss: {
            Task { await overrideVM.loadForEmployee(id: employee.id) }
        }) {
            EmployeeEditSheet(viewModel: viewModel, existing: employee, onDelete: { dismiss() })
        }
        .sheet(isPresented: $showingAddOverride, onDismiss: { Task { await overrideVM.loadForEmployee(id: employee.id) } }) {
            EmployeeAvailabilityOverrideSheet(
                vm: overrideVM, employees: [employee], existing: nil,
                preselectedEmployeeId: employee.id
            )
        }
        .sheet(item: $editingOverride, onDismiss: { Task { await overrideVM.loadForEmployee(id: employee.id) } }) { ovr in
            EmployeeAvailabilityOverrideSheet(
                vm: overrideVM, employees: [employee], existing: ovr,
                preselectedEmployeeId: employee.id
            )
        }
        .sheet(item: $editingOverrideGroup, onDismiss: { Task { await overrideVM.loadForEmployee(id: employee.id) } }) { group in
            EmployeeAvailabilityOverrideSheet(
                vm: overrideVM, employees: [employee], existing: nil,
                existingRange: group.items,
                preselectedEmployeeId: employee.id
            )
        }
    }
}

struct RoleTag: View {
    let name: String
    var body: some View {
        Text(name.isEmpty ? "Any Role" : name)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.secondary.opacity(0.15)))
            .foregroundStyle(name.isEmpty ? .tertiary : .secondary)
    }
}
