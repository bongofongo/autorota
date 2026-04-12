import Foundation
import Observation
import AutorotaKit

@Observable
final class AvailabilityProgressViewModel {

    var doneSet: Set<Int64> = []
    var isLoading = false
    var error: String?

    private let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = LiveAutorotaService()) {
        self.service = service
    }

    func load(weekStart: String) async {
        isLoading = true
        error = nil
        do {
            let rows = try await service.listAvailabilityProgress(weekStart: weekStart)
            doneSet = Set(rows.filter(\.done).map(\.employeeId))
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func markDone(employeeId: Int64, weekStart: String) async {
        doneSet.insert(employeeId)
        do {
            try await service.setAvailabilityProgress(employeeId: employeeId, weekStart: weekStart, done: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func markUndone(employeeId: Int64, weekStart: String) async {
        doneSet.remove(employeeId)
        do {
            try await service.setAvailabilityProgress(employeeId: employeeId, weekStart: weekStart, done: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func isDone(_ employeeId: Int64) -> Bool {
        doneSet.contains(employeeId)
    }

    /// Returns the index of the next not-done employee after `currentIndex`, wrapping around.
    /// Returns nil if all employees are done.
    func nextNotDoneIndex(employees: [FfiEmployee], after currentIndex: Int) -> Int? {
        let count = employees.count
        guard count > 0 else { return nil }
        for offset in 1...count {
            let idx = (currentIndex + offset) % count
            if !isDone(employees[idx].id) {
                return idx
            }
        }
        return nil
    }
}
