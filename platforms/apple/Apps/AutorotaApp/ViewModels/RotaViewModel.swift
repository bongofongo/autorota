import Foundation
import Observation
import AutorotaKit

@Observable
final class RotaViewModel {

    var schedule: FfiWeekSchedule?
    var isLoading = false
    var isScheduling = false
    var error: String?
    var warnings: [FfiShortfallWarning] = []

    var selectedWeekStart: String = currentWeekStart()

    func loadSchedule() async {
        isLoading = true
        error = nil
        do {
            schedule = try await getWeekScheduleAsync(weekStart: selectedWeekStart)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func runSchedule() async {
        isScheduling = true
        error = nil
        warnings = []
        do {
            let result = try await runScheduleAsync(weekStart: selectedWeekStart)
            warnings = result.warnings
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
        isScheduling = false
    }

    func finalizeRota() async {
        guard let rotaId = schedule?.rotaId else { return }
        do {
            try await finalizeRotaAsync(id: rotaId)
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func confirmAssignment(id: Int64) async {
        do {
            try await updateAssignmentStatusAsync(id: id, status: "Confirmed")
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteAssignment(id: Int64) async {
        do {
            try await deleteAssignmentAsync(id: id)
            await loadSchedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // Derived helpers

    /// Shifts grouped by weekday for display.
    var shiftsByDay: [(weekday: String, shifts: [FfiShiftInfo])] {
        guard let schedule else { return [] }
        let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let grouped = Dictionary(grouping: schedule.shifts, by: \.weekday)
        return order.compactMap { day in
            guard let shifts = grouped[day], !shifts.isEmpty else { return nil }
            return (weekday: day, shifts: shifts.sorted { $0.startTime < $1.startTime })
        }
    }

    /// Assignments for a specific shift.
    func assignments(for shiftId: Int64) -> [FfiScheduleEntry] {
        schedule?.entries.filter { $0.shiftId == shiftId } ?? []
    }
}
