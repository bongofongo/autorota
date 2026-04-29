import SwiftUI
import Charts
import AutorotaKit

struct AnalyticsView: View {

    @State private var vm = AnalyticsViewModel()
    @Environment(ExchangeRateService.self) private var exchangeRates
    @Environment(\.accessibilityPalette) private var palette
    @AppStorage("appCurrency") private var displayCurrency = "usd"

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.employeeSummaries.isEmpty {
                    ProgressView("Loading analytics…")
                } else if vm.totalHours == 0 && !vm.isLoading {
                    ContentUnavailableView(
                        "No Data",
                        systemImage: "chart.bar",
                        description: Text("Schedule some shifts to see analytics here.")
                    )
                } else {
                    scrollContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Analytics")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                vm.exchangeRates = exchangeRates
                vm.displayCurrency = displayCurrency
                await vm.load()
            }
            #if os(iOS)
            .refreshable { await vm.load() }
            #endif
            .onChange(of: displayCurrency) {
                vm.displayCurrency = displayCurrency
                Task { await vm.load() }
            }
            .alert("Error", isPresented: .constant(vm.error != nil)) {
                Button("OK") { vm.error = nil }
            } message: {
                Text(vm.error ?? "")
            }
        }
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                dateRangePicker
                summaryCards
                employeeHoursSection
                employeeTable
                roleBreakdownSection
                dayOfWeekSection
                weeklyTrendsSection
                weeklyCostTrendsSection
            }
            .padding()
        }
    }

    // MARK: - Date Range Picker

    private var dateRangePicker: some View {
        ZStack {
            Image(systemName: "arrow.right")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                DatePicker("", selection: $vm.startDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Spacer()
                DatePicker("", selection: $vm.endDate, in: vm.startDate..., displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: vm.startDate) {
            if vm.endDate < vm.startDate { vm.endDate = vm.startDate }
            Task { await vm.load() }
        }
        .onChange(of: vm.endDate) {
            Task { await vm.load() }
        }
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            summaryCard(title: "Total Hours", value: fmtHours(vm.totalHours), icon: "clock")
            summaryCard(title: "Labor Cost", value: fmtCost(vm.totalCost), icon: "dollarsign.circle")
            summaryCard(title: "Employees", value: "\(vm.employeeCount)", icon: "person.2")
            summaryCard(title: "Avg Hrs/Employee", value: fmtHours(vm.avgHoursPerEmployee), icon: "chart.bar")
        }
    }

    private func summaryCard(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.bold())
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Employee Hours Chart

    private var employeeHoursSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hours by Employee")
                .font(.headline)

            Chart(vm.employeeSummaries) { emp in
                BarMark(
                    x: .value("Hours", emp.totalHours),
                    y: .value("Employee", emp.name)
                )
                .foregroundStyle(palette.chartPrimary.gradient)
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                }
            }
            .frame(height: max(CGFloat(vm.employeeSummaries.count) * 36, 100))
        }
    }

    // MARK: - Employee Table

    private var employeeTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Employee Breakdown")
                    .font(.headline)
                Spacer()
                Picker("Sort", selection: $vm.employeeSortOrder) {
                    ForEach(AnalyticsViewModel.EmployeeSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }

            ForEach(vm.employeeSummaries) { emp in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(emp.name).fontWeight(.medium)
                        Spacer()
                        Text("\(emp.shiftCount) shifts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label(fmtHours(emp.totalHours), systemImage: "clock")
                        Spacer()
                        if emp.totalEarnings > 0 {
                            Label(fmtCost(emp.totalEarnings), systemImage: "dollarsign.circle")
                        }
                        Spacer()
                        Label("\(fmtHours(emp.avgHoursPerWeek))/wk", systemImage: "calendar")
                        if let target = emp.targetWeeklyHours, target > 0 {
                            Text("(\(fmtHours(target)) target)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    // MARK: - Role Breakdown

    private var roleBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hours by Role")
                .font(.headline)

            Chart(vm.hoursByRole) { role in
                BarMark(
                    x: .value("Hours", role.totalHours),
                    y: .value("Role", role.role)
                )
                .foregroundStyle(palette.chartSecondary.gradient)
                .annotation(position: .trailing) {
                    Text(fmtHours(role.totalHours))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: max(CGFloat(vm.hoursByRole.count) * 36, 60))
        }
    }

    // MARK: - Day of Week Distribution

    private var dayOfWeekSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hours by Day of Week")
                .font(.headline)

            Chart(vm.hoursByDayOfWeek) { day in
                BarMark(
                    x: .value("Day", day.dayName),
                    y: .value("Hours", day.totalHours)
                )
                .foregroundStyle(palette.chartTertiary.gradient)
            }
            .frame(height: 200)
        }
    }

    // MARK: - Weekly Trends

    private var weeklyTrendsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly Hours Trend")
                .font(.headline)

            if vm.weeklyTrends.count > 1 {
                Chart(vm.weeklyTrends) { week in
                    LineMark(
                        x: .value("Week", week.weekStart),
                        y: .value("Hours", week.totalHours)
                    )
                    .foregroundStyle(palette.chartPrimary)
                    PointMark(
                        x: .value("Week", week.weekStart),
                        y: .value("Hours", week.totalHours)
                    )
                    .foregroundStyle(palette.chartPrimary)
                }
                .frame(height: 200)
            } else {
                Text("Need at least 2 weeks of data for trends.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    private var weeklyCostTrendsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly Labor Cost Trend")
                .font(.headline)

            if vm.weeklyTrends.count > 1 && vm.weeklyTrends.contains(where: { $0.totalCost > 0 }) {
                Chart(vm.weeklyTrends) { week in
                    LineMark(
                        x: .value("Week", week.weekStart),
                        y: .value("Cost", week.totalCost)
                    )
                    .foregroundStyle(palette.chartSecondary)
                    AreaMark(
                        x: .value("Week", week.weekStart),
                        y: .value("Cost", week.totalCost)
                    )
                    .foregroundStyle(palette.chartSecondary.opacity(0.1))
                }
                .frame(height: 200)
            } else {
                Text("No wage data available for cost trends.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Formatters

    private func fmtHours(_ h: Float) -> String {
        String(format: "%.1fh", h)
    }

    private func fmtCost(_ c: Float) -> String {
        let sym = exchangeRates.symbol(for: displayCurrency)
        return String(format: "%@%.2f", sym, c)
    }
}
