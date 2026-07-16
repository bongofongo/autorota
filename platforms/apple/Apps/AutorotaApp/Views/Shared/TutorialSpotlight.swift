import SwiftUI

// MARK: - Types (cross-platform; the overlay itself is iOS-only below)

/// UI elements the guided demo tour can point at. Views register their
/// global frame under one of these via `.tutorialTarget(_:)`.
enum TutorialTarget: String, Hashable {
    /// Tab-switch prompts: never highlighted (the system tab bar can't be
    /// located reliably) — the tooltip floats and the user finds the tab.
    case employeesTab
    case rotaTab
    case shiftsTab
    case mercuryRow
    case marsRow
    case availabilityPencil
    case availabilityGrid
    /// The lasso toggle in the grid's toolbar.
    case lassoToggle
    /// "Scroll down to the Exceptions section" — floats, never highlighted.
    case exceptionsScrollHint
    case addExceptionButton
    case nextWeekChevron
    case generateButton
    case sandboxButton
    case shiftCard
    case doneButton
    /// "Tap another employee to finish the swap" — floats, never highlighted.
    case swapSecondTap
    case shareEntry
    /// "What shifts are" intro on the Shifts tab — floats, never highlighted.
    case shiftPurposeHint
    /// The plus button in the Shifts list header.
    case addShiftButton
    /// "Role & Staffing" walkthrough — rendered by `ShiftTemplateEditSheet`'s
    /// own overlay (the sheet covers the root overlay).
    case shiftRoleStaffingHint
    /// "Customize the PDF layout" — rendered by `ExportSheetView`'s own
    /// overlay (the export sheet covers the root overlay), so the root host
    /// never resolves it.
    case exportCustomize

    /// The tab a target lives on. Guidance for a page-bound target is only
    /// shown while that tab is current; nil targets (the tab-switch
    /// prompts) are visible from anywhere.
    var requiredTab: TabPage? {
        switch self {
        case .employeesTab, .rotaTab, .shiftsTab:
            return nil
        case .mercuryRow, .marsRow, .availabilityPencil, .availabilityGrid,
             .lassoToggle, .exceptionsScrollHint, .addExceptionButton:
            return .employees
        case .shiftPurposeHint, .addShiftButton, .shiftRoleStaffingHint:
            return .templates
        case .nextWeekChevron, .generateButton, .sandboxButton, .shiftCard,
             .doneButton, .swapSecondTap, .shareEntry, .exportCustomize:
            return .rota
        }
    }

    /// Page-bound prompts that never register a frame: show the floating
    /// tooltip instead of hiding when no highlight is possible.
    var floatsWithoutFrame: Bool {
        switch self {
        case .exceptionsScrollHint, .swapSecondTap, .shiftPurposeHint,
             .shiftRoleStaffingHint:
            return true
        default:
            return false
        }
    }
}

/// User actions the guided tour listens for to advance its sub-steps.
enum TutorialEvent: Equatable {
    case tabSelected(TabPage)
    case employeeDetailOpened(nickname: String?)
    case employeeDetailClosed
    case gridEditStarted
    case gridEditEnded
    case cellCycled
    case lassoToggledOn
    case lassoDrawn
    case lassoApplied
    case lassoToggledOff
    case weekChanged(isTourWeek: Bool)
    case sandboxEntered
    case sandboxExited
    /// The Add Exception button scrolled into view on an employee page.
    case exceptionsSectionVisible(nickname: String?)
    case exceptionSheetOpened
    /// The new-shift template sheet was presented from the Shifts tab.
    case addShiftSheetOpened
    /// First swap tap made; the app is waiting for the confirming tap.
    case swapSourceSelected
    case shareSheetOpened
}

/// Grid-level actions forwarded to the tour without threading callbacks
/// through every `AvailabilityGridView` embed site. The grid posts these on
/// `.autorotaTutorialAction` with the action as the notification object;
/// `DemoModeController` maps them onto `TutorialEvent`s while a demo runs.
enum TutorialAction: String {
    case cellCycled
    case lassoToggledOn
    case lassoDrawn
    case lassoApplied
    case lassoToggledOff
}

extension Notification.Name {
    static let autorotaTutorialAction = Notification.Name("autorotaTutorialAction")
}

/// What the spotlight overlay should show right now.
struct DemoSpotlight: Equatable {
    let target: TutorialTarget
    /// Localization key of the tooltip instruction.
    let instructionKey: String
    /// 1-based position within the current step's sub-sequence.
    let index: Int
    let total: Int
    /// Info-only sub-steps have no completing action — the tooltip's
    /// button reads "Next" instead of "Skip".
    var isInfo: Bool = false
}

// MARK: - Frame registry

/// Holds the global-coordinate frames of registered tutorial targets so the
/// overlay can cut a spotlight hole around the active one. Frames are only
/// tracked while a demo is running (`isTracking`).
@MainActor
@Observable
final class TutorialSpotlightModel {
    var isTracking = false
    private(set) var frames: [TutorialTarget: CGRect] = [:]

    func update(_ target: TutorialTarget, frame: CGRect) {
        guard isTracking else { return }
        // Ignore zero/degenerate frames from views mid-layout.
        guard frame.width > 1, frame.height > 1 else { return }
        if frames[target] != frame {
            frames[target] = frame
        }
    }

    func remove(_ target: TutorialTarget) {
        frames[target] = nil
    }

    func reset() {
        frames = [:]
    }
}

// MARK: - Registration modifier

private struct TutorialTargetModifier: ViewModifier {
    let target: TutorialTarget
    @Environment(TutorialSpotlightModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                model.update(target, frame: frame)
            }
            .onDisappear {
                model.remove(target)
            }
    }
}

extension View {
    /// Registers this view's global frame as a spotlight target for the
    /// guided demo tour. No-ops (beyond a cheap geometry observation)
    /// outside demo mode.
    func tutorialTarget(_ target: TutorialTarget) -> some View {
        modifier(TutorialTargetModifier(target: target))
    }
}

/// Shared fade for every guidance appearance: the page settles first
/// (delay), then the dim/highlight/tooltip breathe in; dismissal is quick
/// so stale guidance gets out of the way. The first tooltip of a step's
/// sequence eases in slowly; subsequent ones are brisker to keep momentum.
enum TutorialFade {
    private static let first: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeIn(duration: 0.6).delay(0.25)),
        removal: .opacity.animation(.easeOut(duration: 0.2))
    )
    private static let subsequent: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeIn(duration: 0.35).delay(0.25)),
        removal: .opacity.animation(.easeOut(duration: 0.2))
    )

    static func transition(isFirstOfSet: Bool) -> AnyTransition {
        isFirstOfSet ? first : subsequent
    }
}
