import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("AnalyticsViewModel")
struct AnalyticsViewModelTests {

    private func makeRecord(
        employeeId: Int64 = 1,
        employeeName: String = "Alice",
        date: String = "2026-04-06",
        weekday: String = "Mon",
        weekStart: String = "2026-04-06",
        durationHours: Float = 8.0,
        shiftCost: Float? = 120.0,
        role: String = "Barista"
    ) -> FfiEmployeeShiftRecord {
        FfiEmployeeShiftRecord(
            assignmentId: Int64.random(in: 1...10000),
            rotaId: 1,
            shiftId: 1,
            employeeId: employeeId,
            status: "Confirmed",
            employeeName: employeeName,
            hourlyWage: shiftCost.map { $0 / durationHours },
            shiftCost: shiftCost,
            date: date,
            weekday: weekday,
            startTime: "09:00",
            endTime: "17:00",
            requiredRole: role,
            durationHours: durationHours,
            weekStart: weekStart
        )
    }

    private func makeEmployee(id: Int64 = 1, first: String = "Alice", targetHours: Float = 20) -> FfiEmployee {
        FfiEmployee(
            id: id, firstName: first, lastName: "Smith", nickname: nil,
            displayName: "\(first) Smith", roles: ["Barista"], startDate: "2025-01-01",
            targetWeeklyHours: targetHours, weeklyHoursDeviation: 5, maxDailyHours: 8,
            notes: nil, bankDetails: nil, hourlyWage: 15.0, wageCurrency: "usd", defaultAvailability: [], availability: [], deleted: false
        )
    }

    @Test func loadComputesAggregatesCorrectly() async {
        let mock = MockAutorotaService()
        mock.stubbedAllShiftHistory = [
            makeRecord(employeeId: 1, employeeName: "Alice", durationHours: 8, shiftCost: 120),
            makeRecord(employeeId: 1, employeeName: "Alice", date: "2026-04-07", weekday: "Tue", durationHours: 6, shiftCost: 90),
            makeRecord(employeeId: 2, employeeName: "Bob", durationHours: 4, shiftCost: 60),
        ]
        mock.stubbedEmployees = [makeEmployee(id: 1), makeEmployee(id: 2, first: "Bob")]
        let vm = AnalyticsViewModel(service: mock)

        await vm.load()

        #expect(vm.totalHours == 18.0)
        #expect(vm.totalCost == 270.0)
        #expect(vm.employeeCount == 2)
        #expect(vm.avgHoursPerEmployee == 9.0)
        #expect(vm.error == nil)
        #expect(vm.isLoading == false)
    }

    @Test func employeeSummariesGroupByEmployee() async {
        let mock = MockAutorotaService()
        mock.stubbedAllShiftHistory = [
            makeRecord(employeeId: 1, employeeName: "Alice", durationHours: 8, shiftCost: 120),
            makeRecord(employeeId: 1, employeeName: "Alice", date: "2026-04-07", weekday: "Tue", durationHours: 6, shiftCost: 90),
            makeRecord(employeeId: 2, employeeName: "Bob", durationHours: 4, shiftCost: 60),
        ]
        mock.stubbedEmployees = [makeEmployee(id: 1), makeEmployee(id: 2, first: "Bob")]
        let vm = AnalyticsViewModel(service: mock)

        await vm.load()

        #expect(vm.employeeSummaries.count == 2)
        let alice = vm.employeeSummaries.first { $0.id == 1 }
        #expect(alice != nil)
        #expect(alice?.totalHours == 14.0)
        #expect(alice?.totalEarnings == 210.0)
        #expect(alice?.shiftCount == 2)

        let bob = vm.employeeSummaries.first { $0.id == 2 }
        #expect(bob?.totalHours == 4.0)
        #expect(bob?.shiftCount == 1)
    }

    @Test func hoursByRoleGroupsCorrectly() async {
        let mock = MockAutorotaService()
        mock.stubbedAllShiftHistory = [
            makeRecord(durationHours: 8, role: "Barista"),
            makeRecord(durationHours: 6, role: "Barista"),
            makeRecord(durationHours: 4, role: "Kitchen"),
        ]
        mock.stubbedEmployees = [makeEmployee()]
        let vm = AnalyticsViewModel(service: mock)

        await vm.load()

        #expect(vm.hoursByRole.count == 2)
        let barista = vm.hoursByRole.first { $0.role == "Barista" }
        #expect(barista?.totalHours == 14.0)
        #expect(barista?.shiftCount == 2)
        let kitchen = vm.hoursByRole.first { $0.role == "Kitchen" }
        #expect(kitchen?.totalHours == 4.0)
    }

