import Foundation
import AutorotaKit

@Observable
final class RoleViewModel {

    var roles: [FfiRole] = []
    var isLoading = false
    var hasLoaded = false
    var error: String?

    private let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
        self.service = service
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            roles = try await service.listRoles()
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    func create(name: String) async {
        do {
            _ = try await service.createRole(name: name)
            await load()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func update(id: Int64, name: String) async {
        do {
            try await service.updateRole(id: id, name: name)
            await load()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func delete(id: Int64) async {
        do {
            try await service.deleteRole(id: id)
            await load()
        } catch {
            self.error = userFacingMessage(error)
        }
    }
}
