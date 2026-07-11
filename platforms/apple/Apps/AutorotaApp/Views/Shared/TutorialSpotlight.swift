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

#if os(iOS)

// MARK: - Spotlight overlay (iPhone / iPad only)

/// Full-screen dim layer with a rounded-rect hole cut around the active
/// target, plus a tooltip bubble with the instruction and sub-progress.
/// The dim layer never intercepts touches — the user always performs the
/// pointed-at action themselves; only the tooltip's Skip button is tappable.
struct TutorialSpotlightOverlay: View {
    let spotlight: DemoSpotlight
    /// Resolved frame of the target, in global coordinates. Nil when the
    /// target isn't on screen (yet) — the tooltip floats without a hole.
    let targetFrame: CGRect?
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let holePadding: CGFloat = 6
    private static let holeCornerRadius: CGFloat = 10

    private var holeRect: CGRect? {
        targetFrame?.insetBy(dx: -Self.holePadding, dy: -Self.holePadding)
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = geo.frame(in: .global)
            ZStack(alignment: .topLeading) {
                if holeRect != nil {
                    dimLayer(bounds: bounds)
                        .allowsHitTesting(false)
                    anchoredTooltip(bounds: bounds)
                } else {
                    // No locatable target (tab-switch prompts): sit just
                    // above the tab bar, pointing down at it.
                    bottomFloatingTooltip
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: targetFrame)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func dimLayer(bounds: CGRect) -> some View {
        if let holeRect {
            // Even-odd fill: full-screen rect + hole path = dim everywhere
            // except the hole.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: bounds.size))
                let local = holeRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                path.addRoundedRect(
                    in: local,
                    cornerSize: CGSize(width: Self.holeCornerRadius, height: Self.holeCornerRadius)
                )
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .overlay(
                RoundedRectangle(cornerRadius: Self.holeCornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: holeRect.width, height: holeRect.height)
                    .position(
                        x: holeRect.midX - bounds.minX,
                        y: holeRect.midY - bounds.minY
                    )
            )
        }
    }

    /// Tooltip for a spotlighted target: on whichever side of the hole has
    /// more room, arrow pointing at the hole.
    @ViewBuilder
    private func anchoredTooltip(bounds: CGRect) -> some View {
        if let holeRect {
            let holeInLocal = holeRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let placeBelow = holeInLocal.midY < bounds.height / 2

            VStack(alignment: .leading, spacing: 8) {
                if placeBelow {
                    arrow(pointingUp: true)
                        .padding(.leading, 24)
                }
                tooltipBubble
                if !placeBelow {
                    arrow(pointingUp: false)
                        .padding(.leading, 24)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            .padding(.horizontal, 16)
            .position(
                x: min(max(holeInLocal.midX, 170), bounds.width - 170),
                y: placeBelow
                    ? min(holeInLocal.maxY + 70, bounds.height - 80)
                    : max(holeInLocal.minY - 70, 80)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("demo.spotlight.tooltip")
        }
    }

    /// Tooltip for tab-switch prompts: bottom-anchored just above the tab
    /// bar, arrow pointing down at it.
    private var bottomFloatingTooltip: some View {
        VStack(spacing: 8) {
            tooltipBubble
            arrow(pointingUp: false)
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 100)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("demo.spotlight.tooltip")
    }

    private var tooltipBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("demo.spotlight.progress \(spotlight.index) \(spotlight.total)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(spotlight.isInfo ? "demo.spotlight.next" : "demo.spotlight.skip") {
                    onSkip()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityIdentifier("demo.spotlight.skip")
            }
            Text(LocalizedStringKey(spotlight.instructionKey))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func arrow(pointingUp: Bool) -> some View {
        Triangle()
            .fill(.regularMaterial)
            .frame(width: 18, height: 9)
            .rotationEffect(pointingUp ? .zero : .degrees(180))
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

#endif
