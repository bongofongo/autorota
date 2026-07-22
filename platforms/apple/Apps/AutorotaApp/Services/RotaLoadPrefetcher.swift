import AutorotaKit
import Foundation

/// Prefetches the current week's rota data while the boot animation plays so
/// RotaViewModel's cold load finds everything ready the frame the paint gate
/// lifts, instead of starting its four FFI calls only after it.
///
/// One-shot: the first successful `take` consumes the result. Any
/// `.autorotaDataChanged` post (e.g. a remote sync landing mid-animation)
/// invalidates the prefetch so the consumer falls back to a fresh load.
@MainActor
final class RotaLoadPrefetcher {
    static let shared = RotaLoadPrefetcher()

    struct Prefetched {
        let weekStart: String
        /// The schedule fetch keeps its error: the consumer surfaces a
        /// failure exactly as a live `loadSchedule` would. Reference data is
        /// best-effort, same as `ensureReferenceData`.
        let scheduleResult: Result<FfiWeekSchedule?, Error>
        let employees: [FfiEmployee]?
        let overrides: [FfiEmployeeAvailabilityOverride]?
        let roles: [FfiRole]?
    }

    private var task: Task<Prefetched, Never>?
    private var weekStart: String?
    private var observer: (any NSObjectProtocol)?

    func start(service: AutorotaServiceProtocol, weekStart: String) {
        guard task == nil else { return }
        self.weekStart = weekStart
        observer = NotificationCenter.default.addObserver(
            forName: .autorotaDataChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
        task = Task {
            async let schedule = service.getWeekSchedule(weekStart: weekStart)
            async let emps = service.listEmployees()
            async let overrides = service.listAllEmployeeAvailabilityOverrides()
            async let roles = service.listRoles()

            let scheduleResult: Result<FfiWeekSchedule?, Error>
            do { scheduleResult = .success(try await schedule) } catch { scheduleResult = .failure(error) }
            return Prefetched(
                weekStart: weekStart,
                scheduleResult: scheduleResult,
                employees: try? await emps,
                overrides: try? await overrides,
                roles: try? await roles
            )
        }
    }

    /// Consume the prefetched result for `weekStart`. Awaits in-flight work
    /// (a consumer arriving early waits for the remainder rather than
    /// duplicating the FFI calls); returns nil on mismatch or invalidation.
    func take(weekStart: String) async -> Prefetched? {
        guard let task, self.weekStart == weekStart else { return nil }
        let result = await task.value
        // Re-check: an invalidation may have landed while awaiting.
        guard self.weekStart == weekStart else { return nil }
        clear()
        return result
    }

    private func invalidate() {
        task?.cancel()
        clear()
    }

    private func clear() {
        task = nil
        weekStart = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
