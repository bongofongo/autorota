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
        case createShift
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

/// One pointed action within a guided step. The spotlight overlay walks
/// these in order; the parent step's data-change predicate stays the source
/// of truth for step completion.
enum DemoSubStepID: String {
    // setAvailability (openEmployeesTab is shared with meetCrew)
    case openEmployeesTab
    case openMercury
    case tapPencil
    case cycleCell
    case toggleLassoOn
    case lassoBlock
    case bulkApply
    case toggleLassoOff
    case tapAvailabilityDone
    // createException
    case openMars
    case scrollToException
    case tapAddException
    // createShift
    case openShiftsTab
    case shiftPurpose
    case tapAddShift
    case roleStaffing
    // generateRota
    case openRotaTab
    case goToNextWeek
    case tapGenerate
    // alterRota
    case enterSandbox
    case alterAssignment
    case swapSecondTap
    case tapDone
    // exportPDF
    case openShare
    case customizeLayout
}

/// One row of the "how to get there" hint path shown in the checklist
/// sheet. Mirrors the current step's sub-sequence, but nav prerequisites
/// are judged against *live* app context so a user who backed out sees
/// them flip back to todo.
struct DemoHintItem: Identifiable, Equatable {
    enum State {
        case satisfied
        case current
        case todo
    }

    let sub: DemoSubStepID
    let state: State
    /// Localization key of the direction; reuses the tooltip strings.
    let instructionKey: String
    var id: String { sub.rawValue }
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
        // Defaulted so existing construction sites (tests included) opt in
        // only when they care about completion persistence.
        var loadDemoEverCompleted: () -> Bool = {
            UserDefaults.standard.bool(forKey: DemoModeController.demoEverCompletedKey)
        }
        var persistDemoEverCompleted: () -> Void = {
            UserDefaults.standard.set(true, forKey: DemoModeController.demoEverCompletedKey)
        }

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

    /// UserDefaults key marking that a demo tour finished at least once.
    static let demoEverCompletedKey = "demoEverCompleted"

    private(set) var isActive = false
    private(set) var steps: [DemoStep] = DemoStep.ID.allCases.map { DemoStep(id: $0) }
    /// True once every step is done/skipped; drives the completion card.
    private(set) var isComplete = false
    /// A tour has been finished at least once, ever (persisted). Moves the
    /// demo entry point from the Menu landing to the Help page, relabeled
    /// "Replay Demo".
    private(set) var hasEverCompletedDemo: Bool
    /// Set when enter/exit hits an FFI error; surfaced as an alert.
    var lastError: String?

    /// Position within the current step's guided sub-sequence.
    private(set) var currentSubStepIndex = 0
    /// App context the sub-sequence normalizes against, so a step never
    /// points at a navigation the user has already performed. Also read by
    /// the spotlight host to hide page-bound guidance on the wrong tab.
    private(set) var currentTab: TabPage?
    private var isSandboxActive = false
    private var isOnTourWeek = false
    /// An employee detail page is on screen. The create-shift guidance
    /// waits until the user backs out to the Employees list before its
    /// first prompt appears.
    private var isEmployeeDetailOpen = false
    /// Nickname on the open employee detail page; feeds the hint path's
    /// live checks for the open-Mercury / open-Mars prerequisites.
    private(set) var openEmployeeNickname: String?
    /// The availability grid is in inline edit mode (pencil tapped).
    private(set) var isGridEditing = false
    /// Sub-steps dismissed via the tooltip's Skip button. Their action was
    /// never observed, so the hint path keeps showing them as todo instead
    /// of pretending they happened.
    private var skippedSubs: Set<DemoSubStepID> = []
    /// An assignment was mutated while `alterRota` was current — the step
    /// completes once the user leaves sandbox mode (teaching Done/auto-save),
    /// or immediately if the mutation happened outside sandbox mode.
    private var assignmentAlteredDuringStep = false
    /// "Finish Demo" was tapped in the export sheet; the export step
    /// completes once the sheet has fully dismissed (RotaView's onDismiss)
    /// so the completion card never races the dismissal transition.
    private var pendingExportFinish = false

