import AutorotaKit
import Foundation
import Observation

extension Notification.Name {
    /// Posted by `ExportSheetView` after a schedule export succeeds. Exports
    /// are reads, so `.autorotaDataChanged` never fires for them — the demo
    /// tour's PDF step listens for this instead.
    static let autorotaExportCompleted = Notification.Name("autorotaExportCompleted")
}

/// One step of the guided demo tour.
struct DemoStep: Identifiable, Equatable {
    enum ID: String, CaseIterable {
        case meetCrew
        case setAvailability
        case createException
        case generateRota
        case alterRota
        case exportPDF
    }

    enum State: Equatable {
        case pending
        case done
        case skipped
    }

    let id: ID
    var state: State = .pending

    var titleKey: String { "demo.step.\(id.rawValue).title" }
    var instructionKey: String { "demo.step.\(id.rawValue).instruction" }
    /// Info-only steps have no completion signal; the banner shows a
    /// "Next" button instead of waiting for a data change.
    var isManualAdvance: Bool { id == .meetCrew }
}

/// Drives demo mode: swaps the app onto a throwaway seeded database, pauses
/// iCloud sync, lifts the license gate, and walks a step checklist that
/// auto-advances by observing `.autorotaDataChanged` / `.autorotaExportCompleted`.
///
/// The FFI + sync operations are injected as closures so unit tests can run
/// the step engine against `MockAutorotaService` without an XCFramework.
@MainActor
@Observable
final class DemoModeController {
    /// Seams for everything that touches the real world. Production wiring
    /// in `.live(syncEngine:)`; tests replace members freely.
    struct Environment {
        var switchDb: (String) throws -> Void
        var seedDemoDb: (String) throws -> Void
        var demoDBPath: () throws -> String
        var realDBPath: () throws -> String
        var removeDemoFiles: () -> Void
        var pauseSync: () -> Bool          // returns whether sync was running
        var resumeSync: () async -> Void
        var setGateDemoActive: (Bool) -> Void
        var tourWeekStart: () -> String    // Monday the tour centres on

        static func live(syncEngine: AutorotaSyncEngine) -> Environment {
            Environment(
                switchDb: { try autorotaSwitchDb(to: $0) },
                seedDemoDb: { try autorotaSeedDemoDb(weekStart: $0) },
                demoDBPath: { try autorotaDemoDBURL().path },
                realDBPath: { try autorotaDefaultDBURL().path },
                removeDemoFiles: { DemoModeController.removeDemoDatabaseFiles() },
                pauseSync: {
                    let wasRunning = syncEngine.isRunning
                    syncEngine.stop()
                    return wasRunning
                },
                resumeSync: { await syncEngine.start() },
                setGateDemoActive: { LicenseGate.shared.setDemoActive($0) },
                tourWeekStart: { weekStart(weeksFromNow: 1) }
            )
        }
    }

    private(set) var isActive = false
    private(set) var steps: [DemoStep] = DemoStep.ID.allCases.map { DemoStep(id: $0) }
    /// True once every step is done/skipped; drives the completion card.
    private(set) var isComplete = false
    /// Set when enter/exit hits an FFI error; surfaced as an alert.
    var lastError: String?

    /// Monday (yyyy-MM-dd) the tour centres on. Fixed at demo entry.
    private(set) var tourWeek: String = ""

    private let env: Environment
    private let service: AutorotaServiceProtocol
    private var dataObserver: NSObjectProtocol?
    private var exportObserver: NSObjectProtocol?
    /// Row IDs of the demo employees the predicates track, found by nickname
    /// after seeding.
    private var mercuryId: Int64?
    private var marsId: Int64?
    /// Exception override IDs present right after seeding (Neptune's), so the
    /// create-exception predicate only counts user-created rows.
    private var seededExceptionIds: Set<Int64> = []

    init(
        environment: Environment,
        service: AutorotaServiceProtocol? = nil
    ) {
        self.env = environment
        self.service = service ?? GatedAutorotaService()
    }

    var currentStep: DemoStep? {
        steps.first { $0.state == .pending }
    }

    var completedCount: Int {
        steps.filter { $0.state != .pending }.count
    }

    // MARK: - Enter / exit

    func enterDemo() {
        guard !isActive else { return }
        do {
            let wasSyncRunning = env.pauseSync()
            wasSyncRunningBeforeDemo = wasSyncRunning
            env.removeDemoFiles()
            try env.switchDb(env.demoDBPath())
            tourWeek = env.tourWeekStart()
            try env.seedDemoDb(tourWeek)
            env.setGateDemoActive(true)
            resetSteps()
            isActive = true
            startObserving()
            Task { await captureSeededBaseline() }
            // Payload-less post = "reload everything": every ViewModel
            // refetches from the freshly seeded demo pool.
            NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        } catch {
            // Entering failed partway — put the app back on the real DB.
            lastError = error.localizedDescription
            try? env.switchDb((try? env.realDBPath()) ?? "")
            env.setGateDemoActive(false)
            if wasSyncRunningBeforeDemo {
                Task { await env.resumeSync() }
            }
        }
    }

    func exitDemo() {
        guard isActive else { return }
        stopObserving()
        do {
            try env.switchDb(env.realDBPath())
        } catch {
            // The old pool is closed even when connect fails, so surface the
            // error; the recovery path is an app relaunch (boots real DB).
            lastError = error.localizedDescription
        }
        env.setGateDemoActive(false)
        isActive = false
        isComplete = false
        if wasSyncRunningBeforeDemo {
            Task { await env.resumeSync() }
        }
        NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
        env.removeDemoFiles()
    }

