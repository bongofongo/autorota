import Foundation
import Observation
import AutorotaKit

@Observable
final class EmployeeViewModel {

    var employees: [FfiEmployee] = []
    var isLoading = false
    var error: String?

    func load() async {
        isLoading = true
        error = nil
        do {
            employees = try await listEmployeesAsync()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func create(_ employee: FfiEmployee) async {
        do {
            _ = try await createEmployeeAsync(employee)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func update(_ employee: FfiEmployee) async {
        do {
            try await updateEmployeeAsync(employee)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(id: Int64) async {
        do {
            try await deleteEmployeeAsync(id: id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
