import Foundation
import Observation
import AutorotaKit

@Observable
final class OverrideViewModel {

    var employeeAvailabilityOverrides: [FfiEmployeeAvailabilityOverride] = []
    var shiftTemplateOverrides: [FfiShiftTemplateOverride] = []
    var isLoading = false
    var error: String?

    private let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = LiveAutorotaService()) {
        self.service = service
    }

    func loadAll() async {
        isLoading = true
        error = nil
        do {
            async let empOverrides = service.listAllEmployeeAvailabilityOverrides()
            async let tmplOverrides = service.listAllShiftTemplateOverrides()
            employeeAvailabilityOverrides = try await empOverrides
            shiftTemplateOverrides = try await tmplOverrides
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
    }

    func loadForEmployee(id: Int64) async {
        isLoading = true
        error = nil
        do {
            employeeAvailabilityOverrides = try await service.listEmployeeAvailabilityOverrides(employeeId: id)
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
    }

    func upsertEmployeeOverride(_ o: FfiEmployeeAvailabilityOverride) async {
        do {
            _ = try await service.upsertEmployeeAvailabilityOverride(o)
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func deleteEmployeeOverride(id: Int64) async {
        do {
            try await service.deleteEmployeeAvailabilityOverride(id: id)
            employeeAvailabilityOverrides.removeAll { $0.id == id }
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func upsertTemplateOverride(_ o: FfiShiftTemplateOverride) async {
        do {
            _ = try await service.upsertShiftTemplateOverride(o)
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    func deleteTemplateOverride(id: Int64) async {
        do {
            try await service.deleteShiftTemplateOverride(id: id)
            shiftTemplateOverrides.removeAll { $0.id == id }
        } catch {
            self.error = userFacingMessage(error)
        }
    }
}
