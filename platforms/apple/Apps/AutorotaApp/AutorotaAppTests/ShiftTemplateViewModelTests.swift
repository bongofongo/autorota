import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("ShiftTemplateViewModel")
struct ShiftTemplateViewModelTests {

    private func makeTemplate(id: Int64 = 1, name: String = "Morning") -> FfiShiftTemplate {
        FfiShiftTemplate(
            id: id, name: name, weekdays: ["Mon", "Tue", "Wed"],
            startTime: "07:00", endTime: "12:00", requiredRole: "Barista",
            minEmployees: 1, maxEmployees: 2, deleted: false
        )
    }

    @Test func loadSetsTemplates() async {
        let mock = MockAutorotaService()
        mock.stubbedShiftTemplates = [makeTemplate(id: 1), makeTemplate(id: 2, name: "Evening")]
        let vm = ShiftTemplateViewModel(service: mock)

        await vm.load()

        #expect(vm.templates.count == 2)
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
    }

    @Test func loadErrorSetsErrorString() async {
        let mock = MockAutorotaService()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad"])
        let vm = ShiftTemplateViewModel(service: mock)

        await vm.load()

        #expect(vm.error == "bad")
        #expect(vm.templates.isEmpty)
    }

    @Test func createCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedShiftTemplates = [makeTemplate()]
        let vm = ShiftTemplateViewModel(service: mock)

        await vm.create(makeTemplate())

        #expect(mock.callLog.first == "createShiftTemplate:Morning")
        #expect(mock.callLog.contains("listShiftTemplates"))
    }

    @Test func deleteCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedShiftTemplates = []
        let vm = ShiftTemplateViewModel(service: mock)

        await vm.delete(id: 7)

        #expect(mock.callLog.first == "deleteShiftTemplate:7")
        #expect(mock.callLog.contains("listShiftTemplates"))
    }

    @Test func updateCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        let t = makeTemplate(id: 3)
        mock.stubbedShiftTemplates = [t]
        let vm = ShiftTemplateViewModel(service: mock)

        await vm.update(t)

        #expect(mock.callLog.first == "updateShiftTemplate:3")
        #expect(mock.callLog.contains("listShiftTemplates"))
    }
}
