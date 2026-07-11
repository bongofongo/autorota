import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("DemoModeController")
@MainActor
struct DemoModeControllerTests {

    // MARK: - Fixtures

    /// Environment whose closures record ordering and never touch FFI/CloudKit.
    private final class EnvRecorder {
        var log: [String] = []
        var syncWasRunning = true
        var switchError: Error?
        var demoEverCompleted = false

        func environment() -> DemoModeController.Environment {
            DemoModeController.Environment(
                switchDb: { [self] path in
                    if let e = switchError { throw e }
                    log.append("switchDb:\(path)")
                },
                seedDemoDb: { [self] week in log.append("seed:\(week)") },
                demoDBPath: { "/tmp/demo.sqlite" },
                realDBPath: { "/tmp/real.sqlite" },
                removeDemoFiles: { [self] in log.append("removeFiles") },
                pauseSync: { [self] in
                    log.append("pauseSync")
                    return syncWasRunning
                },
                resumeSync: { [self] in log.append("resumeSync") },
                setGateDemoActive: { [self] in log.append("gate:\($0)") },
                tourWeekStart: { "2099-04-20" },
                loadDemoEverCompleted: { [self] in demoEverCompleted },
                persistDemoEverCompleted: { [self] in
                    demoEverCompleted = true
                    log.append("persistCompleted")
                }
            )
        }
    }

    private func makeEmployee(id: Int64, nickname: String) -> FfiEmployee {
        FfiEmployee(
            id: id, firstName: "First\(id)", lastName: "Last\(id)", nickname: nickname,
            displayName: nickname, roles: ["Barista"], startDate: "2025-01-06",
            targetWeeklyHours: 20, weeklyHoursDeviation: 5, maxDailyHours: 8,
            notes: nil, bankDetails: nil, phone: nil, email: nil, preferredContact: nil,
            hourlyWage: nil, wageCurrency: nil, defaultAvailability: [], availability: [],
            deleted: false
        )
    }

    private func makeOverride(
        id: Int64, employeeId: Int64, source: String
    ) -> FfiEmployeeAvailabilityOverride {
        FfiEmployeeAvailabilityOverride(
            id: id, employeeId: employeeId, date: "2099-04-22",
            availability: [], notes: nil, source: source
        )
    }

    private func seededMock() -> MockAutorotaService {
        let mock = MockAutorotaService()
        mock.stubbedEmployees = [
            makeEmployee(id: 1, nickname: "Mercury"),
            makeEmployee(id: 4, nickname: "Mars"),
            makeEmployee(id: 8, nickname: "Neptune"),
        ]
        // Neptune's two pre-seeded exceptions.
        mock.stubbedAvailabilityOverrides = [
            makeOverride(id: 100, employeeId: 8, source: "exception"),
            makeOverride(id: 101, employeeId: 8, source: "exception"),
        ]
        return mock
    }

    private func makeController(
        env: EnvRecorder, mock: MockAutorotaService
    ) -> DemoModeController {
        DemoModeController(environment: env.environment(), service: mock)
    }

    /// Skip steps until `id` is current (bounded so a regression can't hang).
    private func skip(_ controller: DemoModeController, to id: DemoStep.ID) {
        for _ in 0..<DemoStep.ID.allCases.count {
            if controller.currentStep?.id == id || controller.currentStep == nil { break }
            controller.skipCurrentStep()
        }
    }

    /// Skip every remaining step.
    private func skipAll(_ controller: DemoModeController) {
        for _ in 0..<DemoStep.ID.allCases.count {
            if controller.currentStep == nil { break }
            controller.skipCurrentStep()
        }
    }

    // MARK: - Enter / exit ordering

