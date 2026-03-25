import Foundation
import Observation
import AutorotaKit

@Observable
final class ShiftTemplateViewModel {

    var templates: [FfiShiftTemplate] = []
    var isLoading = false
    var error: String?

    func load() async {
        isLoading = true
        error = nil
        do {
            templates = try await listShiftTemplatesAsync()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func create(_ template: FfiShiftTemplate) async {
        do {
            _ = try await createShiftTemplateAsync(template)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func update(_ template: FfiShiftTemplate) async {
        do {
            try await updateShiftTemplateAsync(template)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(id: Int64) async {
        do {
            try await deleteShiftTemplateAsync(id: id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
