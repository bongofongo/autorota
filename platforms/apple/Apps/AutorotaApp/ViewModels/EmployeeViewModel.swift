import Foundation
import Observation
import AutorotaKit

@Observable
final class EmployeeViewModel {

    var employees: [FfiEmployee] = []
    var isLoading = false
    var error: String?

    let service: AutorotaServiceProtocol
    private var hasLoaded = false

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
        self.service = service
    }

    /// Cold load — fetches once. Subsequent appearances are no-ops so the List
    /// isn't churned on every tab switch (the source of the Employees flicker).
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload(showSpinner: true)
    }

    /// Re-fetch employees. Reassigns `employees` only when the data actually
    /// changed so the List isn't rebuilt (and doesn't flicker) on no-op
    /// refreshes. Shows the spinner only on a genuine cold start.
    func reload(showSpinner: Bool = false) async {
        if showSpinner && employees.isEmpty { isLoading = true }
        error = nil
        do {
            let latest = try await service.listEmployees()
            if latest != employees { employees = latest }
            hasLoaded = true
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
    }

    func create(_ employee: FfiEmployee) async {
        do {
            _ = try await service.createEmployee(employee)
            await reload()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func update(_ employee: FfiEmployee) async {
        do {
            try await service.updateEmployee(employee)
            await reload()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func delete(id: Int64) async {
        do {
            try await service.deleteEmployee(id: id)
            await reload()
        } catch {
            self.error = userFacingMessage(error)
        }
    }
}