    /// Monday (yyyy-MM-dd) the tour centres on. Fixed at demo entry.
    private(set) var tourWeek: String = ""

    private let env: Environment
    private let service: AutorotaServiceProtocol
    private var dataObserver: NSObjectProtocol?
    private var exportObserver: NSObjectProtocol?
    private var tutorialObserver: NSObjectProtocol?
    /// Row IDs of the demo employees the predicates track, found by nickname
    /// after seeding.
    private var mercuryId: Int64?
    private var marsId: Int64?
    /// Exception override IDs present right after seeding (Neptune's), so the
    /// create-exception predicate only counts user-created rows.
    private var seededExceptionIds: Set<Int64> = []
    /// Shift templates present right after seeding, so the create-shift
    /// predicate only counts a template the user added.
    private var seededTemplateCount = 0

    init(
        environment: Environment,
        service: AutorotaServiceProtocol? = nil
    ) {
        self.env = environment
        self.service = service ?? GatedAutorotaService()
        self.hasEverCompletedDemo = environment.loadDemoEverCompleted()
    }

    var currentStep: DemoStep? {
        steps.first { $0.state == .pending }
    }

    var completedCount: Int {
        steps.filter { $0.state != .pending }.count
    }

    /// The spotlight the overlay should render, or nil when the current
    /// step has no (remaining) guided sub-steps.
    var currentSpotlight: DemoSpotlight? {
        guard isActive, !isComplete, let step = currentStep else { return nil }
        // The shift tips wait until the user has backed out of the employee
        // detail page (where the exception step ends) to the main list.
        if step.id == .createShift, isEmployeeDetailOpen { return nil }
        let subs = Self.subSteps(for: step.id)
        guard currentSubStepIndex < subs.count else { return nil }
        let sub = subs[currentSubStepIndex]
        return DemoSpotlight(
            target: Self.target(for: sub),
            instructionKey: "demo.sub.\(step.id.rawValue).\(sub.rawValue)",
            index: currentSubStepIndex + 1,
            total: subs.count,
            isInfo: sub == .shiftPurpose
        )
    }

    // MARK: - Hint path

    /// "How to get there" directions for the current step, judged against
    /// live app context: nav prerequisites the user backed out of read as
    /// todo again, and Skip-dismissed actions never read as done. The first
    /// unsatisfied item is the one to do next.
    var hintPath: [DemoHintItem]? {
        guard isActive, !isComplete, let step = currentStep else { return nil }
        let subs = Self.subSteps(for: step.id)
        var sawCurrent = false
        return subs.enumerated().map { index, sub in
            let satisfied = contextSatisfied(sub)
                ?? (index < currentSubStepIndex && !skippedSubs.contains(sub))
            let state: DemoHintItem.State
            if satisfied {
                state = .satisfied
            } else if sawCurrent {
                state = .todo
            } else {
                state = .current
                sawCurrent = true
            }
            return DemoHintItem(
                sub: sub,
                state: state,
                instructionKey: "demo.sub.\(step.id.rawValue).\(sub.rawValue)"
            )
        }
    }

    /// The next direction to follow — the hint card's headline. Nil when
    /// every item reads satisfied and the step is waiting on its data
    /// predicate (the card falls back to the step instruction).
    var currentHintItem: DemoHintItem? {
        hintPath?.first { $0.state == .current }
    }

    /// True when a step is pending but the spotlight overlay would render
    /// nothing — the sequence was skipped dry, or the target lives on a tab
    /// the user isn't on. Drives the banner's "tap for directions" nudge.
    var isGuidanceHidden: Bool {
        guard isActive, !isComplete, currentStep != nil else { return false }
        guard let spot = currentSpotlight else { return true }
        if let required = spot.target.requiredTab, required != currentTab {
            return true
        }
        return false
    }