    @Test func enterPausesSyncBeforeSwitchingAndSeeds() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())

        controller.enterDemo()

        #expect(controller.isActive)
        #expect(env.log.prefix(5) == [
            "pauseSync",
            "removeFiles",
            "switchDb:/tmp/demo.sqlite",
            "seed:2099-04-20",
            "gate:true",
        ])
        #expect(controller.tourWeek == "2099-04-20")
    }

    @Test func exitSwitchesBackClearsGateAndResumesSync() async {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        env.log.removeAll()

        controller.exitDemo()
        // resumeSync runs in a Task; yield so it lands in the log.
        await Task.yield()
        await Task.yield()

        #expect(!controller.isActive)
        #expect(env.log.contains("switchDb:/tmp/real.sqlite"))
        #expect(env.log.contains("gate:false"))
        #expect(env.log.contains("resumeSync"))
        #expect(env.log.contains("removeFiles"))
        // Gate cleared and DB switched before sync resumes.
        #expect(env.log.firstIndex(of: "switchDb:/tmp/real.sqlite")!
                < env.log.firstIndex(of: "resumeSync")!)
    }

    @Test func exitDoesNotResumeSyncWhenItWasNotRunning() async {
        let env = EnvRecorder()
        env.syncWasRunning = false
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        env.log.removeAll()

        controller.exitDemo()
        await Task.yield()
        await Task.yield()

        #expect(!env.log.contains("resumeSync"))
    }

    @Test func failedEnterRollsBackToRealDB() {
        let env = EnvRecorder()
        env.switchError = NSError(domain: "test", code: 1)
        let controller = makeController(env: env, mock: seededMock())

        controller.enterDemo()

        #expect(!controller.isActive)
        #expect(controller.lastError != nil)
        #expect(env.log.contains("gate:false"))
    }

    // MARK: - Step engine

    @Test func stepsStartPendingWithMeetCrewCurrent() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()

        #expect(controller.currentStep?.id == .meetCrew)
        #expect(controller.completedCount == 0)
        #expect(!controller.isComplete)
    }

    @Test func manualAdvanceCompletesMeetCrew() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()

        controller.advanceManualStep()

        #expect(controller.currentStep?.id == .setAvailability)
        #expect(controller.completedCount == 1)
    }

    @Test func availabilityStepWaitsForLassoSubStepsBeforeCompleting() async {
        let env = EnvRecorder()
        let mock = seededMock()
        let controller = makeController(env: env, mock: mock)
        controller.enterDemo()
        await controller.captureSeededBaseline()
        controller.advanceManualStep()

        // Unrelated table change does nothing.
        await controller.evaluateCurrentStep(changedTables: [.role])
        #expect(controller.currentStep?.id == .setAvailability)

        // Mercury (id 1) gets a manual per-date override — but the guided
        // sequence hasn't reached the lasso teaching yet, so the step must
        // NOT complete.
        mock.stubbedAvailabilityOverrides.append(
            makeOverride(id: 200, employeeId: 1, source: "manual")
        )
        controller.noteTutorialEvent(.cellCycled)
        await controller.evaluateCurrentStep(changedTables: [.employeeAvailabilityOverride])
        #expect(controller.currentStep?.id == .setAvailability)
        #expect(controller.currentSpotlight?.instructionKey
                == "demo.sub.setAvailability.toggleLassoOn")

        // Finishing the lasso sub-steps and closing the grid editor lets
        // the step complete.
        controller.noteTutorialEvent(.lassoDrawn)
        controller.noteTutorialEvent(.lassoApplied)
        await controller.evaluateCurrentStep(changedTables: [.employeeAvailabilityOverride])
        #expect(controller.currentStep?.id == .setAvailability) // checkmark still pending

        controller.noteTutorialEvent(.gridEditEnded)
        for _ in 0..<50 where controller.currentStep?.id == .setAvailability {
            await Task.yield()
        }
        #expect(controller.currentStep?.id == .createException)
    }

    @Test func skippingRemainingSubStepsCompletesSatisfiedAvailabilityStep() async {
        let env = EnvRecorder()
        let mock = seededMock()
        let controller = makeController(env: env, mock: mock)
        controller.enterDemo()
        await controller.captureSeededBaseline()
        controller.advanceManualStep()

        // Predicate already satisfied; the last data change has passed.
        mock.stubbedAvailabilityOverrides.append(
            makeOverride(id: 200, employeeId: 1, source: "manual")
        )
        await controller.evaluateCurrentStep(changedTables: [.employeeAvailabilityOverride])
        #expect(controller.currentStep?.id == .setAvailability)

        // Skipping through the rest of the sequence must still complete the
        // step (deadlock guard re-checks the predicate asynchronously).
        let subCount = DemoModeController.subSteps(for: .setAvailability).count
        for _ in 0..<subCount { controller.skipCurrentSubStep() }
        for _ in 0..<50 where controller.currentStep?.id == .setAvailability {
            await Task.yield()
        }
        #expect(controller.currentStep?.id == .createException)
    }

    @Test func exceptionStepIgnoresSeededExceptionsAndWrongEmployee() async {
        let env = EnvRecorder()
        let mock = seededMock()
        let controller = makeController(env: env, mock: mock)
        controller.enterDemo()
        await controller.captureSeededBaseline()
        controller.advanceManualStep()
        controller.skipCurrentStep() // skip availability -> on createException

        // Neptune's seeded exceptions must not complete the step.
        await controller.evaluateCurrentStep(changedTables: [.employeeAvailabilityOverride])
        #expect(controller.currentStep?.id == .createException)

        // An exception for someone other than Mars doesn't count either.
        mock.stubbedAvailabilityOverrides.append(
            makeOverride(id: 300, employeeId: 8, source: "exception")
        )
        await controller.evaluateCurrentStep(changedTables: [.employeeAvailabilityOverride])
        #expect(controller.currentStep?.id == .createException)

        // Mars (id 4) gets his day off.
        mock.stubbedAvailabilityOverrides.append(
            makeOverride(id: 301, employeeId: 4, source: "exception")
        )
        await controller.evaluateCurrentStep(changedTables: [.employeeAvailabilityOverride])
        #expect(controller.currentStep?.id == .createShift)
    }

    @Test func shiftTipsWaitUntilEmployeeDetailCloses() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep()
        // The exception step typically completes while Mars's detail page
        // is still on screen.
        controller.noteTutorialEvent(.employeeDetailOpened(nickname: "Mars"))
        skip(controller, to: .createShift)

        #expect(controller.currentStep?.id == .createShift)
        #expect(controller.currentSpotlight == nil)

        // Backing out to the Employees list releases the shift tips.
        controller.noteTutorialEvent(.employeeDetailClosed)
        #expect(controller.currentSpotlight?.target == .shiftsTab)
    }

    @Test func createShiftStepGuidesThroughPlusAndStaffing() async {
        let env = EnvRecorder()
        let mock = seededMock()
        mock.stubbedShiftTemplates = []
        let controller = makeController(env: env, mock: mock)
        controller.enterDemo()
        await controller.captureSeededBaseline()
        controller.advanceManualStep()
        skip(controller, to: .createShift)

        #expect(controller.currentSpotlight?.target == .shiftsTab)

        controller.noteTutorialEvent(.tabSelected(.templates))
        #expect(controller.currentSpotlight?.target == .shiftPurposeHint)
        #expect(controller.currentSpotlight?.isInfo == true)

        // The purpose card is info-only — Next (skip) moves on.
        controller.skipCurrentSubStep()
        #expect(controller.currentSpotlight?.target == .addShiftButton)
        #expect(controller.currentSpotlight?.isInfo == false)

        controller.noteTutorialEvent(.addShiftSheetOpened)
        #expect(controller.currentSpotlight?.target == .shiftRoleStaffingHint)

        // Saving a template that wasn't in the seed completes the step.
        mock.stubbedShiftTemplates.append(FfiShiftTemplate(
            id: 1, name: "Close", weekdays: ["Fri"], startTime: "17:00",
            endTime: "22:00", requiredRole: "", minEmployees: 1,
            maxEmployees: 2, roleRequirements: [], deleted: false
        ))
        await controller.evaluateCurrentStep(changedTables: [.shiftTemplate])
        #expect(controller.currentStep?.id == .generateRota)
    }

    @Test func generateStepNeedsAssignmentsInTourWeek() async {
        let env = EnvRecorder()
        let mock = seededMock()
        let controller = makeController(env: env, mock: mock)
        controller.enterDemo()
        await controller.captureSeededBaseline()
        controller.advanceManualStep()
        skip(controller, to: .generateRota)

        // No schedule yet.
        await controller.evaluateCurrentStep(changedTables: [.rota, .assignment])
        #expect(controller.currentStep?.id == .generateRota)

        mock.stubbedWeekSchedule = FfiWeekSchedule(
            rotaId: 1, weekStart: "2099-04-20", hasSaves: false,
            entries: [FfiScheduleEntry(
                assignmentId: 1, shiftId: 1, date: "2099-04-20", weekday: "Mon",
                startTime: "07:00", endTime: "12:00", requiredRole: "Barista",
                employeeId: 3, employeeName: "Earth", status: "Proposed",
                maxEmployees: 2
            )],
            shifts: []
        )
        await controller.evaluateCurrentStep(changedTables: [.assignment])
        #expect(controller.currentStep?.id == .alterRota)
    }

    @Test func alterStepCompletesOnAnyAssignmentChange() async {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep()
        skip(controller, to: .alterRota)

        await controller.evaluateCurrentStep(changedTables: [.save])
        #expect(controller.currentStep?.id == .alterRota)

        await controller.evaluateCurrentStep(changedTables: [.assignment])
        #expect(controller.currentStep?.id == .exportPDF)
    }

    @Test func fullReloadPostsNeverAdvanceSteps() async {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep()
        skip(controller, to: .alterRota)

        await controller.evaluateCurrentStep(changedTables: nil)
        #expect(controller.currentStep?.id == .alterRota)
    }

    @Test func completingAllStepsSetsIsComplete() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()

        controller.advanceManualStep()
        skipAll(controller)

        #expect(controller.isComplete)
        #expect(controller.currentStep == nil)
    }

    @Test func firstCompletionPersistsEverCompletedFlagOnce() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        #expect(!controller.hasEverCompletedDemo)

        controller.enterDemo()
        controller.advanceManualStep()
        skipAll(controller)

        #expect(controller.hasEverCompletedDemo)
        #expect(env.log.filter { $0 == "persistCompleted" }.count == 1)

        // A replay completing again must not re-persist.
        controller.restartTour()
        controller.advanceManualStep()
        skipAll(controller)
        #expect(env.log.filter { $0 == "persistCompleted" }.count == 1)
    }

    @Test func controllerLoadsPersistedEverCompletedFlag() {
        let env = EnvRecorder()
        env.demoEverCompleted = true
        let controller = makeController(env: env, mock: seededMock())

        #expect(controller.hasEverCompletedDemo)
    }

    @Test func restartTourResetsSteps() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep()
        skipAll(controller)
        #expect(controller.isComplete)

        controller.restartTour()

        #expect(!controller.isComplete)
        #expect(controller.currentStep?.id == .meetCrew)
        #expect(controller.completedCount == 0)
    }

    // MARK: - Guided sub-steps

    @Test func meetCrewSpotlightsEmployeesTabAndAutoCompletes() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()

        #expect(controller.currentSpotlight?.target == .employeesTab)
        #expect(controller.currentSpotlight?.instructionKey
                == "demo.sub.meetCrew.openEmployeesTab")

        // Reaching the Employees tab completes the step — no banner Next.
        controller.noteTutorialEvent(.tabSelected(.employees))
        #expect(controller.currentStep?.id == .setAvailability)
        // Exposed for the spotlight host's page gating.
        #expect(controller.currentTab == .employees)
    }

    @Test func setAvailabilitySubStepsWalkTheGridFlow() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.noteTutorialEvent(.tabSelected(.employees)) // -> setAvailability

        // Already on the Employees tab, so the first sub-step is skipped.
        #expect(controller.currentSpotlight?.target == .mercuryRow)

        controller.noteTutorialEvent(.employeeDetailOpened(nickname: "Venus"))
        #expect(controller.currentSpotlight?.target == .mercuryRow)

        controller.noteTutorialEvent(.employeeDetailOpened(nickname: "Mercury"))
        #expect(controller.currentSpotlight?.target == .availabilityPencil)

        controller.noteTutorialEvent(.gridEditStarted)
        #expect(controller.currentSpotlight?.instructionKey
                == "demo.sub.setAvailability.cycleCell")

        controller.noteTutorialEvent(.cellCycled)
        #expect(controller.currentSpotlight?.instructionKey
                == "demo.sub.setAvailability.toggleLassoOn")
        #expect(controller.currentSpotlight?.target == .lassoToggle)

        controller.noteTutorialEvent(.lassoToggledOn)
        #expect(controller.currentSpotlight?.instructionKey
                == "demo.sub.setAvailability.lassoBlock")

        controller.noteTutorialEvent(.lassoDrawn)
        #expect(controller.currentSpotlight?.instructionKey
                == "demo.sub.setAvailability.bulkApply")

        controller.noteTutorialEvent(.lassoApplied)
        #expect(controller.currentSpotlight?.instructionKey
                == "demo.sub.setAvailability.toggleLassoOff")
        #expect(controller.currentSpotlight?.target == .lassoToggle)

        controller.noteTutorialEvent(.lassoToggledOff)
        #expect(controller.currentSpotlight?.instructionKey
                == "demo.sub.setAvailability.tapAvailabilityDone")
        #expect(controller.currentSpotlight?.target == .availabilityPencil)

        controller.noteTutorialEvent(.gridEditEnded)
        #expect(controller.currentSpotlight == nil)
    }

    @Test func outOfOrderEventJumpsPastIntermediateSubSteps() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep() // -> setAvailability, sub 0

        // The user found the pencil on their own — jump straight past the
        // navigation sub-steps.
        controller.noteTutorialEvent(.gridEditStarted)
        #expect(controller.currentSpotlight?.instructionKey
                == "demo.sub.setAvailability.cycleCell")
    }

    @Test func skipCurrentSubStepAdvancesOne() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep() // -> setAvailability

        #expect(controller.currentSpotlight?.target == .employeesTab)
        controller.skipCurrentSubStep()
        #expect(controller.currentSpotlight?.target == .mercuryRow)
    }

    @Test func generateRotaNormalizesAgainstContext() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.noteTutorialEvent(.tabSelected(.rota))
        controller.noteTutorialEvent(.weekChanged(isTourWeek: true))
        controller.advanceManualStep()
        skip(controller, to: .generateRota)

        // Already on the Rota tab viewing the tour week — point straight
        // at the Generate wand.
        #expect(controller.currentSpotlight?.target == .generateButton)
    }

    @Test func alterRotaCompletesOnDoneAfterSandboxEdit() async {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep()
        skip(controller, to: .alterRota)

        #expect(controller.currentSpotlight?.target == .sandboxButton)

        controller.noteTutorialEvent(.sandboxEntered)
        #expect(controller.currentSpotlight?.target == .shiftCard)

        // First swap tap: guidance drops to the floating "tap another
        // employee" hint while the app awaits the confirming tap.
        controller.noteTutorialEvent(.swapSourceSelected)
        #expect(controller.currentSpotlight?.target == .swapSecondTap)

        // Assignment mutation inside sandbox points at Done instead of
        // completing the step.
        await controller.evaluateCurrentStep(changedTables: [.assignment])
        #expect(controller.currentStep?.id == .alterRota)
        #expect(controller.currentSpotlight?.target == .doneButton)

        controller.noteTutorialEvent(.sandboxExited)
        #expect(controller.currentStep?.id == .exportPDF)
    }

    @Test func exceptionStepGuidesThroughMarsToAddException() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.noteTutorialEvent(.tabSelected(.employees)) // -> setAvailability
        controller.skipCurrentStep() // -> createException

        // Already on Employees, so guidance starts at Mars's row.
        #expect(controller.currentSpotlight?.target == .marsRow)

        controller.noteTutorialEvent(.employeeDetailOpened(nickname: "Mars"))
        #expect(controller.currentSpotlight?.target == .exceptionsScrollHint)

        // The Add Exception row scrolling into view advances past the hint.
        controller.noteTutorialEvent(.exceptionsSectionVisible(nickname: "Mars"))
        #expect(controller.currentSpotlight?.target == .addExceptionButton)

        // Opening the exception sheet exhausts the guidance; saving the
        // range completes the step via the data predicate.
        controller.noteTutorialEvent(.exceptionSheetOpened)
        #expect(controller.currentSpotlight == nil)
        #expect(controller.currentStep?.id == .createException)
    }

    @Test func exportStepGuidesToShareEntry() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep()
        skip(controller, to: .exportPDF)

        #expect(controller.currentStep?.id == .exportPDF)
        #expect(controller.currentSpotlight?.target == .rotaTab)

        controller.noteTutorialEvent(.tabSelected(.rota))
        #expect(controller.currentSpotlight?.target == .shareEntry)

        // Opening the share/export sheet moves guidance to the in-sheet
        // customize-layout tip.
        controller.noteTutorialEvent(.shareSheetOpened)
        #expect(controller.currentSpotlight?.target == .exportCustomize)
        #expect(controller.currentStep?.id == .exportPDF)

        // "Finish Demo" defers completion until the sheet has dismissed.
        controller.requestExportStepFinish()
        #expect(controller.currentStep?.id == .exportPDF)

        controller.consumeExportStepFinish()
        #expect(controller.currentStep == nil)
        #expect(controller.isComplete)
    }

    @Test func consumeExportFinishWithoutRequestIsNoOp() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep()
        skip(controller, to: .exportPDF)

        controller.consumeExportStepFinish()
        #expect(controller.currentStep?.id == .exportPDF)
        #expect(!controller.isComplete)
    }

    @Test func restartTourResetsSubSteps() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.noteTutorialEvent(.tabSelected(.employees))
        controller.advanceManualStep()
        controller.skipCurrentSubStep()

        controller.restartTour()

        // Back on meetCrew; the Employees tab is already current, so its
        // lone sub-step is pre-satisfied.
        #expect(controller.currentStep?.id == .meetCrew)
        #expect(controller.currentSpotlight == nil)
    }

    @Test func eventsIgnoredWhenDemoInactive() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())

        controller.noteTutorialEvent(.tabSelected(.employees))
        controller.noteTutorialEvent(.gridEditStarted)

        #expect(controller.currentSpotlight == nil)
        #expect(!controller.isActive)
    }

    // MARK: - Hint path

    @Test func hintPathFlipsNavPrerequisitesWhenUserBacksOut() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.noteTutorialEvent(.tabSelected(.employees)) // -> setAvailability
        controller.noteTutorialEvent(.employeeDetailOpened(nickname: "Mercury"))
        controller.noteTutorialEvent(.gridEditStarted)
        #expect(controller.currentHintItem?.sub == .cycleCell)

        // Wander off: close Mercury's page and switch to the Rota tab. The
        // nav prerequisites must read as the route back, not as done.
        controller.noteTutorialEvent(.employeeDetailClosed)
        controller.noteTutorialEvent(.tabSelected(.rota))

        let path = controller.hintPath!
        func state(_ sub: DemoSubStepID) -> DemoHintItem.State? {
            path.first { $0.sub == sub }?.state
        }
        #expect(state(.openEmployeesTab) == .current)
        #expect(state(.openMercury) == .todo)
        #expect(state(.tapPencil) == .todo)
        #expect(state(.cycleCell) == .todo)
        #expect(controller.currentHintItem?.sub == .openEmployeesTab)
        #expect(controller.currentHintItem?.instructionKey
                == "demo.sub.setAvailability.openEmployeesTab")

        // Returning re-satisfies the prerequisites and the path picks up
        // where the user left off.
        controller.noteTutorialEvent(.tabSelected(.employees))
        controller.noteTutorialEvent(.employeeDetailOpened(nickname: "Mercury"))
        controller.noteTutorialEvent(.gridEditStarted)
        #expect(controller.currentHintItem?.sub == .cycleCell)
    }

    @Test func hintPathKeepsSkippedActionsTodo() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.noteTutorialEvent(.tabSelected(.employees)) // -> setAvailability
        controller.skipCurrentSubStep() // skip openMercury (context-checked anyway)
        controller.skipCurrentSubStep() // skip tapPencil (context-checked anyway)
        controller.skipCurrentSubStep() // skip cycleCell — an action sub

        // The spotlight has moved on, but the skipped items still read as
        // the route in the hint path (their effects never happened):
        // Mercury's page isn't open, so it's the current direction, and the
        // skipped cycleCell action is todo — never satisfied.
        #expect(controller.currentSpotlight?.target == .lassoToggle)
        let path = controller.hintPath!
        #expect(path.first { $0.sub == .openMercury }?.state == .current)
        #expect(path.first { $0.sub == .tapPencil }?.state == .todo)
        #expect(path.first { $0.sub == .cycleCell }?.state == .todo)
    }

    @Test func hintPathFallsBackWhenAllItemsSatisfied() async {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep()
        skip(controller, to: .alterRota)
        controller.noteTutorialEvent(.tabSelected(.rota))
        controller.noteTutorialEvent(.sandboxEntered)
        controller.noteTutorialEvent(.swapSourceSelected)
        await controller.evaluateCurrentStep(changedTables: [.assignment])

        // Everything up to Done is satisfied; Done is the current item
        // (completes via sandboxExited, not an observed action).
        #expect(controller.currentHintItem?.sub == .tapDone)

        controller.noteTutorialEvent(.sandboxExited)
        #expect(controller.currentStep?.id == .exportPDF)
    }

    @Test func guidanceHiddenOnWrongTabOrExhaustedSequence() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        #expect(!controller.isGuidanceHidden) // inactive

        controller.enterDemo()
        // meetCrew's employeesTab prompt floats everywhere — not hidden.
        #expect(!controller.isGuidanceHidden)

        controller.noteTutorialEvent(.tabSelected(.employees)) // -> setAvailability
        controller.noteTutorialEvent(.employeeDetailOpened(nickname: "Mercury"))
        #expect(!controller.isGuidanceHidden) // pencil tip on its own tab

        // Wrong tab for the page-bound pencil target.
        controller.noteTutorialEvent(.tabSelected(.rota))
        #expect(controller.isGuidanceHidden)
        controller.noteTutorialEvent(.tabSelected(.employees))
        #expect(!controller.isGuidanceHidden)

        // Skipping the sequence dry hides guidance too.
        let subCount = DemoModeController.subSteps(for: .setAvailability).count
        for _ in 0..<subCount { controller.skipCurrentSubStep() }
        #expect(controller.currentSpotlight == nil)
        #expect(controller.isGuidanceHidden)
    }

    // MARK: - Gate

    @Test func demoFlagLiftsGateAndClears() {
        // Fresh instance — mutating `.shared` races parallel suites.
        let gate = LicenseGate()
        gate.update(state: .unset)
        #expect(!gate.allowsMutation)

        gate.setDemoActive(true)
        #expect(gate.allowsMutation)

        gate.setDemoActive(false)
        #expect(!gate.allowsMutation)
    }
}