    /// Delete the demo database (and WAL/SHM siblings). Called on demo exit
    /// and from app launch so a mid-demo crash never leaves a stale file.
    static func removeDemoDatabaseFiles() {
        guard let base = try? autorotaDemoDBURL() else { return }
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: base.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Step engine

    func skipCurrentStep() {
        guard let step = currentStep else { return }
        setState(.skipped, for: step.id)
    }

    func advanceManualStep() {
        guard let step = currentStep, step.isManualAdvance else { return }
        setState(.done, for: step.id)
    }

    func restartTour() {
        resetSteps()
        isComplete = false
    }

    private var wasSyncRunningBeforeDemo = false

    private func resetSteps() {
        steps = DemoStep.ID.allCases.map { DemoStep(id: $0) }
    }

    private func setState(_ state: DemoStep.State, for id: DemoStep.ID) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].state = state
        if currentStep == nil {
            isComplete = true
        }
    }

    private func startObserving() {
        dataObserver = NotificationCenter.default.addObserver(
            forName: .autorotaDataChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let tables = note.autorotaDataChange?.tables
            Task { @MainActor [weak self] in
                await self?.evaluateCurrentStep(changedTables: tables)
            }
        }
        exportObserver = NotificationCenter.default.addObserver(
            forName: .autorotaExportCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive,
                      self.currentStep?.id == .exportPDF else { return }
                self.setState(.done, for: .exportPDF)
            }
        }
    }

    private func stopObserving() {
        if let o = dataObserver { NotificationCenter.default.removeObserver(o) }
        if let o = exportObserver { NotificationCenter.default.removeObserver(o) }
        dataObserver = nil
        exportObserver = nil
    }

    /// Record the freshly seeded state the predicates compare against:
    /// employee row IDs by nickname and Neptune's pre-seeded exception IDs.
    /// Internal (not private) so tests can await it deterministically.
    func captureSeededBaseline() async {
        do {
            let employees = try await service.listEmployees()
            mercuryId = employees.first { $0.nickname == "Mercury" }?.id
            marsId = employees.first { $0.nickname == "Mars" }?.id
            let overrides = try await service.listAllEmployeeAvailabilityOverrides()
            seededExceptionIds = Set(
                overrides.filter { $0.source == "exception" }.map(\.id)
            )
        } catch {
            // Predicates degrade gracefully: a nil ID means the availability
            // and exception steps fall back to "any matching row".
        }
    }

    /// Internal (not private) so tests can drive the step engine directly
    /// without racing the notification-spawned Tasks.
    func evaluateCurrentStep(changedTables: Set<AutorotaDataChange.Table>?) async {
        guard isActive, !isComplete, let step = currentStep else { return }

        // A nil table set is a full-reload post (e.g. our own enter/exit
        // notifications) — never treat it as step progress.
        guard let tables = changedTables else { return }

        switch step.id {
        case .meetCrew:
            break // manual advance only

        case .setAvailability:
            guard tables.contains(.employeeAvailabilityOverride) || tables.contains(.employee)
            else { return }
            if await mercuryHasAvailability() {
                setState(.done, for: .setAvailability)
            }

        case .createException:
            guard tables.contains(.employeeAvailabilityOverride) else { return }
            if await userCreatedException() {
                setState(.done, for: .createException)
            }

        case .generateRota:
            guard !tables.isDisjoint(with: [.rota, .assignment, .shift]) else { return }
            if await tourWeekHasAssignments() {
                setState(.done, for: .generateRota)
            }

        case .alterRota:
            // Any assignment mutation after the rota exists counts — swap,
            // move, add, or delete. Event-based; no query needed.
            guard tables.contains(.assignment) else { return }
            setState(.done, for: .alterRota)

        case .exportPDF:
            break // completes via .autorotaExportCompleted
        }
    }

    // MARK: - Predicates

    private func mercuryHasAvailability() async -> Bool {
        do {
            if let id = mercuryId {
                let rows = try await service.listEmployeeAvailabilityOverrides(employeeId: id)
                if !rows.isEmpty { return true }
                // The user may have filled the default weekly grid instead of
                // the per-date editor — check the employee record too.
                let employees = try await service.listEmployees()
                return employees.first { $0.id == id }.map { !$0.defaultAvailability.isEmpty } ?? false
            }
            // Fallback: any new override at all.
            let all = try await service.listAllEmployeeAvailabilityOverrides()
            return all.contains { !seededExceptionIds.contains($0.id) }
        } catch {
            return false
        }
    }

    private func userCreatedException() async -> Bool {
        do {
            let all = try await service.listAllEmployeeAvailabilityOverrides()
            let userExceptions = all.filter {
                $0.source == "exception" && !seededExceptionIds.contains($0.id)
            }
            if let id = marsId {
                return userExceptions.contains { $0.employeeId == id }
            }
            return !userExceptions.isEmpty
        } catch {
            return false
        }
    }

    private func tourWeekHasAssignments() async -> Bool {
        do {
            guard let schedule = try await service.getWeekSchedule(weekStart: tourWeek) else {
                return false
            }
            return !schedule.entries.isEmpty
        } catch {
            return false
        }
    }
}
