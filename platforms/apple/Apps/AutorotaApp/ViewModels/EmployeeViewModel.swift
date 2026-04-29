import Foundation
import Observation
import AutorotaKit
import TipKit

@Observable
final class EmployeeViewModel {

    var employees: [FfiEmployee] = []
    var isLoading = false
    var error: String?

    let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
        self.service = service
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            employees = try await service.listEmployees()
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
    }

    func create(_ employee: FfiEmployee) async {
        do {
            _ = try await service.createEmployee(employee)
            await load()
            await AutorotaEvents.firstEmployeeAdded.donate()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func update(_ employee: FfiEmployee) async {
        do {
            try await service.updateEmployee(employee)
            await load()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func delete(id: Int64) async {
        do {
            try await service.deleteEmployee(id: id)
            await load()
        } catch {
            self.error = userFacingMessage(error)
        }
    }
}
