import Foundation
import Observation
import AutorotaKit

@Observable
final class ShiftTemplateViewModel {

    var templates: [FfiShiftTemplate] = []
    var isLoading = false
    var hasLoaded = false
    var error: String?

    let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = GatedAutorotaService()) {
        self.service = service
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            templates = try await service.listShiftTemplates()
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    func create(_ template: FfiShiftTemplate) async {
        do {
            _ = try await service.createShiftTemplate(template)
            await load()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func update(_ template: FfiShiftTemplate) async {
        do {
            try await service.updateShiftTemplate(template)
            await load()
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func delete(id: Int64) async {
        do {
            try await service.deleteShiftTemplate(id: id)
            await load()
        } catch {
            self.error = userFacingMessage(error)
        }
    }
}