    /// Whether live app context satisfies a navigation prerequisite; nil
    /// for action sub-steps, which are judged by sequence position instead.
    private func contextSatisfied(_ sub: DemoSubStepID) -> Bool? {
        switch sub {
        case .openEmployeesTab: return currentTab == .employees
        case .openShiftsTab:    return currentTab == .templates
        case .openRotaTab:      return currentTab == .rota
        case .openMercury:      return openEmployeeNickname == "Mercury"
        case .openMars:         return openEmployeeNickname == "Mars"
        case .tapPencil:        return isGridEditing
        case .goToNextWeek:     return isOnTourWeek
        case .enterSandbox:     return isSandboxActive
        default:                return nil
        }
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
            currentTab = nil
            isSandboxActive = false
            isOnTourWeek = false
            isEmployeeDetailOpen = false
            openEmployeeNickname = nil
            isGridEditing = false
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

    // MARK: - Guided sub-steps

    static func subSteps(for id: DemoStep.ID) -> [DemoSubStepID] {
        switch id {
        case .meetCrew:
            return [.openEmployeesTab]
        case .setAvailability:
            return [.openEmployeesTab, .openMercury, .tapPencil, .cycleCell,
                    .toggleLassoOn, .lassoBlock, .bulkApply, .toggleLassoOff,
                    .tapAvailabilityDone]
        case .createException:
            return [.openEmployeesTab, .openMars, .scrollToException, .tapAddException]
        case .createShift:
            return [.openShiftsTab, .shiftPurpose, .tapAddShift, .roleStaffing]
        case .generateRota:
            return [.openRotaTab, .goToNextWeek, .tapGenerate]
        case .alterRota:
            return [.enterSandbox, .alterAssignment, .swapSecondTap, .tapDone]
        case .exportPDF:
            return [.openRotaTab, .openShare, .customizeLayout]
        }
    }

    static func target(for sub: DemoSubStepID) -> TutorialTarget {
        switch sub {
        case .openEmployeesTab: return .employeesTab
        case .openMercury:      return .mercuryRow
        case .tapPencil:        return .availabilityPencil
        case .cycleCell, .lassoBlock, .bulkApply: return .availabilityGrid
        case .toggleLassoOn, .toggleLassoOff: return .lassoToggle
        case .tapAvailabilityDone: return .availabilityPencil
        case .openMars:         return .marsRow
        case .scrollToException: return .exceptionsScrollHint
        case .tapAddException:  return .addExceptionButton
        case .openShiftsTab:    return .shiftsTab
        case .shiftPurpose:     return .shiftPurposeHint
        case .tapAddShift:      return .addShiftButton
        case .roleStaffing:     return .shiftRoleStaffingHint
        case .openRotaTab:      return .rotaTab
        case .goToNextWeek:     return .nextWeekChevron
        case .tapGenerate:      return .generateButton
        case .enterSandbox:     return .sandboxButton
        case .alterAssignment:  return .shiftCard
        case .swapSecondTap:    return .swapSecondTap
        case .tapDone:          return .doneButton
        case .openShare:        return .shareEntry
        case .customizeLayout:  return .exportCustomize
        }
    }

    /// Feed of user actions from the views. Advances the guided sub-sequence;
    /// also keeps the navigation context fresh so future steps can skip
    /// already-satisfied sub-steps. Safe to call regardless of demo state.
    func noteTutorialEvent(_ event: TutorialEvent) {
        guard isActive else { return }

        switch event {
        case .tabSelected(let page):     currentTab = page
        case .weekChanged(let tour):     isOnTourWeek = tour
        case .sandboxEntered:            isSandboxActive = true
        case .sandboxExited:             isSandboxActive = false
        case .employeeDetailOpened(let nick):
            isEmployeeDetailOpen = true
            openEmployeeNickname = nick
        case .employeeDetailClosed:
            isEmployeeDetailOpen = false
            openEmployeeNickname = nil
            isGridEditing = false
        case .gridEditStarted:           isGridEditing = true
        case .gridEditEnded:             isGridEditing = false
        default: break
        }

        guard !isComplete, let step = currentStep else { return }

        // Reaching the Employees tab IS the meet-the-crew moment — no
        // banner Next needed (it remains as a fallback).
        if event == .tabSelected(.employees), step.id == .meetCrew {
            setState(.done, for: .meetCrew)
            return
        }

        // Leaving sandbox after altering the rota is the Done teaching
        // moment — it completes the step.
        if event == .sandboxExited, step.id == .alterRota, assignmentAlteredDuringStep {
            setState(.done, for: .alterRota)
            return
        }

        let subs = Self.subSteps(for: step.id)
        guard currentSubStepIndex < subs.count else { return }

        // Match the event against the current *or any later* sub-step, so a
        // user who skipped ahead on their own doesn't get pointed backwards.
        if let matched = (currentSubStepIndex..<subs.count).first(where: {
            Self.satisfies(event: event, sub: subs[$0])
        }) {
            currentSubStepIndex = matched + 1
            normalizeSubSteps()
            completeStepIfSequenceExhausted()
        }
    }

    /// "Finish Demo" tapped in the export sheet (demo runs never export
    /// anything real). Completion is deferred to `consumeExportStepFinish`.
    func requestExportStepFinish() {
        guard isActive else { return }
        pendingExportFinish = true
    }

    /// Called after the export sheet has fully dismissed.
    func consumeExportStepFinish() {
        guard isActive, pendingExportFinish else { return }
        pendingExportFinish = false
        if currentStep?.id == .exportPDF {
            setState(.done, for: .exportPDF)
        }
    }

    /// Tooltip "Skip" — advances past the current sub-step only.
    func skipCurrentSubStep() {
        guard isActive, let step = currentStep else { return }
        let subs = Self.subSteps(for: step.id)
        guard currentSubStepIndex < subs.count else { return }
        skippedSubs.insert(subs[currentSubStepIndex])
        currentSubStepIndex += 1
        normalizeSubSteps()
        completeStepIfSequenceExhausted()
    }

    /// setAvailability defers its data predicate until the guided sequence
    /// finishes (so everyone sees the lasso teaching). When the sequence is
    /// exhausted via events or Skips, the last data change may already have
    /// happened — re-check the predicate here to avoid a stuck step.
    private func completeStepIfSequenceExhausted() {
        guard let step = currentStep, step.id == .setAvailability,
              currentSubStepIndex >= Self.subSteps(for: .setAvailability).count
        else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isActive,
                  self.currentStep?.id == .setAvailability else { return }
            if await self.mercuryHasAvailability() {
                self.setState(.done, for: .setAvailability)
            }
        }
    }

