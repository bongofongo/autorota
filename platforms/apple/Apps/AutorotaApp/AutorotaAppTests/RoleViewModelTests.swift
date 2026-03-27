import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("RoleViewModel")
struct RoleViewModelTests {

    @Test func loadSetsRoles() async {
        let mock = MockAutorotaService()
        mock.stubbedRoles = [FfiRole(id: 1, name: "Barista"), FfiRole(id: 2, name: "Manager")]
        let vm = RoleViewModel(service: mock)

        await vm.load()

        #expect(vm.roles.count == 2)
        #expect(vm.roles[0].name == "Barista")
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
    }

    @Test func loadErrorSetsErrorString() async {
        let mock = MockAutorotaService()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "oops"])
        let vm = RoleViewModel(service: mock)

        await vm.load()

        #expect(vm.error == "oops")
        #expect(vm.roles.isEmpty)
    }

    @Test func createCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedRoles = [FfiRole(id: 1, name: "Barista")]
        let vm = RoleViewModel(service: mock)

        await vm.create(name: "Barista")

        #expect(mock.callLog.first == "createRole:Barista")
        #expect(mock.callLog.contains("listRoles"))
    }

    @Test func updateCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedRoles = [FfiRole(id: 1, name: "Senior Barista")]
        let vm = RoleViewModel(service: mock)

        await vm.update(id: 1, name: "Senior Barista")

        #expect(mock.callLog.first == "updateRole:1:Senior Barista")
        #expect(mock.callLog.contains("listRoles"))
    }

    @Test func deleteCallsServiceAndReloads() async {
        let mock = MockAutorotaService()
        mock.stubbedRoles = []
        let vm = RoleViewModel(service: mock)

        await vm.delete(id: 3)

        #expect(mock.callLog.first == "deleteRole:3")
        #expect(mock.callLog.contains("listRoles"))
    }
}