    @Test func weeklyTrendsAreSortedChronologically() async {
        let mock = MockAutorotaService()
        mock.stubbedAllShiftHistory = [
            makeRecord(weekStart: "2026-04-13", durationHours: 10, shiftCost: 150),
            makeRecord(weekStart: "2026-03-30", durationHours: 8, shiftCost: 120),
            makeRecord(weekStart: "2026-04-06", durationHours: 6, shiftCost: 90),
        ]
        mock.stubbedEmployees = [makeEmployee()]
        let vm = AnalyticsViewModel(service: mock)

        await vm.load()

        #expect(vm.weeklyTrends.count == 3)
        #expect(vm.weeklyTrends[0].weekStart == "2026-03-30")
        #expect(vm.weeklyTrends[1].weekStart == "2026-04-06")
        #expect(vm.weeklyTrends[2].weekStart == "2026-04-13")
    }

    @Test func dayOfWeekDistribution() async {
        let mock = MockAutorotaService()
        mock.stubbedAllShiftHistory = [
            makeRecord(weekday: "Mon", durationHours: 8),
            makeRecord(weekday: "Mon", durationHours: 6),
            makeRecord(weekday: "Fri", durationHours: 4),
        ]
        mock.stubbedEmployees = [makeEmployee()]
        let vm = AnalyticsViewModel(service: mock)

        await vm.load()

        #expect(vm.hoursByDayOfWeek.count == 2)
        let mon = vm.hoursByDayOfWeek.first { $0.dayName == "Mon" }
        #expect(mon?.totalHours == 14.0)
        #expect(mon?.shiftCount == 2)
        let fri = vm.hoursByDayOfWeek.first { $0.dayName == "Fri" }
        #expect(fri?.totalHours == 4.0)
        // Sorted by day index
        #expect(vm.hoursByDayOfWeek.first?.dayName == "Mon")
    }

    @Test func sortOrderChangesEmployeeOrder() async {
        let mock = MockAutorotaService()
        mock.stubbedAllShiftHistory = [
            makeRecord(employeeId: 1, employeeName: "Zara", durationHours: 4, shiftCost: 100),
            makeRecord(employeeId: 2, employeeName: "Alice", durationHours: 10, shiftCost: 50),
        ]
        mock.stubbedEmployees = [makeEmployee(id: 1, first: "Zara"), makeEmployee(id: 2, first: "Alice")]
        let vm = AnalyticsViewModel(service: mock)

        await vm.load()

        // Default sort is hours (descending)
        #expect(vm.employeeSummaries.first?.name == "Alice")

        vm.employeeSortOrder = .name
        #expect(vm.employeeSummaries.first?.name == "Alice") // A before Z

        vm.employeeSortOrder = .earnings
        #expect(vm.employeeSummaries.first?.name == "Zara") // 100 > 50
    }

    @Test func loadErrorSetsErrorMessage() async {
        let mock = MockAutorotaService()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network fail"])
        let vm = AnalyticsViewModel(service: mock)

        await vm.load()

        #expect(vm.error == "network fail")
        #expect(vm.employeeSummaries.isEmpty)
        #expect(vm.totalHours == 0)
    }

    @Test func emptyDataShowsZeros() async {
        let mock = MockAutorotaService()
        mock.stubbedAllShiftHistory = []
        mock.stubbedEmployees = []
        let vm = AnalyticsViewModel(service: mock)

        await vm.load()

        #expect(vm.totalHours == 0)
        #expect(vm.totalCost == 0)
        #expect(vm.employeeCount == 0)
        #expect(vm.avgHoursPerEmployee == 0)
        #expect(vm.employeeSummaries.isEmpty)
        #expect(vm.hoursByRole.isEmpty)
        #expect(vm.weeklyTrends.isEmpty)
    }

    @Test func datePresetComputesCorrectRange() {
        let vm = AnalyticsViewModel(service: MockAutorotaService())

        vm.selectedPreset = .thisWeek
        let (weekStart, weekEnd) = vm.effectiveDateRange()
        // Should be a 7-day span (Monday to Sunday)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let start = fmt.date(from: weekStart)!
        let end = fmt.date(from: weekEnd)!
        let days = Calendar(identifier: .iso8601).dateComponents([.day], from: start, to: end).day!
        #expect(days == 6) // Monday to Sunday = 6 days difference

        vm.selectedPreset = .thisMonth
        let (monthStart, monthEnd) = vm.effectiveDateRange()
        // Month start should be day 01
        #expect(monthStart.hasSuffix("-01"))
        // Month end should be in the same month
        #expect(monthStart.prefix(7) == monthEnd.prefix(7))

        vm.selectedPreset = .thisQuarter
        let (qStart, _) = vm.effectiveDateRange()
        // Quarter start month should be 01, 04, 07, or 10
        let qMonth = Int(qStart.split(separator: "-")[1])!
        #expect([1, 4, 7, 10].contains(qMonth))
    }

    @Test func targetWeeklyHoursPopulatedFromEmployeeList() async {
        let mock = MockAutorotaService()
        mock.stubbedAllShiftHistory = [
            makeRecord(employeeId: 1, employeeName: "Alice", durationHours: 8),
        ]
        mock.stubbedEmployees = [makeEmployee(id: 1, targetHours: 25)]
        let vm = AnalyticsViewModel(service: mock)

        await vm.load()

        let alice = vm.employeeSummaries.first { $0.id == 1 }
        #expect(alice?.targetWeeklyHours == 25)
    }
}