    private static func satisfies(event: TutorialEvent, sub: DemoSubStepID) -> Bool {
        switch sub {
        case .openEmployeesTab: return event == .tabSelected(.employees)
        case .openMercury:
            if case .employeeDetailOpened(let nick) = event { return nick == "Mercury" }
            return false
        case .tapPencil:        return event == .gridEditStarted
        case .cycleCell:        return event == .cellCycled
        case .toggleLassoOn:    return event == .lassoToggledOn
        case .lassoBlock:       return event == .lassoDrawn
        case .bulkApply:        return event == .lassoApplied
        case .toggleLassoOff:   return event == .lassoToggledOff
        case .tapAvailabilityDone: return event == .gridEditEnded
        case .openMars:
            if case .employeeDetailOpened(let nick) = event { return nick == "Mars" }
            return false
        case .scrollToException:
            if case .exceptionsSectionVisible(let nick) = event { return nick == "Mars" }
            return false
        case .tapAddException:  return event == .exceptionSheetOpened
        case .openShiftsTab:    return event == .tabSelected(.templates)
        case .shiftPurpose:     return false // info-only; Next advances it
        case .tapAddShift:      return event == .addShiftSheetOpened
        case .roleStaffing:     return false // step completes via the template predicate
        case .openRotaTab:      return event == .tabSelected(.rota)
        case .goToNextWeek:     return event == .weekChanged(isTourWeek: true)
        case .tapGenerate:      return false // cleared by step completion
        case .enterSandbox:     return event == .sandboxEntered
        // The first swap tap moves guidance to the floating "tap another
        // employee" hint; non-swap edits advance via the assignment predicate.
        case .alterAssignment:  return event == .swapSourceSelected
        case .swapSecondTap:    return false // advanced by the assignment predicate
        case .tapDone:          return false // completes the step via sandboxExited
        case .openShare:        return event == .shareSheetOpened
        case .customizeLayout:  return false // step completes via .autorotaExportCompleted
        }
    }

