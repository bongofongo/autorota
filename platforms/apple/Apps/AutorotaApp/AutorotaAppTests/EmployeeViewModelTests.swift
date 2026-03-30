import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("EmployeeViewModel")
struct EmployeeViewModelTests {

    private func makeEmployee(id: Int64 = 1, first: String = "Alice", last: String = "Smith") -> FfiEmployee {
        FfiEmployee(
            id: id, firstName: first, lastName: last, nickname: nil,
            displayName: "\(first) \(last)", roles: ["Barista"], startDate: "2025-01-01",
            targetWeeklyHours: 20, weeklyHoursDeviation: 5, maxDailyHours: 8,
            notes: nil, bankDetails: nil, hourlyWage: nil, wageCurrency: nil, defaultAvailability: [], availability: [], deleted: false
        )
    }

    @Test func loadSetsEmployees() async {
        let mock = MockAutorotaService()
        mock.stubbedEmployees = [makeEmployee(id: 1), makeEmployee(id: 2, first: "Bob")]
        let vm = EmployeeViewModel(service: mock)

        await vm.load()

        #expect(vm.employees.count == 2)
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
        #expect(mock.callLog.contains("listEmployees"))
    }

    @Test func loadErrorSetsErrorString() async {
        let mock = MockAutorotaService()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "fail"])
        let vm = EmployeeViewModel(service: mock)

        await vm.load()

        #expect(vm.error == "fail")
        #expect(vm.employees.isEmpty)
    }

    @Test func createCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedEmployees = [makeEmployee()]
        let vm = EmployeeViewModel(service: mock)

        await vm.create(makeEmployee())

        #expect(mock.callLog.first == "createEmployee:Alice")
        #expect(mock.callLog.contains("listEmployees"))
        #expect(vm.employees.count == 1)
    }

    @Test func deleteCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedEmployees = []
        let vm = EmployeeViewModel(service: mock)

        await vm.delete(id: 42)

        #expect(mock.callLog.first == "deleteEmployee:42")
        #expect(mock.callLog.contains("listEmployees"))
    }

    @Test func updateCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        let emp = makeEmployee(id: 5)
        mock.stubbedEmployees = [emp]
        let vm = EmployeeViewModel(service: mock)

        await vm.update(emp)

        #expect(mock.callLog.first == "updateEmployee:5")
        #expect(mock.callLog.contains("listEmployees"))
    }
}
