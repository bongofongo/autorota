import SwiftUI
import AutorotaKit

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
    /// Sticky lasso mode is on in one of the grids — pauses Form scrolling.
    @State private var gridLassoActive = false
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
            case .none: String(localized: "Not linked")
            case .imessage: "iMessage"
            case .whatsapp: "WhatsApp"
            }
        }
    }
    @State private var hourlyWageText = ""
    @State private var wageCurrency: String = AppCurrency.usd.rawValue

    @State private var defaultAvailabilitySlots: [AvailabilitySlot] = []

    enum AvailMode: String, CaseIterable, Identifiable {
        case `default` = "Default"
        case actual = "Actual"
        var id: String { rawValue }
    }
    @State private var availabilityMode: AvailMode = .actual
    @State private var actualWeekOffset: Int = 1
    @State private var actualEditsByDate: [String: [DayAvailabilitySlot]] = [:]

    @State private var defaultVisibleStart = 6
    @State private var defaultVisibleEnd = 22


    private var isEditing: Bool { existing != nil }

    private static func isValidEmail(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        let parts = trimmed.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return parts[1].contains(".")
    }

    private static let sheetWeekRangeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func sheetWeekDays(offset: Int) -> [(weekday: String, date: Date, iso: String)] {
        AvailabilityWeekMath.weekDays(from: weekStart(weeksFromNow: offset))
    }

    private var sheetOverrideByIso: [String: FfiEmployeeAvailabilityOverride] {
        Dictionary(overrideVM.employeeAvailabilityOverrides.map { ($0.date, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    private func mergedActualSlotsForEdit(offset: Int) -> [AvailabilitySlot] {
        // Unsaved in-sheet edits take precedence over stored overrides:
        // wrap them as synthetic overrides so the shared merge applies them.
        var overrides = sheetOverrideByIso
        for (iso, edits) in actualEditsByDate {
            overrides[iso] = FfiEmployeeAvailabilityOverride(
                id: 0, employeeId: existing?.id ?? 0, date: iso,
                availability: edits, notes: nil, source: "manual"
            )
        }
        return AvailabilityWeekMath.merge(
            days: sheetWeekDays(offset: offset),
            overrides: overrides,
            defaultAvailability: defaultAvailabilitySlots
        )
    }

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
                                .appDecimalKeyboard()
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
                            .appEmailKeyboardConfig()
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
                                applyDefaultRangeChange(start: start, end: end)
                            },
                            onLassoModeChange: { gridLassoActive = $0 }
                        )
                    case .actual:
                        let days = sheetWeekDays(offset: actualWeekOffset)
                        let merged = mergedActualSlotsForEdit(offset: actualWeekOffset)
                        let outlined = Set(days.compactMap { day -> String? in
                            if actualEditsByDate[day.iso] != nil {
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
                            onLassoModeChange: { gridLassoActive = $0 },
                            onReset: {
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
            .dismissesKeyboardOnTap()
            .appFormGroupedStyle()
            .scrollDisabled(gridLassoActive)
            .onChange(of: availabilityMode) { _, _ in
                // Switching grids unmounts the toggled one; never leave
                // scrolling stuck off.
                gridLassoActive = false
            }
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
        .appSheetMacFrame(minWidth: 560, idealWidth: 640, minHeight: 550, idealHeight: 700)
    }

    private func prefill() {
        guard let e = existing else { return }
        firstName = e.firstName
        lastName = e.lastName
        nickname = e.nickname ?? ""
        selectedRoles = Set(e.roles)
        startDate = AvailabilityWeekMath.isoFmt.date(from: e.startDate) ?? Date()
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

    /// Updates the default-availability visible range. Hours that just became visible
    /// and are explicit "No" on all 7 days are artifacts of a previous save's
    /// out-of-range fill — clear them back to Maybe, otherwise `inferredVisibleRange`
    /// would snap the range back on the next open.
    private func applyDefaultRangeChange(start: Int, end: Int) {
        let oldStart = defaultVisibleStart
        let oldEnd = defaultVisibleEnd
        defaultVisibleStart = start
        defaultVisibleEnd = end
        for hour in 0...23 {
            guard AvailabilityGridView.hourIsInRange(hour, start: start, end: end),
                  !AvailabilityGridView.hourIsInRange(hour, start: oldStart, end: oldEnd) else { continue }
            let row = defaultAvailabilitySlots.filter { Int($0.hour) == hour }
            if row.count == 7, row.allSatisfy({ $0.state == "No" }) {
                defaultAvailabilitySlots.removeAll { Int($0.hour) == hour }
            }
        }
    }

    private func save() {
        let finalDefault = AvailabilityGridView.slotsWithOutOfRangeSetToNo(
            slots: defaultAvailabilitySlots, start: defaultVisibleStart, end: defaultVisibleEnd)

        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        let trimmedLast = lastName.trimmingCharacters(in: .whitespaces)
        let trimmedNick = nickname.trimmingCharacters(in: .whitespaces)
        let displayWage: Float? = Float(hourlyWageText.trimmingCharacters(in: .whitespaces))
        let parsedWage: Float? = displayWage.map { exchangeRates.convert($0, from: displayCurrency, to: wageCurrency) }
        let emp = FfiEmployee(
            id: existing?.id ?? 0,
            firstName: trimmedFirst,
            lastName: trimmedLast,
            nickname: trimmedNick.isEmpty ? nil : trimmedNick,
            displayName: "",
            roles: Array(selectedRoles),
            startDate: AvailabilityWeekMath.isoFmt.string(from: startDate),
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
                dismiss()
                return
            }

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
                guard let date = AvailabilityWeekMath.isoFmt.date(from: iso) else { continue }
                let wd = wdMap[cal.component(.weekday, from: date)] ?? "Mon"
                let sortedEdit = editedDay.sorted { $0.hour < $1.hour }
                let defaultDay = defaultForWeekday(wd)
                let existing = existingByIso[iso]
                if sortedEdit == defaultDay {
                    if let ex = existing, ex.source != "exception" {
                        await overrideVM.deleteEmployeeOverride(id: ex.id)
                    }
                } else {
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
                .appDecimalKeyboard()
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
