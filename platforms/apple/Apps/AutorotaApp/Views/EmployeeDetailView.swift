import SwiftUI
import AutorotaKit
import TipKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Canonical preferred messaging channel tokens shared between the edit sheet
/// and the read-only Details Phone row. Kept file-local since only this view
/// consumes it today.
enum ContactMethod: String {
    case imessage
    case whatsapp

    var icon: String {
        switch self {
        case .imessage: "message.fill"
        case .whatsapp: "bubble.left.and.bubble.right.fill"
        }
    }

    /// Build a deep link for `phone`. `sms:` opens Messages (iMessage when
    /// available, SMS otherwise). `wa.me/<E.164-less-plus>` opens WhatsApp
    /// when installed, otherwise the web click-to-chat flow.
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

struct EmployeeDetailView: View {

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

    // Disclosure group expansion state for shifts section
    @State private var lastWeekExpanded = false
    @State private var thisWeekExpanded = false
    @State private var nextWeekExpanded = false

    // Custom date range
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
        // The detail view's Exceptions list only surfaces rows explicitly
        // classified as exceptions. Manual per-date edits (written by the
        // Actual availability grid) share the same table but are not
        // exceptions and must stay hidden here.
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

    /// Merge default template with per-date overrides into weekday-keyed slots for a specific week.
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
                    // Promote domestic/partial input to E.164 so the display
                    // shows the `+CC` prefix, then group.
                    let e164 = displayFormatter.normalizeForStorage(phone)
                    let prettyPhone = displayFormatter.format(e164)
                    HStack {
                        Text("Phone").foregroundStyle(.secondary)
                        Spacer()
                        Text(prettyPhone)
                        if let method, let url = method.url(for: phone) {
                            Button {
                                #if canImport(UIKit)
                                UIApplication.shared.open(url)
                                #elseif canImport(AppKit)
                                NSWorkspace.shared.open(url)
                                #endif
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
                                #if canImport(UIKit)
                                UIApplication.shared.open(url)
                                #elseif canImport(AppKit)
                                NSWorkspace.shared.open(url)
                                #endif
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

                    // Custom date range
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
                // Orange outline marks exceptions only. Manual per-date edits
                // also sit in overrideByDate (so the grid renders the right
                // actual availability) but must not display as exceptions.
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
                            if let first = group.items.first { editingOverride = first }
                        } label: {
                            overrideGroupRow(group)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let first = group.items.first {
                                Button {
                                    editingOverride = first
                                } label: {
                                    Label(group.isRange ? "Edit First Day" : "Edit", systemImage: "pencil")
                                }
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
    }
}

// MARK: - Edit / Create sheet

struct EmployeeEditSheet: View {

    let viewModel: EmployeeViewModel
    var existing: FfiEmployee?
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(ExchangeRateService.self) private var exchangeRates
    @AppStorage("appCurrency") private var displayCurrency: String = AppCurrency.usd.rawValue
    @State private var showingDeleteConfirmation = false

    @State private var roleVM = RoleViewModel()
    @State private var overrideVM = OverrideViewModel()
    private let employeeRolesTip = EmployeeRolesTip()
    private let availabilityModeTip = AvailabilityModeTip()
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var nickname = ""
    @State private var selectedRoles: Set<String> = []
    @State private var startDate = Date()
    @State private var targetHours = 20.0
    @State private var deviation = 4.0
    @State private var maxDaily = 8.0
    @State private var notes = ""
    @State private var phone = ""
    @State private var phoneCountry: PhoneCountry = PhoneCountry(
        regionCode: Locale.current.region?.identifier ?? ""
    )
    @State private var email = ""
    @State private var preferredContact: PreferredContact = .none

    private var phoneFormatter: PhoneNumberFormatter {
        PhoneNumberFormatter(country: phoneCountry)
    }

    /// Live formatter passed to `PhoneInputField`. Auto-detects country on
    /// pasted `+CC…` input, then groups the NSN for the selected country.
    private func formatPhoneInput(_ raw: String) -> String {
        let normNew = phoneFormatter.normalize(raw)
        if normNew.hasPrefix("+") {
            let detected = PhoneCountry.detect(from: normNew)
            if detected != .other, detected != phoneCountry {
                phoneCountry = detected
            }
        }
        return PhoneNumberFormatter(country: phoneCountry).formatForField(raw)
    }

    /// Inline hint shown when the current input fails validation.
    private var invalidPhoneHint: String {
        if phoneCountry == .other {
            return "Enter 7–15 digits. Use + for international."
        }
        let range = phoneCountry.nsnLengthRange
        if range.lowerBound == range.upperBound {
            return "Enter a \(range.lowerBound)-digit \(phoneCountry.displayName) number."
        }
        return "Enter a \(range.lowerBound)–\(range.upperBound)-digit \(phoneCountry.displayName) number."
    }

    /// Swap the selected country while preserving the NSN the user has
    /// already entered. Empty fields stay empty.
    private func switchPhoneCountry(to new: PhoneCountry) {
        let oldF = PhoneNumberFormatter(country: phoneCountry)
        let nsn = oldF.extractNSN(phone)
        phoneCountry = new
        let newF = PhoneNumberFormatter(country: new)
        phone = newF.formatForField(nsn)
    }

    enum PreferredContact: String, CaseIterable, Identifiable {
        case none = ""
        case imessage = "imessage"
        case whatsapp = "whatsapp"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "Not linked"
            case .imessage: "iMessage"
            case .whatsapp: "WhatsApp"
            }
        }
    }
    @State private var hourlyWageText = ""
    @State private var wageCurrency: String = AppCurrency.usd.rawValue

    // Availability state
    @State private var defaultAvailabilitySlots: [AvailabilitySlot] = []

    enum AvailMode: String, CaseIterable, Identifiable {
        case `default` = "Default"
        case actual = "Actual"
        var id: String { rawValue }
    }
    @State private var availabilityMode: AvailMode = .actual
    @State private var actualWeekOffset: Int = 1
    /// ISO date → edited day slots (staged). Reflects a delta over existing overrides.
    @State private var actualEditsByDate: [String: [DayAvailabilitySlot]] = [:]

    // Visible hour range — shared by both grids, set via the Default range picker
    @State private var defaultVisibleStart = 6
    @State private var defaultVisibleEnd = 22

    // Selection mode — disables Form scrolling while active
    @State private var selectionModeActive = false

    private var isEditing: Bool { existing != nil }

    /// Minimal RFC5322-subset check: `local@domain.tld`, no spaces.
    private static func isValidEmail(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        let parts = trimmed.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return parts[1].contains(".")
    }

    private static let sheetDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let sheetWeekRangeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func sheetMondayOfWeek(offset: Int) -> Date {
        let cal = Calendar(identifier: .iso8601)
        let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        return cal.date(byAdding: .weekOfYear, value: offset, to: monday)!
    }

    private func sheetWeekDays(offset: Int) -> [(weekday: String, date: Date, iso: String)] {
        let cal = Calendar(identifier: .iso8601)
        let mon = sheetMondayOfWeek(offset: offset)
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: mon)!
            return (EmployeeDetailView.weekdayOrder[i], d, Self.sheetDateFmt.string(from: d))
        }
    }