    /// Skip sub-steps the app context already satisfies (e.g. the user is
    /// already on the Employees tab when the step begins).
    private func normalizeSubSteps() {
        guard let step = currentStep else { return }
        let subs = Self.subSteps(for: step.id)
        while currentSubStepIndex < subs.count,
              alreadySatisfied(subs[currentSubStepIndex]) {
            currentSubStepIndex += 1
        }
    }

    private func alreadySatisfied(_ sub: DemoSubStepID) -> Bool {
        switch sub {
        case .openEmployeesTab: return currentTab == .employees
        case .openRotaTab:      return currentTab == .rota
        case .openShiftsTab:    return currentTab == .templates
        case .goToNextWeek:     return isOnTourWeek
        case .enterSandbox:     return isSandboxActive
        default:                return false
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
        assignmentAlteredDuringStep = false
        skippedSubs = []
        currentSubStepIndex = 0
        normalizeSubSteps()
    }

    private func setState(_ state: DemoStep.State, for id: DemoStep.ID) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].state = state
        // The next step starts its guided sequence from the top, minus
        // anything the current app context already satisfies.
        assignmentAlteredDuringStep = false
        skippedSubs = []
        currentSubStepIndex = 0
        normalizeSubSteps()
        if currentStep == nil {
            isComplete = true
            if !hasEverCompletedDemo {
                hasEverCompletedDemo = true
                env.persistDemoEverCompleted()
            }
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
        tutorialObserver = NotificationCenter.default.addObserver(
            forName: .autorotaTutorialAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let action = note.object as? TutorialAction else { return }
            Task { @MainActor [weak self] in
                switch action {
                case .cellCycled:      self?.noteTutorialEvent(.cellCycled)
                case .lassoToggledOn:  self?.noteTutorialEvent(.lassoToggledOn)
                case .lassoDrawn:      self?.noteTutorialEvent(.lassoDrawn)
                case .lassoApplied:    self?.noteTutorialEvent(.lassoApplied)
                case .lassoToggledOff: self?.noteTutorialEvent(.lassoToggledOff)
                }
            }
        }
    }

    private func stopObserving() {
        if let o = dataObserver { NotificationCenter.default.removeObserver(o) }
        if let o = exportObserver { NotificationCenter.default.removeObserver(o) }
        if let o = tutorialObserver { NotificationCenter.default.removeObserver(o) }
        dataObserver = nil
        exportObserver = nil
        tutorialObserver = nil
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
            seededTemplateCount = try await service.listShiftTemplates().count
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
            // Don't complete mid-sequence: a single cell edit satisfies the
            // data predicate, but the lasso sub-steps still need teaching.
            guard currentSubStepIndex >= Self.subSteps(for: .setAvailability).count
            else { return }
            if await mercuryHasAvailability() {
                setState(.done, for: .setAvailability)
            }

        case .createException:
            guard tables.contains(.employeeAvailabilityOverride) else { return }
            if await userCreatedException() {
                setState(.done, for: .createException)
            }

        case .createShift:
            guard tables.contains(.shiftTemplate) else { return }
            if await userCreatedTemplate() {
                setState(.done, for: .createShift)
            }

        case .generateRota:
            guard !tables.isDisjoint(with: [.rota, .assignment, .shift]) else { return }
            if await tourWeekHasAssignments() {
                setState(.done, for: .generateRota)
            }

        case .alterRota:
            // Any assignment mutation counts — swap, move, add, or delete.
            // Inside sandbox mode the step completes when the user taps
            // Done (teaching that exiting saves); a mutation made outside
            // sandbox completes it immediately.
            guard tables.contains(.assignment) else { return }
            assignmentAlteredDuringStep = true
            if isSandboxActive {
                let subs = Self.subSteps(for: .alterRota)
                if let doneIdx = subs.firstIndex(of: .tapDone) {
                    currentSubStepIndex = max(currentSubStepIndex, doneIdx)
                }
            } else {
                setState(.done, for: .alterRota)
            }

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

    private func userCreatedTemplate() async -> Bool {
        do {
            return try await service.listShiftTemplates().count > seededTemplateCount
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
