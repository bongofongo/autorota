import Foundation
import AutorotaKit

@Observable
final class RoleViewModel {

    var roles: [FfiRole] = []
    var isLoading = false
    var error: String?

    private let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = LiveAutorotaService()) {
        self.service = service
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            roles = try await service.listRoles()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func create(name: String) async {
        do {
            _ = try await service.createRole(name: name)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func update(id: Int64, name: String) async {
        do {
            try await service.updateRole(id: id, name: name)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(id: Int64) async {
        do {
            try await service.deleteRole(id: id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