    private var sheetOverrideByIso: [String: FfiEmployeeAvailabilityOverride] {
        Dictionary(overrideVM.employeeAvailabilityOverrides.map { ($0.date, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Merged weekday-keyed slots for the visible week: edits > overrides > default template.
    private func mergedActualSlotsForEdit(offset: Int) -> [AvailabilitySlot] {
        let days = sheetWeekDays(offset: offset)
        var out: [AvailabilitySlot] = []
        for (wd, _, iso) in days {
            if let edits = actualEditsByDate[iso] {
                for s in edits {
                    out.append(AvailabilitySlot(weekday: wd, hour: s.hour, state: s.state))
                }
            } else if let ovr = sheetOverrideByIso[iso] {
                for s in ovr.availability {
                    out.append(AvailabilitySlot(weekday: wd, hour: s.hour, state: s.state))
                }
            } else {
                for s in defaultAvailabilitySlots where s.weekday == wd {
                    out.append(s)
                }
            }
        }
        return out
    }

    /// Diff new grid output against the merged baseline and stage per-date edits.
    private func applyActualEdit(newSlots: [AvailabilitySlot]) {
        let days = sheetWeekDays(offset: actualWeekOffset)
        for (wd, _, iso) in days {
            let newDay = newSlots
                .filter { $0.weekday == wd }
                .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
                .sorted { $0.hour < $1.hour }
            let baseline: [DayAvailabilitySlot]
            if let edits = actualEditsByDate[iso] {
                baseline = edits.sorted { $0.hour < $1.hour }
            } else if let ovr = sheetOverrideByIso[iso] {
                baseline = ovr.availability.sorted { $0.hour < $1.hour }
            } else {
                baseline = defaultAvailabilitySlots
                    .filter { $0.weekday == wd }
                    .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
                    .sorted { $0.hour < $1.hour }
            }
            if newDay != baseline {
                actualEditsByDate[iso] = newDay
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Info") {
                    TextField("First Name", text: $firstName)
                    TextField("Last Name", text: $lastName)
                    TextField("Nickname (optional)", text: $nickname)
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                }
                Section("Roles") {
                    if roleVM.roles.isEmpty {
                        Text("No roles defined. Add roles in the Shifts tab.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(roleVM.roles, id: \.id) { role in
                        Toggle(role.name, isOn: Binding(
                            get: { selectedRoles.contains(role.name) },
                            set: { on in
                                if on { selectedRoles.insert(role.name) }
                                else { selectedRoles.remove(role.name) }
                            }
                        ))
                    }
                }
                .popoverTip(employeeRolesTip)
                Section("Hours") {
                    StepperField(label: "Target", suffix: "h/week",
                                 value: $targetHours, range: 0...80, step: 1)
                    StepperField(label: "Deviation", suffix: "h ±",
                                 value: $deviation, range: 0...20, step: 1)
                    StepperField(label: "Max daily", suffix: "h",
                                 value: $maxDaily, range: 1...24, step: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Hourly wage")
                            Spacer()
                            Text(exchangeRates.symbol(for: displayCurrency))
                                .foregroundStyle(.secondary)
                            TextField("Not set", text: $hourlyWageText)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                        HStack {
                            Text("Stored as")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $wageCurrency) {
                                ForEach(AppCurrency.allCases, id: \.rawValue) { c in
                                    Text(c.label).tag(c.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Contact") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Email (optional)", text: $email)
                            #if canImport(UIKit)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            #endif
                        if !email.isEmpty, !Self.isValidEmail(email) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                Text("Enter a valid email address.")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    Picker("Messaging app", selection: $preferredContact) {
                        ForEach(PreferredContact.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    if preferredContact != .none {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                PhoneInputField(
                                    text: $phone,
                                    placeholder: phoneCountry.placeholder,
                                    format: formatPhoneInput
                                )
                                Menu {
                                    ForEach(PhoneCountry.allCases) { c in
                                        Button {
                                            switchPhoneCountry(to: c)
                                        } label: {
                                            HStack {
                                                Text("\(c.flag)  \(c.displayName)")
                                                if !c.callingCode.isEmpty {
                                                    Spacer()
                                                    Text("+\(c.callingCode)")
                                                }
                                                if c == phoneCountry {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(phoneCountry.flag)
                                        Text(phoneCountry.chipLabel)
                                            .font(.callout.monospacedDigit())
                                        Image(systemName: "chevron.down")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.quaternary, in: Capsule())
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            if !phone.isEmpty {
                                HStack(spacing: 4) {
                                    if phoneFormatter.isValid(phone) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                        Text("Looks valid")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.orange)
                                        Text(invalidPhoneHint)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                Section("Availability") {
                    Picker("Mode", selection: $availabilityMode) {
                        ForEach(AvailMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .popoverTip(availabilityModeTip)

                    switch availabilityMode {
                    case .default:
                        AvailabilityGridView(
                            slots: defaultAvailabilitySlots,
                            isEditable: true,
                            visibleHourStart: defaultVisibleStart,
                            visibleHourEnd: defaultVisibleEnd,
                            showRangePicker: true,
                            onChange: { defaultAvailabilitySlots = $0 },
                            onVisibleRangeChange: { start, end in
                                defaultVisibleStart = start
                                defaultVisibleEnd = end
                            },
                            onSelectionModeChange: { selectionModeActive = $0 }
                        )
                    case .actual:
                        let days = sheetWeekDays(offset: actualWeekOffset)
                        let merged = mergedActualSlotsForEdit(offset: actualWeekOffset)
                        // Orange outline marks *exceptions* only — not normal
                        // per-date edits. A staged edit from this sheet is a
                        // manual edit and never outlines. An existing row shows
                        // only if its source is "exception".
                        let outlined = Set(days.compactMap { day -> String? in
                            if actualEditsByDate[day.iso] != nil {
                                // User is editing this day manually — no outline, whatever they do.
                                return nil
                            }
                            return sheetOverrideByIso[day.iso]?.source == "exception" ? day.weekday : nil
                        })
                        let subheaders = Dictionary(uniqueKeysWithValues: days.map {
                            ($0.weekday, Self.sheetWeekRangeFmt.string(from: $0.date).components(separatedBy: " ").last ?? "")
                        })

                        HStack {
                            Button { actualWeekOffset -= 1 } label: {
                                Image(systemName: "chevron.left")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Previous week")
                            Spacer()
                            VStack(spacing: 1) {
                                if let first = days.first?.date, let last = days.last?.date {
                                    Text("\(Self.sheetWeekRangeFmt.string(from: first)) – \(Self.sheetWeekRangeFmt.string(from: last))")
                                        .font(.subheadline).fontWeight(.medium)
                                }
                                if actualWeekOffset == 0 {
                                    Text("This week").font(.caption2).foregroundStyle(.secondary)
                                } else if actualWeekOffset == 1 {
                                    Text("Next week").font(.caption2).foregroundStyle(.secondary)
                                } else if actualWeekOffset == -1 {
                                    Text("Last week").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { actualWeekOffset += 1 } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Next week")
                        }

                        AvailabilityGridView(
                            slots: merged,
                            isEditable: true,
                            visibleHourStart: defaultVisibleStart,
                            visibleHourEnd: defaultVisibleEnd,
                            onChange: { applyActualEdit(newSlots: $0) },
                            onSelectionModeChange: { selectionModeActive = $0 },
                            onReset: {
                                // Reset to default template for every date in visible week.
                                // Staged values matching default are deleted on Save, clearing
                                // any existing per-date overrides for this week.
                                for d in days {
                                    let wd = d.weekday
                                    let defaultDay = defaultAvailabilitySlots
                                        .filter { $0.weekday == wd }
                                        .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
                                        .sorted { $0.hour < $1.hour }
                                    actualEditsByDate[d.iso] = defaultDay
                                }
                            },
                            outlinedWeekdays: outlined,
                            weekdaySubheaders: subheaders
                        )
                    }
                }
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Remove Employee", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollDisabled(selectionModeActive)
            .dismissesKeyboardOnTap()
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(isEditing ? "Edit Employee" : "New Employee")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  lastName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert(
                "Remove \(existing.map { "\($0.firstName) \($0.lastName)" } ?? "Employee")?",
                isPresented: $showingDeleteConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    guard let e = existing else { return }
                    Task {
                        await viewModel.delete(id: e.id)
                        dismiss()
                        onDelete?()
                    }
                }
            } message: {
                Text("This employee will be removed from future rotas. Past and current assignments are preserved.")
            }
            .onAppear {
                if existing == nil { wageCurrency = displayCurrency }
                prefill()
            }
            .task {
                await roleVM.load()
                if let e = existing { await overrideVM.loadForEmployee(id: e.id) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 550, idealHeight: 700)
        #endif
    }

    private func prefill() {
        guard let e = existing else { return }
        firstName = e.firstName
        lastName = e.lastName
        nickname = e.nickname ?? ""
        selectedRoles = Set(e.roles)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        startDate = fmt.date(from: e.startDate) ?? Date()
        targetHours = Double(e.targetWeeklyHours)
        deviation = Double(e.weeklyHoursDeviation)
        maxDaily = Double(e.maxDailyHours)
        notes = e.notes ?? ""
        let stored = e.phone ?? ""
        let detected = PhoneCountry.detect(from: stored)
        phoneCountry = detected == .other
            ? PhoneCountry(regionCode: Locale.current.region?.identifier ?? "")
            : detected
        phone = PhoneNumberFormatter(country: phoneCountry).formatForField(stored)
        email = e.email ?? ""
        preferredContact = PreferredContact(rawValue: e.preferredContact ?? "") ?? .none
        let storedCurrency = e.wageCurrency ?? displayCurrency
        wageCurrency = storedCurrency
        if let wage = e.hourlyWage {
            let converted = exchangeRates.convert(wage, from: storedCurrency, to: displayCurrency)
            hourlyWageText = String(format: "%.2f", converted)
        } else {
            hourlyWageText = ""
        }
        defaultAvailabilitySlots = e.defaultAvailability
        let range = AvailabilityGridView.inferredVisibleRange(from: e.defaultAvailability)
        defaultVisibleStart = range.start
        defaultVisibleEnd = range.end
    }

    private func save() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        let finalDefault = AvailabilityGridView.slotsWithOutOfRangeSetToNo(
            slots: defaultAvailabilitySlots, start: defaultVisibleStart, end: defaultVisibleEnd)

        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        let trimmedLast = lastName.trimmingCharacters(in: .whitespaces)
        let trimmedNick = nickname.trimmingCharacters(in: .whitespaces)
        let displayWage: Float? = Float(hourlyWageText.trimmingCharacters(in: .whitespaces))
        // Convert from display currency back to the employee's storage currency
        let parsedWage: Float? = displayWage.map { exchangeRates.convert($0, from: displayCurrency, to: wageCurrency) }
        // Keep `availability` mirrored to `defaultAvailability` so scheduler's weekday
        // fallback matches the template for any week without an override.
        let emp = FfiEmployee(
            id: existing?.id ?? 0,
            firstName: trimmedFirst,
            lastName: trimmedLast,
            nickname: trimmedNick.isEmpty ? nil : trimmedNick,
            displayName: "",  // Rust recomputes this on save
            roles: Array(selectedRoles),
            startDate: fmt.string(from: startDate),
            targetWeeklyHours: Float(targetHours),
            weeklyHoursDeviation: Float(deviation),
            maxDailyHours: Float(maxDaily),
            notes: notes.isEmpty ? nil : notes,
            bankDetails: existing?.bankDetails,
            phone: {
                guard preferredContact != .none else { return nil }
                let normalized = phoneFormatter.normalizeForStorage(phone)
                return normalized.isEmpty ? nil : normalized
            }(),
            email: {
                let trimmed = email.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }(),
            preferredContact: preferredContact == .none ? nil : preferredContact.rawValue,
            hourlyWage: parsedWage,
            wageCurrency: parsedWage != nil ? wageCurrency : nil,
            defaultAvailability: finalDefault,
            availability: finalDefault,
            deleted: false
        )

        Task {
            let savedEmpId: Int64
            if isEditing {
                await viewModel.update(emp)
                savedEmpId = emp.id
            } else {
                await viewModel.create(emp)
                // Skip override persistence for brand-new employees — UI can't have staged
                // edits against an employee that didn't exist yet, but the guard is defensive.
                dismiss()
                return
            }

            // Persist staged per-date edits as overrides (create/update/delete).
            let defaultForWeekday: (String) -> [DayAvailabilitySlot] = { wd in
                finalDefault
                    .filter { $0.weekday == wd }
                    .map { DayAvailabilitySlot(hour: $0.hour, state: $0.state) }
                    .sorted { $0.hour < $1.hour }
            }
            let wdMap: [Int: String] = [2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat", 1: "Sun"]
            let cal = Calendar(identifier: .iso8601)
            let existingByIso = Dictionary(
                overrideVM.employeeAvailabilityOverrides.map { ($0.date, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            for (iso, editedDay) in actualEditsByDate {
                guard let date = Self.sheetDateFmt.date(from: iso) else { continue }
                let wd = wdMap[cal.component(.weekday, from: date)] ?? "Mon"
                let sortedEdit = editedDay.sorted { $0.hour < $1.hour }
                let defaultDay = defaultForWeekday(wd)
                let existing = existingByIso[iso]
                if sortedEdit == defaultDay {
                    // Staged edit reconciles to the default template. Only
                    // delete when the existing row is a *manual* per-date
                    // edit. Exceptions — deliberately classified via the
                    // Exceptions UI — must not be silently deleted when the
                    // user happens to edit that day back to default.
                    if let ex = existing, ex.source != "exception" {
                        await overrideVM.deleteEmployeeOverride(id: ex.id)
                    }
                } else {
                    // Preserve the original classification on conflict: if
                    // editing an existing exception row, the backend's
                    // ON CONFLICT preserves source. For brand-new rows
                    // written by this sheet, tag them "manual".
                    let source = existing?.source ?? "manual"
                    let ovr = FfiEmployeeAvailabilityOverride(
                        id: existing?.id ?? 0,
                        employeeId: savedEmpId,
                        date: iso,
                        availability: sortedEdit,
                        notes: existing?.notes,
                        source: source
                    )
                    await overrideVM.upsertEmployeeOverride(ovr)
                }
            }
            dismiss()
        }
    }
}

// MARK: - Keyboard dismiss helper

extension View {
    /// Dismisses the software keyboard (iOS) when the user taps on a non-interactive area.
    /// On macOS this is a no-op — adding onTapGesture to a Form breaks click-through to controls.
    func dismissesKeyboardOnTap() -> some View {
        #if canImport(UIKit)
        onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        #else
        self
        #endif
    }
}

// MARK: - Role tag chip

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

// MARK: - Stepper with editable text field

private struct StepperField: View {
    let label: String
    let suffix: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    @State private var textValue: String = ""
    @FocusState private var isFocused: Bool
    @ScaledMetric private var fieldWidth: CGFloat = 48

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            Button {
                value = max(range.lowerBound, value - step)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Decrease \(label)")

            TextField("", text: $textValue)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .frame(width: fieldWidth)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if !focused, let parsed = Double(textValue) {
                        value = min(range.upperBound, max(range.lowerBound, parsed))
                    }
                }
                .onSubmit {
                    if let parsed = Double(textValue) {
                        value = min(range.upperBound, max(range.lowerBound, parsed))
                    }
                }

            Text(suffix)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                value = min(range.upperBound, value + step)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Increase \(label)")
        }
        .onChange(of: value) { _, newVal in
            if !isFocused {
                textValue = String(format: "%.0f", newVal)
            }
        }
        .onAppear {
            textValue = String(format: "%.0f", value)
        }
    }
}
