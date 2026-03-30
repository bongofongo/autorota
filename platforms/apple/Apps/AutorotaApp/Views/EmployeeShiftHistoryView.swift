import SwiftUI
import AutorotaKit

struct EmployeeShiftHistoryView: View {

    let employeeId: Int64
    let targetWeeklyHours: Float
    let hourlyWage: Float?
    let wageCurrency: String?

    @AppStorage("appCurrency") private var displayCurrency: String = AppCurrency.usd.rawValue
    @Environment(ExchangeRateService.self) private var exchangeRates
    @State private var vm = ShiftHistoryViewModel()

    private var currencySymbol: String {
        exchangeRates.symbol(for: displayCurrency)
    }

    /// Convert an earnings amount from the employee's stored currency to the display currency.
    private func converted(_ amount: Float) -> Float {
        exchangeRates.convert(amount, from: wageCurrency ?? displayCurrency, to: displayCurrency)
    }

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
            } else {
                List {
                    currentWeekSection
                    upcomingSection
                    pastSection
                    totalsSection
                }
            }
        }
        .navigationTitle("Analytics")
        .task { await vm.load(employeeId: employeeId) }
        .alert("Error", isPresented: .constant(vm.error != nil)) {
            Button("OK") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    // MARK: - Sections

    private var currentWeekSection: some View {
        Section("This Week") {
            LabeledContent("Hours",
                value: "\(fmtHours(vm.currentWeekHours)) / \(fmtHours(targetWeeklyHours)) target")
            if hourlyWage != nil {
                LabeledContent("Earnings",
                    value: fmtCurrency(converted(vm.currentWeekEarnings), symbol: currencySymbol))
            }
            if vm.currentWeekShifts.isEmpty {
                Text("No shifts this week.").foregroundStyle(.secondary)
            } else {
                DisclosureGroup {
                    ForEach(vm.currentWeekShifts, id: \.assignmentId) { record in
                        ShiftRecordRow(record: record, currencySymbol: currencySymbol, convertedCost: record.shiftCost.map { converted($0) })
                    }
                } label: {
                    HStack {
                        Text("Shifts")
                        Spacer()
                        if hourlyWage != nil && currentWeekEarnings > 0 {
                            Text(fmtCurrency(converted(currentWeekEarnings), symbol: currencySymbol))
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                        Text(fmtHours(vm.currentWeekHours))
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    private var currentWeekEarnings: Float {
        vm.currentWeekShifts.reduce(0) { $0 + ($1.shiftCost ?? 0) }
    }

    private var upcomingSection: some View {
        Section("Upcoming") {
            if vm.plannedShifts.isEmpty {
                Text("No upcoming shifts.").foregroundStyle(.secondary)
            } else {
                ForEach(groupedByWeek(vm.plannedShifts), id: \.weekStart) { group in
                    DisclosureGroup {
                        ForEach(group.records, id: \.assignmentId) { record in
                            ShiftRecordRow(record: record, currencySymbol: currencySymbol, convertedCost: record.shiftCost.map { converted($0) })
                        }
                    } label: {
                        HStack {
                            Text("Week of \(group.weekStart)")
                            Spacer()
                            if hourlyWage != nil && group.totalEarnings > 0 {
                                Text(fmtCurrency(converted(group.totalEarnings), symbol: currencySymbol))
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                            Text(fmtHours(group.totalHours))
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    private var pastSection: some View {
        Section("Past") {
            if vm.pastShifts.isEmpty {
                Text("No past shifts.").foregroundStyle(.secondary)
            } else {
                ForEach(groupedByWeek(vm.pastShifts).reversed(), id: \.weekStart) { group in
                    DisclosureGroup {
                        ForEach(group.records, id: \.assignmentId) { record in
                            ShiftRecordRow(record: record, currencySymbol: currencySymbol, convertedCost: record.shiftCost.map { converted($0) })
                        }
                    } label: {
                        HStack {
                            Text("Week of \(group.weekStart)")
                            Spacer()
                            if hourlyWage != nil && group.totalEarnings > 0 {
                                Text(fmtCurrency(converted(group.totalEarnings), symbol: currencySymbol))
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                            Text(fmtHours(group.totalHours))
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    private var totalsSection: some View {
        Section("Totals") {
            LabeledContent("Total worked",
                value: "\(fmtHours(vm.totalHours)) across \(vm.pastShifts.count) shifts")
            if hourlyWage != nil {
                LabeledContent("Total earned",
                    value: fmtCurrency(converted(vm.totalEarnings), symbol: currencySymbol))
            }
            DisclosureGroup("Weekly") {
                ForEach(vm.weeklyBreakdown) { entry in
                    LabeledContent(entry.weekStart,
                        value: hourlyWage != nil
                            ? "\(fmtHours(entry.hours)) — \(fmtCurrency(converted(entry.earnings), symbol: currencySymbol))"
                            : fmtHours(entry.hours))
                }
            }
            DisclosureGroup("Monthly") {
                ForEach(vm.monthlyBreakdown) { entry in
                    LabeledContent(entry.month,
                        value: hourlyWage != nil
                            ? "\(fmtHours(entry.hours)) — \(fmtCurrency(converted(entry.earnings), symbol: currencySymbol))"
                            : fmtHours(entry.hours))
                }
            }
        }
    }

    // MARK: - Helpers

    private struct WeekGroup {
        let weekStart: String
        let records: [FfiEmployeeShiftRecord]
        var totalHours: Float { records.reduce(0) { $0 + $1.durationHours } }
        var totalEarnings: Float { records.reduce(0) { $0 + ($1.shiftCost ?? 0) } }
    }

    private func groupedByWeek(_ records: [FfiEmployeeShiftRecord]) -> [WeekGroup] {
        let grouped = Dictionary(grouping: records) { $0.weekStart }
        return grouped.map { WeekGroup(weekStart: $0.key, records: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }
    }
}

// MARK: - Formatting helpers

/// Formats a float, dropping the decimal when it's a whole number (e.g. 8.0 → "8", 8.5 → "8.5").
private func fmtHours(_ v: Float) -> String {
    v.truncatingRemainder(dividingBy: 1) == 0
        ? "\(Int(v))h"
        : String(format: "%.1fh", v)
}

private func fmtCurrency(_ v: Float, symbol: String) -> String {
    v.truncatingRemainder(dividingBy: 1) == 0
        ? "\(symbol)\(Int(v))"
        : String(format: "%@%.2f", symbol, v)
}

// MARK: - Shift Record Row

private struct ShiftRecordRow: View {
    let record: FfiEmployeeShiftRecord
    let currencySymbol: String
    var convertedCost: Float?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.weekday) \(record.date)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("\(record.startTime) – \(record.endTime)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(record.requiredRole)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(Capsule())
            statusBadge
            VStack(alignment: .trailing, spacing: 1) {
                Text(fmtHours(record.durationHours))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if let cost = convertedCost {
                    Text(fmtCurrency(cost, symbol: currencySymbol))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (color, label) = statusInfo
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var statusInfo: (Color, String) {
        switch record.status {
        case "Proposed": (.orange, "Proposed")
        case "Confirmed": (.green, "Confirmed")
        case "Overridden": (.blue, "Overridden")
        default: (.gray, record.status)
        }
    }
}
