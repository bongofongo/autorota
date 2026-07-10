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
                tourWeekStart: { "2099-04-20" }
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

    @Test func availabilityStepCompletesWhenMercuryGainsOverride() async {
        let env = EnvRecorder()
        let mock = seededMock()
        let controller = makeController(env: env, mock: mock)
        controller.enterDemo()
        await controller.captureSeededBaseline()
        controller.advanceManualStep()

        // Unrelated table change does nothing.
        await controller.evaluateCurrentStep(changedTables: [.role])
        #expect(controller.currentStep?.id == .setAvailability)

        // Mercury (id 1) gets a manual per-date override.
        mock.stubbedAvailabilityOverrides.append(
            makeOverride(id: 200, employeeId: 1, source: "manual")
        )
        await controller.evaluateCurrentStep(changedTables: [.employeeAvailabilityOverride])
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
        #expect(controller.currentStep?.id == .generateRota)
    }

    @Test func generateStepNeedsAssignmentsInTourWeek() async {
        let env = EnvRecorder()
        let mock = seededMock()
        let controller = makeController(env: env, mock: mock)
        controller.enterDemo()
        await controller.captureSeededBaseline()
        controller.advanceManualStep()
        controller.skipCurrentStep()
        controller.skipCurrentStep() // -> generateRota

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
        controller.skipCurrentStep()
        controller.skipCurrentStep()
        controller.skipCurrentStep() // -> alterRota

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
        controller.skipCurrentStep()
        controller.skipCurrentStep()
        controller.skipCurrentStep() // -> alterRota (event-based step)

        await controller.evaluateCurrentStep(changedTables: nil)
        #expect(controller.currentStep?.id == .alterRota)
    }

    @Test func completingAllStepsSetsIsComplete() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()

        controller.advanceManualStep()
        for _ in 0..<5 { controller.skipCurrentStep() }

        #expect(controller.isComplete)
        #expect(controller.currentStep == nil)
    }

    @Test func restartTourResetsSteps() {
        let env = EnvRecorder()
        let controller = makeController(env: env, mock: seededMock())
        controller.enterDemo()
        controller.advanceManualStep()
        for _ in 0..<5 { controller.skipCurrentStep() }
        #expect(controller.isComplete)

        controller.restartTour()

        #expect(!controller.isComplete)
        #expect(controller.currentStep?.id == .meetCrew)
        #expect(controller.completedCount == 0)
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
