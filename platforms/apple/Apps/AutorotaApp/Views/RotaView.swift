import SwiftUI
import AutorotaKit

struct RotaView: View {

    @State private var vm = RotaViewModel()
    @State private var showExportSheet = false
    @State private var showStaffingSheet = false
    /// Shift picked in the warnings sheet; handed to the grid via
    /// `vm.requestShiftFocus` only after the sheet has fully dismissed, so the
    /// editor sheet doesn't race the dismissal transition.
    @State private var pendingFocusShiftId: Int64?
    /// `-1` means "not yet loaded" — treat as having employees so the existing
    /// no-schedule CUV (with Generate prompt) is the default. Only an explicit
    /// `0` triggers the prerequisite empty state.
    @State private var employeeCount: Int = -1
    /// Tracks the currently-running week-change reload so the prior task can
    /// be cancelled when the user rapidly steps through weeks. Without this,
    /// a slow load for week N could overwrite a fresh load for week N+1.
    @State private var weekChangeTask: Task<Void, Never>?
    @Environment(RotaUIBridge.self) private var bridge
    @Environment(EmployeeUIBridge.self) private var employeeBridge
    @Environment(DemoModeController.self) private var demo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isMenuPushed) private var isMenuPushed

    /// Slide for week steps: the incoming week pushes in from the side it
    /// lives on (future from trailing, past from leading). Crossfade under
    /// Reduce Motion.
    private var weekTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .push(from: vm.lastWeekStepDirection >= 0 ? .trailing : .leading)
    }

    /// Animated week step shared by the toolbar chevrons and the empty-week
    /// swipe. `fromSwipe` gates the haptic tick to gesture-driven changes.
    private func stepWeek(_ delta: Int, fromSwipe: Bool = true) {
        withAnimation(.smooth(duration: 0.3)) {
            vm.shiftWeek(by: delta)
        }
        if fromSwipe { vm.swipeFeedbackTick += 1 }
    }

    var body: some View {
        OptionalNavigationStack(embed: !isMenuPushed) {
            VStack(spacing: 0) {
                Group {
                    if vm.isLoading {
                        VStack {
                            Spacer()
                            ProgressView("Loading schedule…")
                            Spacer()
                        }
                    } else if let schedule = vm.schedule {
                        ScheduleGridView(vm: vm, schedule: schedule)
                    } else if employeeCount == 0 {
                        VStack {
                            Spacer()
                            ContentUnavailableView {
                                Label("empty.rota.title", systemImage: "person.crop.circle.badge.exclamationmark")
                            } description: {
                                Text("empty.rota.body")
                            } actions: {
                                Button {
                                    employeeBridge.requestNewEmployeeSheet = true
                                } label: {
                                    Label("empty.rota.action", systemImage: "person.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Spacer()
                        }
                    } else {
                        VStack {
                            Spacer()
                            ContentUnavailableView(
                                "No Schedule",
                                systemImage: "calendar.badge.plus",
                                description: Text("Tap Generate to create a schedule for this week.")
                            )
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .weekSwipe(enabled: true) { stepWeek($0) }
                    }
                }
                // Re-identify the content per week so a step slides the old
                // week out and the new one in (see `weekTransition`).
                .id(vm.selectedWeekStart)
                .transition(weekTransition)
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sensoryFeedback(.selection, trigger: vm.swipeFeedbackTick)
            .onAppear {
                demo.noteTutorialEvent(.weekChanged(isTourWeek: vm.selectedWeekStart == demo.tourWeek))
            }
            .onChange(of: showExportSheet) { _, shown in
                if shown { demo.noteTutorialEvent(.shareSheetOpened) }
            }
            .onChange(of: vm.hasSwapSource) { _, selecting in
                if selecting { demo.noteTutorialEvent(.swapSourceSelected) }
            }
            .onChange(of: vm.selectedWeekStart) { _, newWeek in
                demo.noteTutorialEvent(.weekChanged(isTourWeek: newWeek == demo.tourWeek))
                // Cancel any in-flight reload from a prior week step so a slow
                // load can't clobber a fresh one.
                weekChangeTask?.cancel()
                weekChangeTask = Task {
                    await vm.autoSave()
                    if Task.isCancelled { return }
                    vm.resetModes()
                    if Task.isCancelled { return }
                    await vm.loadSchedule()
                }
            }
            .toolbar {
                // Top-left: options menu — only on a scheduled week, not while
                // editing. `.topBarLeading` is iOS-family only; macOS uses
                // `.navigation` for the leading edge.
                if vm.schedule != nil && !vm.isEditMode {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) { optionsMenu }
                    #else
                    ToolbarItem(placement: .navigation) { optionsMenu }
                    #endif
                }
                ToolbarItem(placement: .principal) {
                    weekNavigationTitle
                }
                // Top-right: Swap on a scheduled week, Done while editing, or a
                // lone Generate on an empty week. Share lives in the options
                // menu on iPhone/macOS; iPad surfaces it as a discrete button.
                ToolbarItemGroup(placement: .primaryAction) {
                    primaryActionButtons
                }
            }
            .onChange(of: vm.isEditMode) { _, new in
                demo.noteTutorialEvent(new ? .sandboxEntered : .sandboxExited)
                if reduceMotion {
                    bridge.isEditMode = new
                } else {
                    withAnimation(.smooth(duration: 0.35)) {
                        bridge.isEditMode = new
                    }
                }
            }
            .onChange(of: bridge.isEditMode) { _, new in
                if !new && vm.isEditMode {
                    vm.exitEditMode()
                }
            }
            .alert(
                "No schedule for \(vm.weekDateRangeLabel)",
                isPresented: $vm.showGenerateConfirmation
            ) {
                Button("Use existing shifts") {
                    Task { await vm.createFromTemplate() }
                }
                Button("Create empty schedule") {
                    Task { await vm.createEmpty() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("How would you like to create a schedule for this week?")
            }
            .alert(
                "Delete week of \(vm.weekDateRangeLabel)?",
                isPresented: $vm.showDeleteScheduleConfirmation
            ) {
                Button("Delete", role: .destructive) {
                    Task { await vm.deleteSchedule() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All shifts and assignments for this week will be permanently deleted.")
            }
            .alert(
                "Regenerate schedule for \(vm.weekDateRangeLabel)?",
                isPresented: $vm.showRegenerateConfirmation
            ) {
                Button("Regenerate", role: .destructive) {
                    Task { await vm.confirmRegenerate() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the current schedule and its assignments, then generates a new one.")
            }
            .errorAlert($vm.error)
            .sheet(isPresented: $showExportSheet, onDismiss: {
                // Demo "Finish Demo" defers step completion to here so the
                // completion card presents only after this sheet is gone.
                demo.consumeExportStepFinish()
            }) {
                ExportSheetView(
                    weekStart: vm.selectedWeekStart,
                    service: vm.service
                )
            }
            .sheet(isPresented: $showStaffingSheet, onDismiss: {
                if let id = pendingFocusShiftId {
                    pendingFocusShiftId = nil
                    vm.requestShiftFocus(id)
                }
            }) {
                StaffingIssuesView(
                    issues: vm.staffingIssues,
                    dayLabel: { vm.dayOfMonthLabel($0) },
                    onSelect: { issue in
                        pendingFocusShiftId = issue.shiftId
                        showStaffingSheet = false
                    }
                )
            }
            .task {
                await vm.loadSchedule()
                await refreshEmployeeCount()
            }
            .onReceive(NotificationCenter.default.publisher(for: .autorotaDataChanged)) { _ in
                Task { await refreshEmployeeCount() }
            }
        }
    }

    private func refreshEmployeeCount() async {
        do {
            let n = try await countEmployeesAsync()
            await MainActor.run { employeeCount = Int(n) }
        } catch {
            // Keep `-1` (unknown) so the no-schedule CUV renders without
            // suppressing the prerequisite empty state on next refresh.
            await MainActor.run {
                if employeeCount < 0 { employeeCount = -1 }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let n = try? await countEmployeesAsync() {
                await MainActor.run { employeeCount = Int(n) }
            }
        }
    }

    // MARK: - Toolbar content

    /// Principal toolbar item: prev/next week chevrons around the range label.
    private var weekNavigationTitle: some View {
        HStack(spacing: 8) {
            Button { stepWeek(-1, fromSwipe: false) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityIdentifier("rota.prevWeek")

            Text(vm.weekDateRangeShort)
                .font(.headline)
                .lineLimit(1)
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(vm.weekCategory.underlineTint)
                        .frame(height: vm.weekCategory == .current ? 2 : 1)
                        .padding(.horizontal, 2)
                }
                // Fixed width keeps the chevrons anchored as the
                // date range string changes width week to week.
                .frame(width: 150)
                .accessibilityIdentifier("rota.weekTitle")
                .accessibilityValue(vm.weekCategory.accessibilityLabel)

            Button { stepWeek(1, fromSwipe: false) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityIdentifier("rota.nextWeek")
            .tutorialTarget(.nextWeekChevron)
        }
    }

    /// Top-right buttons: Done while editing, Share (iPad) + Sandbox on a
    /// scheduled week, or a lone Generate on an empty week.
    @ViewBuilder
    private var primaryActionButtons: some View {
        if vm.isEditMode {
            Button { vm.exitEditMode() } label: {
                Image(systemName: "checkmark")
            }
            .accessibilityLabel("Done editing")
            .accessibilityIdentifier("rota.done")
            .tutorialTarget(.doneButton)
        } else if vm.schedule != nil {
            if isPad {
                Button { showExportSheet = true } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
                .accessibilityIdentifier("rota.share")
                .tutorialTarget(.shareEntry)
            }
            Button { Task { await vm.enterEditMode() } } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Sandbox mode")
            .accessibilityIdentifier("rota.sandbox")
            .tutorialTarget(.sandboxButton)
        } else {
            Button { Task { await vm.runSchedule() } } label: {
                Image(systemName: "wand.and.stars")
            }
            .accessibilityLabel("Generate")
            .accessibilityIdentifier("rota.generate")
            .tutorialTarget(.generateButton)
        }
    }

    // MARK: - Options menu

    /// Whether we're on iPad, where Share moves out of the options menu into
    /// a discrete trailing toolbar button.
    private var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// Top-left ellipsis menu, shown only on a scheduled week (not editing).
    /// Holds Regenerate, Share (iPhone/macOS only), and the destructive
    /// Delete week; Swap is surfaced as a discrete trailing button.
    @ViewBuilder
    private var optionsMenu: some View {
        Menu {
            Button { showStaffingSheet = true } label: {
                if vm.staffingWarnings.isEmpty {
                    Label("Warnings", systemImage: "exclamationmark.triangle")
                } else {
                    Label("Warnings (\(vm.staffingWarnings.count))", systemImage: "exclamationmark.triangle")
                }
            }
            Divider()
            if !isPad {
                Button { showExportSheet = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button { Task { await vm.runSchedule() } } label: {
                Label("Regenerate", systemImage: "wand.and.stars")
            }
            Button(role: .destructive) {
                vm.showDeleteScheduleConfirmation = true
            } label: {
                Label("Delete week", systemImage: "trash")
            }
        } label: {
            // The toolbar wraps items in a circular glass shape that clips
            // its content, so the badge must stay inside the button bounds:
            // widen the label's frame so the overlay corner sits inside the
            // glass instead of offsetting past the glyph's edge.
            Image(systemName: "ellipsis")
                .frame(width: 30, height: 30)
        }
        // The badge hangs on the Menu container, not the label: the label
        // morphs into the popup and is only re-rendered after the dismiss
        // transition, which made a label-attached badge vanish briefly every
        // time the menu closed.
        .overlay(alignment: .topTrailing) {
            staffingBadge
                .allowsHitTesting(false)
        }
        .accessibilityLabel(
            vm.staffingWarnings.isEmpty
                ? "Options"
                : "Options, \(vm.staffingWarnings.count) staffing warnings"
        )
        .accessibilityIdentifier("rota.options")
        // Share lives inside this menu on iPhone/macOS, so the export
        // tour step points here; iPad tags its discrete Share button.
        .modifier(ShareEntryTutorialTag(enabled: !isPad))
    }

    /// Corner indicator on the ellipsis: orange numbered capsule when any
    /// shift is under its minimum; a subtle dot when the only gaps are
    /// below-max notes. Nothing when fully staffed.
    @ViewBuilder
    private var staffingBadge: some View {
        if !vm.staffingWarnings.isEmpty {
            Text("\(vm.staffingWarnings.count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3.5)
                .padding(.vertical, 1)
                .background(.orange, in: Capsule())
        } else if !vm.staffingNotes.isEmpty {
            Circle()
                .fill(.secondary)
                .frame(width: 6, height: 6)
        }
    }
}

/// Conditionally registers the demo tour's share-entry target.
private struct ShareEntryTutorialTag: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.tutorialTarget(.shareEntry)
        } else {
            content
        }
    }
}

// MARK: - Week category palette

private extension Color {
    /// Soft sage/mint shared by the "current" week underline and the "today"
    /// marker in the schedule grid. Light and unobtrusive.
    static let weekSage = Color(red: 0.52, green: 0.71, blue: 0.59)
}

private extension WeekCategory {
    /// Thin underline tint beneath the carousel date range, replacing the old
    /// pill badge. Current is a soft sage/mint (light, unobtrusive); future
    /// keeps the warm orange; past is a faint gray (matches `DayHeader`).
    var underlineTint: Color {
        switch self {
        case .current: return .weekSage.opacity(0.7)
        case .future:  return .orange.opacity(0.7)
        case .past:    return .secondary.opacity(0.35)
        }
    }

    /// Spoken category for VoiceOver, since the visible label was removed.
    var accessibilityLabel: String {
        switch self {
        case .past: return "Past"
        case .current: return "Current"
        case .future: return "Future"
        }
    }
}

// MARK: - Schedule grid

/// Discriminator for the schedule grid's sheet — replaces three separate
/// `.sheet(item:)` modifiers, only one of which would ever fire on the same
/// view. Stacking multiple `.sheet(item:)` modifiers risks SwiftUI dropping
/// later assignments when a prior sheet is mid-dismiss.
private enum ScheduleSheet: Identifiable {
    case shiftEditor(FfiShiftInfo)
    case addShift(SheetDate)
    case addEmployee(FfiShiftInfo)

    var id: String {
        switch self {
        case .shiftEditor(let s): return "shift-\(s.id)"
        case .addShift(let d):    return "add-\(d.id)"
        case .addEmployee(let s): return "addemp-\(s.id)"
        }
    }
}

private struct ScheduleGridView: View {
    let vm: RotaViewModel
    let schedule: FfiWeekSchedule

    @State private var activeSheet: ScheduleSheet?
    /// A sheet whose presentation is deferred until the past-week edit prompt is
    /// confirmed. nil when no confirmation is pending.
    @State private var pendingSheet: ScheduleSheet?
    @State private var showUnlockPastConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(iOS)
    /// How far past a horizontal edge the user must pull (then lift) for the
    /// iPhone landscape grid to step the week. Kept low so the pull at a
    /// terminal day (Mon/Sun) commits without a long drag.
    private static let weekPullThreshold: CGFloat = 16

    /// Signed horizontal overscroll: negative = pulled past the leading edge,
    /// positive = pulled past the trailing edge, 0 = within bounds.
    private static func horizontalOverscroll(_ geo: ScrollGeometry) -> CGFloat {
        let minX = -geo.contentInsets.leading
        let maxX = max(minX, geo.contentSize.width - geo.containerSize.width
                             + geo.contentInsets.trailing)
        let x = geo.contentOffset.x
        if x < minX { return x - minX }
        if x > maxX { return x - maxX }
        return 0
    }
    #endif

    /// Step the week from a swipe gesture — same effect as the toolbar
    /// chevrons, plus the slide animation and a haptic tick.
    private func stepWeek(_ delta: Int) {
        withAnimation(.smooth(duration: 0.3)) {
            vm.shiftWeek(by: delta)
        }
        vm.swipeFeedbackTick += 1
    }

    /// First shift of the week in weekday order — the card the demo tour's
    /// "alter an assignment" spotlight points at.
    private var firstShiftId: Int64? {
        for day in vm.allWeekdays {
            if let shift = vm.shifts(on: day).first { return shift.id }
        }
        return nil
    }

    /// Present a sheet, first prompting for confirmation if this is the first
    /// edit on a locked past week. Confirming unlocks edits for the visit.
    private func requestSheet(_ sheet: ScheduleSheet) {
        if vm.weekCategory == .past && !vm.pastUnlocked {
            pendingSheet = sheet
            showUnlockPastConfirmation = true
        } else {
            activeSheet = sheet
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geo in
                if geo.size.width > geo.size.height {
                    landscapeContent(availableSize: geo.size)
                } else {
                    portraitContent
                }
            }
            .onChange(of: vm.shiftFocusRequest) { _, request in
                guard let request else { return }
                vm.shiftFocusRequest = nil
                guard let shift = schedule.shifts.first(where: { $0.id == request.shiftId }) else { return }
                if reduceMotion {
                    proxy.scrollTo(shift.id, anchor: .center)
                } else {
                    withAnimation(.smooth(duration: 0.35)) {
                        proxy.scrollTo(shift.id, anchor: .center)
                    }
                }
                // Let the scroll settle before the editor slides up, so the
                // user sees where the shift lives before it's covered.
                let delay: UInt64 = reduceMotion ? 50_000_000 : 450_000_000
                Task {
                    try? await Task.sleep(nanoseconds: delay)
                    requestSheet(.shiftEditor(shift))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if vm.hasSwapSource {
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("Tap a highlighted employee to swap")
                        .font(.subheadline)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .shiftEditor(let shift):
                ShiftEditorSheet(vm: vm, shift: shift)
            case .addShift(let date):
                AddShiftSheet(vm: vm, date: date.id)
            case .addEmployee(let shift):
                AddEmployeePickerSheet(vm: vm, shift: shift)
            }
        }
        .alert(
            "Edit past rota?",
            isPresented: $showUnlockPastConfirmation
        ) {
            Button("Edit", role: .destructive) {
                vm.pastUnlocked = true
                if let sheet = pendingSheet {
                    pendingSheet = nil
                    activeSheet = sheet
                }
            }
            Button("Cancel", role: .cancel) {
                pendingSheet = nil
                if vm.isEditMode { vm.isEditMode = false }
            }
        } message: {
            Text("This rota is from a past week. Are you sure you want to make changes?")
        }
        .onChange(of: vm.isEditMode) { _, new in
            // Entering edit mode (for the swap gesture) on a locked past week
            // also prompts for confirmation.
            if new && vm.weekCategory == .past && !vm.pastUnlocked {
                showUnlockPastConfirmation = true
            }
        }
    }

    // MARK: Portrait layout

    private var portraitContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                ForEach(vm.allWeekdays, id: \.self) { day in
                    let shifts = vm.shifts(on: day)
                    Section {
                        ForEach(shifts, id: \.id) { shift in
                            ShiftCard(
                                shift: shift,
                                assignments: vm.assignments(for: shift.id),
                                vm: vm,
                                isEditMode: vm.isEditMode,
                                isLocked: vm.isShiftLocked(shift),
                                onEdit: { requestSheet(.shiftEditor(shift)) },
                                onAddEmployee: { requestSheet(.addEmployee(shift)) }
                            )
                            .modifier(FirstShiftTutorialTag(isFirst: shift.id == firstShiftId))
                            .id(shift.id)
                        }
                        if shifts.isEmpty {
                            Text("No shifts")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .italic()
                                .padding(.horizontal)
                        }
                    } header: {
                        DayHeader(
                            day: day,
                            dateLabel: vm.dayOfMonthLabel(day),
                            isToday: vm.isDayToday(day),
                            isPast: vm.isDayPast(day),
                            onAddShift: { requestSheet(.addShift(SheetDate(vm.dateForWeekday(day)))) }
                        )
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
        .weekSwipe(enabled: !vm.isEditMode) { stepWeek($0) }
    }

    // MARK: Landscape layout (weekly columns)

    /// The seven weekday columns, shared by every landscape variant.
    private func weekColumns(columnWidth: CGFloat, spacing: CGFloat, padding: CGFloat) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(vm.allWeekdays, id: \.self) { day in
                dayColumn(day: day, width: columnWidth)
            }
        }
        .padding(.horizontal, padding)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func landscapeContent(availableSize: CGSize) -> some View {
        let columnSpacing: CGFloat = 8
        let outerPadding: CGFloat = 8
        let count = CGFloat(max(vm.allWeekdays.count, 1))
        let totalSpacing = (count - 1) * columnSpacing + outerPadding * 2
        let fittedWidth = (availableSize.width - totalSpacing) / count

        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // iPhone: columns get extra width (with horizontal scroll) so
            // names and times breathe; pull past either edge to step the week.
            phoneLandscape(
                columnWidth: max(162, fittedWidth),
                spacing: columnSpacing,
                padding: outerPadding,
                minHeight: availableSize.height - 16
            )
        } else {
            // iPad: the whole week always fits one screen, so there is no
            // horizontal scroll — a swipe anywhere steps the week directly.
            ScrollView(.vertical) {
                weekColumns(columnWidth: fittedWidth, spacing: columnSpacing, padding: outerPadding)
            }
            .contentShape(Rectangle())
            .weekSwipe(enabled: !vm.isEditMode) { stepWeek($0) }
        }
        #else
        // macOS: unchanged scrolling fallback for narrow windows.
        ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: false) {
                weekColumns(
                    columnWidth: max(150, fittedWidth),
                    spacing: columnSpacing,
                    padding: outerPadding
                )
            }
        }
        #endif
    }

    #if os(iOS)
    private func phoneLandscape(
        columnWidth: CGFloat,
        spacing: CGFloat,
        padding: CGFloat,
        minHeight: CGFloat
    ) -> some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: false) {
                weekColumns(columnWidth: columnWidth, spacing: spacing, padding: padding)
                    // Fill the viewport so the blank space below short columns
                    // still pans (and overscrolls) horizontally.
                    .frame(minHeight: minHeight, alignment: .top)
            }
            .onScrollPhaseChange { oldPhase, _, context in
                // Fire exactly once per finger lift: only on the transition
                // out of .interacting. Bounce-back and fling-induced
                // overscroll can't re-trigger.
                guard !vm.isEditMode, oldPhase == .interacting else { return }
                let over = Self.horizontalOverscroll(context.geometry)
                if over <= -Self.weekPullThreshold {
                    stepWeek(-1)
                } else if over >= Self.weekPullThreshold {
                    stepWeek(1)
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private func dayColumn(day: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Column header — plain label in landscape; the add affordance is
            // the plus button at the bottom of the column instead.
            DayHeader(
                day: day,
                dateLabel: vm.dayOfMonthLabel(day),
                isToday: vm.isDayToday(day),
                isPast: vm.isDayPast(day),
                onAddShift: {},
                showsPlus: false
            )

            // Shifts
            let shifts = vm.shifts(on: day)
            if shifts.isEmpty {
                Text("No shifts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.horizontal, 8)
            } else {
                ForEach(shifts, id: \.id) { shift in
                    ShiftCard(
                        shift: shift,
                        assignments: vm.assignments(for: shift.id),
                        vm: vm,
                        isEditMode: vm.isEditMode,
                        isLocked: vm.isShiftLocked(shift),
                        onEdit: { requestSheet(.shiftEditor(shift)) },
                        onAddEmployee: { requestSheet(.addEmployee(shift)) },
                        isCompact: true
                    )
                    .modifier(FirstShiftTutorialTag(isFirst: shift.id == firstShiftId))
                    .id(shift.id)
                }
            }

            // Add-shift affordance at the foot of the column, after the shifts.
            Button(action: { requestSheet(.addShift(SheetDate(vm.dateForWeekday(day)))) }) {
                Image(systemName: "plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .accessibilityLabel("Add shift on \(day)")

            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .top)
    }
}

/// Registers the week's first shift card as the demo tour's "alter an
/// assignment" spotlight target.
private struct FirstShiftTutorialTag: ViewModifier {
    let isFirst: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFirst {
            content.tutorialTarget(.shiftCard)
        } else {
            content
        }
    }
}

// MARK: - Day header

/// Minimalist, Apple-Calendar-style weekday header: left-justified title over a
/// thin underline whose color encodes time alignment (past / today / future).
/// Tapping anywhere on the header adds a shift to that day.
private struct DayHeader: View {
    let day: String
    /// Full-month day-of-month, e.g. "June 1".
    let dateLabel: String
    let isToday: Bool
    let isPast: Bool
    let onAddShift: () -> Void
    /// Landscape columns hide the inline plus (the add affordance lives at the
    /// bottom of each column instead) and render a non-interactive header.
    var showsPlus: Bool = true

    var body: some View {
        if showsPlus {
            Button(action: onAddShift) {
                headerContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.background)
            .accessibilityLabel("Add shift on \(day)")
        } else {
            headerContent
                .background(.background)
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            Text("\(day) · \(dateLabel)")
                .font(.headline)
                .foregroundStyle(isPast ? .secondary : .primary)
            Spacer()
            if showsPlus {
                Image(systemName: "plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(underlineColor)
                .frame(height: isToday ? 2 : 1)
                .padding(.horizontal, 12)
        }
    }

    /// Muted underline tint by time alignment: today in sage (matching the
    /// current-week carousel marker), past gray, future faint.
    private var underlineColor: Color {
        if isToday { return .weekSage.opacity(0.7) }
        if isPast { return .secondary.opacity(0.35) }
        return .secondary.opacity(0.15)
    }
}

// MARK: - Shift card

private struct ShiftCard: View {
    let shift: FfiShiftInfo
    let assignments: [FfiScheduleEntry]
    let vm: RotaViewModel
    let isEditMode: Bool
    let isLocked: Bool
    /// Tap-to-edit: opens the unified shift editor for this shift (normal mode).
    let onEdit: () -> Void
    /// Sandbox-mode quick-add: opens the employee picker for this shift.
    let onAddEmployee: () -> Void
    var isCompact: Bool = false

    @State private var showDeleteConfirm = false

    /// Whether sandbox quick-edit controls are active on this card.
    private var sandboxActive: Bool { isEditMode && !isLocked }

    /// The card content (without swipe/context-menu chrome). Wrapped below so
    /// the swipe container can reveal a delete action behind it.
    private var card: some View {
        Group {
            if isCompact {
                // Landscape columns: employees on top, capacity + times in a
                // single row along the bottom of the card.
                VStack(alignment: .leading, spacing: 6) {
                    employeeColumn
                    bottomDetailsRow
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    employeeColumn
                    trailingDetailsColumn
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(radius: 1)
        )
        .opacity(isLocked && isEditMode ? 0.5 : 1.0)
        // Tapping the card opens the editor only in normal mode. In sandbox
        // mode the card is not tappable-to-edit — quick controls handle edits.
        .contentShape(Rectangle())
        .onTapGesture { if !isEditMode { onEdit() } }
    }

    // Employees, left-justified and top-aligned.
    private var employeeColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if assignments.isEmpty {
                Text("Unassigned")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                ForEach(assignments, id: \.assignmentId) { entry in
                    AssignmentRow(
                        entry: entry,
                        vm: vm,
                        shift: shift,
                        isEditMode: isEditMode,
                        isLocked: isLocked,
                        isCompact: isCompact
                    )
                }
            }

            // Sandbox quick-add — bottom-left, under the employee list.
            // Bypasses the shift max (createAssignment has no capacity gate).
            if sandboxActive {
                Button(action: onAddEmployee) {
                    Label("Add", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.top, 2)
                .padding(.horizontal, 4)
                .accessibilityLabel("Add employee to shift")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capacityText: some View {
        Text("\(assignments.count)/\(shift.maxEmployees)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(assignments.count < Int(shift.minEmployees) ? .red : .secondary)
    }

    private var startTimeText: some View {
        Text(shift.startTime)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var endTimeText: some View {
        Text(shift.endTime)
            .font(.caption.bold())
            .foregroundStyle(.primary)
    }

    // Portrait: capacity over stacked shift times, right-aligned. Start time
    // stays muted; end time is emboldened in the primary color. Role is
    // intentionally omitted from the grid card (still shown on tap in the
    // shift editor).
    private var trailingDetailsColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            capacityText
            startTimeText
            endTimeText
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // Landscape: capacity bottom-left with start → end times centered along
    // the bottom of the card.
    private var bottomDetailsRow: some View {
        ZStack {
            HStack {
                capacityText
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                startTimeText
                endTimeText
            }
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            // iOS portrait: swipe a card left to reveal Delete. Landscape
            // columns (`isCompact`) fall back to the context menu like macOS.
            if sandboxActive && !isCompact {
                SwipeToDeleteCard(onDelete: { showDeleteConfirm = true }) {
                    card
                }
            } else {
                card.modifier(ShiftContextDelete(enabled: sandboxActive) { showDeleteConfirm = true })
            }
            #else
            card.modifier(ShiftContextDelete(enabled: sandboxActive) { showDeleteConfirm = true })
            #endif
        }
        .padding(.horizontal, isCompact ? 6 : 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shiftA11yLabel)
        .accessibilityAction(named: isEditMode ? "Delete shift" : "Edit shift") {
            if isEditMode { showDeleteConfirm = true } else { onEdit() }
        }
        .alert("Delete this shift?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await vm.deleteShift(id: shift.id) }
            }
        } message: {
            Text("This shift and all its assignments will be permanently deleted.")
        }
    }

    private var shiftA11yLabel: String {
        let role = shift.requiredRole.isEmpty ? "any role" : shift.requiredRole
        let staffing = "\(assignments.count) of \(shift.maxEmployees) staffed"
        return "Shift \(shift.startTime) to \(shift.endTime), \(role), \(staffing)"
    }
}

// MARK: - Shift delete affordances

/// Adds a destructive "Delete shift" context menu when `enabled`. Used on macOS
/// and on iOS landscape columns where the swipe gesture isn't offered.
private struct ShiftContextDelete: ViewModifier {
    let enabled: Bool
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete shift", systemImage: "trash")
                }
            }
        } else {
            content
        }
    }
}

#if os(iOS)
/// Drag-to-reveal delete for a shift card. A red Delete button sits underneath;
/// dragging the card left reveals it. Used only in sandbox mode, iOS portrait.
private struct SwipeToDeleteCard<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    /// Live offset while dragging / at rest.
    @State private var offset: CGFloat = 0
    /// Committed resting offset (0 closed, -revealWidth open), captured as the
    /// drag base so onChanged deltas don't compound.
    @State private var committed: CGFloat = 0
    /// How far the card slides to fully expose the delete button.
    private let revealWidth: CGFloat = 84

    var body: some View {
        ZStack(alignment: .trailing) {
            // Underlay delete action, revealed as the card slides left.
            Button {
                close()
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .opacity(offset < -4 ? 1 : 0)
            .accessibilityLabel("Delete shift")

            content
                .offset(x: offset)
                .highPriorityGesture(
                    // High `minimumDistance` so the vertical scroll isn't stolen
                    // by an incidental horizontal twitch.
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            // Clamp between fully open (-revealWidth) and closed
                            // (0); `committed` is the resting base for this drag.
                            offset = min(0, max(-revealWidth, committed + value.translation.width))
                        }
                        .onEnded { value in
                            if committed + value.translation.width < -revealWidth / 2 {
                                open()
                            } else {
                                close()
                            }
                        }
                )
        }
    }

    private func open() {
        committed = -revealWidth
        withAnimation(.snappy(duration: 0.2)) { offset = -revealWidth }
    }

    private func close() {
        committed = 0
        withAnimation(.snappy(duration: 0.2)) { offset = 0 }
    }
}
#endif

// MARK: - Week swipe

#if os(iOS)
/// Horizontal-dominant drag that steps the visible week, mirroring the toolbar
/// chevrons. Attached with `simultaneousGesture` so it never steals vertical
/// scrolling or pinned-header interactions from the grid.
private struct WeekSwipeGesture: ViewModifier {
    let isEnabled: Bool
    let onStep: (Int) -> Void
    @Environment(\.layoutDirection) private var layoutDirection

    /// High enough that an incidental horizontal twitch during a vertical
    /// scroll never registers (same rationale as SwipeToDeleteCard).
    private static let minimumDistance: CGFloat = 25
    private static let triggerDistance: CGFloat = 60
    private static let dominanceRatio: CGFloat = 1.5

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: Self.minimumDistance)
                .onEnded { value in
                    guard isEnabled else { return }
                    let w = value.translation.width
                    let h = value.translation.height
                    guard abs(w) >= Self.triggerDistance,
                          abs(w) > abs(h) * Self.dominanceRatio else { return }
                    // Content dragged left → next week; flip in RTL so "toward
                    // the future" matches the reading direction.
                    var step = w < 0 ? 1 : -1
                    if layoutDirection == .rightToLeft { step = -step }
                    onStep(step)
                }
        )
    }
}
#endif

extension View {
    /// Swipe-to-change-week, iOS-family only; no-op elsewhere so call sites
    /// stay free of platform conditionals.
    @ViewBuilder
    fileprivate func weekSwipe(enabled: Bool, onStep: @escaping (Int) -> Void) -> some View {
        #if os(iOS)
        modifier(WeekSwipeGesture(isEnabled: enabled, onStep: onStep))
        #else
        self
        #endif
    }
}

// MARK: - Conflict glyph

/// Compact warning indicator shown next to a conflicted assignment in the grid.
/// Only hard conflicts render (orange triangle); the soft `.maybe` hint is
/// intentionally suppressed.
private struct ConflictGlyph: View {
    let reason: ConflictReason

    var body: some View {
        if reason.isHard {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(reason.label)
                .accessibilityLabel(reason.label)
        }
    }
}

// MARK: - Assignment row

private struct AssignmentRow: View {
    let entry: FfiScheduleEntry
    let vm: RotaViewModel
    let shift: FfiShiftInfo
    let isEditMode: Bool
    let isLocked: Bool
    var isCompact: Bool = false

    private var isSwapSource: Bool { vm.isSwapSource(assignmentId: entry.assignmentId) }
    private var isSwapTarget: Bool { vm.isSwapTarget(entry: entry) }
    private var canEdit: Bool { isEditMode && !isLocked }
    private var conflict: ConflictReason? { vm.conflictForAssignment(entry.assignmentId) }

    var body: some View {
        // When a swap target, wrap in a tappable button-style row
        if canEdit && vm.hasSwapSource && isSwapTarget {
            swapTargetRow
        } else {
            baseRow
        }
    }

    // The row shown for a valid swap target — tapping it executes the swap
    private var swapTargetRow: some View {
        Button {
            Task { await vm.executeSwap(targetAssignmentId: entry.assignmentId) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(.white)
                    .frame(width: 16)
                Text(entry.employeeName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                #if os(iOS)
                if !isCompact {
                    Text("Swap")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.85))
                }
                #else
                Text("Swap")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.85))
                #endif
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(.indigo, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // Normal row for all other states
    private var baseRow: some View {
        let employeeName = entry.employeeName
        return HStack(spacing: 6) {
            if canEdit {
                // Name pill — whole container taps to initiate or cancel swap.
                // A small swap glyph sits inside, to the right of the name. The
                // pill carries a faint blue tint+outline that deepens when this
                // row is the active swap source.
                Button {
                    if isSwapSource {
                        vm.cancelSwap()
                    } else if !vm.hasSwapSource {
                        vm.selectSwapSource(assignmentId: entry.assignmentId, shiftId: entry.shiftId)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(employeeName)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        isSwapSource
                            ? Color.blue.opacity(0.22)
                            : Color.blue.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                isSwapSource ? Color.blue : Color.blue.opacity(0.4),
                                lineWidth: 1
                            )
                    )
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(vm.hasSwapSource && !isSwapSource)
                .accessibilityLabel(isSwapSource ? "Cancel swap for \(employeeName)" : "Start swap for \(employeeName)")

                // Delete sits outside the pill — instant remove, no confirm.
                Button {
                    Task { await vm.deleteAssignment(id: entry.assignmentId) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(vm.hasSwapSource)
                .accessibilityLabel("Remove \(employeeName)")
            } else {
                Text(employeeName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Assigned: \(employeeName)")
            }

            if let conflict {
                ConflictGlyph(reason: conflict)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

}

// MARK: - Conflict badge (labeled)

/// Labeled conflict indicator used in the editor's assignment + picker lists.
/// Only hard conflicts render; the soft `.maybe` hint is suppressed.
private struct ConflictBadge: View {
    let reason: ConflictReason

    var body: some View {
        if reason.isHard {
            Label(reason.label, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - Role and staffing section

/// Editable "Role and staffing" form section shared by the shift editor, the
/// add-shift sheet, and the template editor. Min staff is clamped to the
/// role-derived floor (the largest role minimum); empty requirements mean a
/// wildcard shift.
struct RoleStaffingSection: View {
    let roles: [FfiRole]
    @Binding var minStaff: Int
    @Binding var maxStaff: Int
    @Binding var roleReqs: [FfiRoleRequirement]

    /// Largest single role minimum — the floor the overall min can't go below.
    private var floor: Int { roleReqs.map { Int($0.minCount) }.max() ?? 0 }
    private var effMin: Int { max(minStaff, floor) }
    private var availableRoles: [FfiRole] {
        let used = Set(roleReqs.map { $0.role })
        return roles.filter { !used.contains($0.name) }
    }

    var body: some View {
        Section {
            Stepper(
                value: Binding(get: { effMin }, set: { minStaff = $0 }),
                in: max(floor, 1)...99
            ) {
                HStack {
                    Text("Min staff")
                    Spacer()
                    Text("\(effMin)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Stepper(
                value: Binding(get: { max(maxStaff, effMin) }, set: { maxStaff = $0 }),
                in: effMin...99
            ) {
                HStack {
                    Text("Max staff")
                    Spacer()
                    Text("\(max(maxStaff, effMin))").foregroundStyle(.secondary).monospacedDigit()
                }
            }

            ForEach($roleReqs, id: \.role) { $req in
                Stepper(
                    value: Binding(
                        get: { Int(req.minCount) },
                        set: { $req.minCount.wrappedValue = UInt32(max(1, $0)) }
                    ),
                    in: 1...99
                ) {
                    HStack {
                        Text(req.role)
                        Spacer()
                        Text("min \(req.minCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        roleReqs.removeAll { $0.role == req.role }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }

            if !availableRoles.isEmpty {
                Menu {
                    ForEach(availableRoles, id: \.id) { role in
                        Button(role.name) {
                            roleReqs.append(FfiRoleRequirement(role: role.name, minCount: 1))
                        }
                    }
                } label: {
                    Label("Add role", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Role and staffing")
        } footer: {
            if roleReqs.isEmpty {
                Text("Any staff with availability can be assigned.")
            } else {
                Text("One person who holds several required roles covers each of them.")
            }
        }
    }
}

// MARK: - Unified shift editor sheet

/// Single editor for a shift: edit times, manage assigned employees (with
/// availability/overlap warnings), and delete the shift. Opened by tapping a
/// shift card. Replaces the former separate time-edit and employee-picker
/// sheets. Role/capacity are read-only here in this pass.
private struct ShiftEditorSheet: View {
    let vm: RotaViewModel
    let shift: FfiShiftInfo
    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var minStaff: Int
    @State private var maxStaff: Int
    @State private var roleReqs: [FfiRoleRequirement]
    @State private var showAddEmployee = false
    @State private var showDeleteConfirm = false

    init(vm: RotaViewModel, shift: FfiShiftInfo) {
        self.vm = vm
        self.shift = shift
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let base = Calendar.current.startOfDay(for: Date())
        _startDate = State(initialValue: fmt.date(from: shift.startTime) ?? base)
        _endDate = State(initialValue: fmt.date(from: shift.endTime) ?? base)
        _minStaff = State(initialValue: Int(shift.minEmployees))
        _maxStaff = State(initialValue: Int(shift.maxEmployees))
        _roleReqs = State(initialValue: shift.roleRequirements)
    }

    private var assignments: [FfiScheduleEntry] { vm.assignments(for: shift.id) }

    /// Times plus the primary role when the shift has one, e.g.
    /// "09:00–17:00 · Barista". Wildcard shifts show just the times.
    private var subtitleText: String {
        let times = "\(shift.startTime)–\(shift.endTime)"
        return shift.requiredRole.isEmpty ? times : "\(times) · \(shift.requiredRole)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endDate, displayedComponents: .hourAndMinute)
                }

                RoleStaffingSection(
                    roles: vm.roles,
                    minStaff: $minStaff,
                    maxStaff: $maxStaff,
                    roleReqs: $roleReqs
                )

                Section("Assigned") {
                    if assignments.isEmpty {
                        Text("No one assigned")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(assignments, id: \.assignmentId) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.employeeName)
                                    if let conflict = vm.conflict(employeeId: entry.employeeId, shift: shift) {
                                        ConflictBadge(reason: conflict)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await vm.deleteAssignment(id: entry.assignmentId) }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(entry.employeeName)")
                            }
                        }
                    }
                    if assignments.count < Int(shift.maxEmployees) {
                        Button {
                            showAddEmployee = true
                        } label: {
                            Label("Add employee", systemImage: "plus.circle.fill")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete shift", systemImage: "trash")
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Edit \(shift.weekday) \(vm.dayOfMonthLabel(shift.weekday))")
            .navigationSubtitle(subtitleText)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "HH:mm"
                        fmt.locale = Locale(identifier: "en_US_POSIX")
                        let start = fmt.string(from: startDate)
                        let end = fmt.string(from: endDate)
                        // Effective min is clamped to the role-derived floor.
                        let floor = roleReqs.map { Int($0.minCount) }.max() ?? 0
                        let effMin = max(minStaff, floor)
                        let effMax = max(maxStaff, effMin)
                        Task {
                            await vm.updateShiftTimes(id: shift.id, startTime: start, endTime: end)
                            await vm.updateShift(
                                id: shift.id,
                                minEmployees: UInt32(effMin),
                                maxEmployees: UInt32(effMax),
                                roleRequirements: roleReqs
                            )
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddEmployee) {
                AddEmployeePickerSheet(vm: vm, shift: shift)
            }
            .alert("Delete this shift?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        await vm.deleteShift(id: shift.id)
                        dismiss()
                    }
                }
            } message: {
                Text("This shift and all its assignments will be permanently deleted.")
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 440, minHeight: 360, idealHeight: 520)
        #endif
    }
}

// MARK: - Add employee picker sheet

/// Picker for adding an employee to a shift. Candidates that can't work the
/// shift (overlap / no availability / exception) show a warning but stay
/// tappable — the manager can assign anyway (warn but allow).
private struct AddEmployeePickerSheet: View {
    let vm: RotaViewModel
    let shift: FfiShiftInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let available = vm.availableEmployees(for: shift.id)
            Group {
                if available.isEmpty {
                    ContentUnavailableView(
                        "No Available Employees",
                        systemImage: "person.slash",
                        description: Text("Everyone is already assigned to this shift.")
                    )
                } else {
                    List(available, id: \.id) { employee in
                        Button {
                            Task {
                                await vm.addEmployeeToShift(shiftId: shift.id, employeeId: employee.id)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(employee.displayName)
                                Spacer()
                                if let conflict = vm.conflict(employeeId: employee.id, shift: shift) {
                                    ConflictBadge(reason: conflict)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Employee")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 400, minHeight: 300, idealHeight: 450)
        #endif
    }
}

// MARK: - Add shift sheet

private struct AddShiftSheet: View {
    let vm: RotaViewModel
    let date: String
    @Environment(\.dismiss) private var dismiss
    // `Calendar.current.date(bySettingHour:...)` only returns nil if the
    // resulting time doesn't exist (e.g. spring-forward DST gap). The 09:00
    // / 17:00 defaults are picked specifically so this can't happen on any
    // real-world day; if it ever does, we fall back to "now" rather than
    // force-unwrap and crash.
    @State private var startDate = AddShiftSheet.defaultTime(hour: 9)
    @State private var endDate = AddShiftSheet.defaultTime(hour: 17)
    @State private var minStaff = 1
    @State private var maxStaff = 1
    @State private var roleReqs: [FfiRoleRequirement] = []

    private static func defaultTime(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
            ?? Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endDate, displayedComponents: .hourAndMinute)
                }
                RoleStaffingSection(
                    roles: vm.roles,
                    minStaff: $minStaff,
                    maxStaff: $maxStaff,
                    roleReqs: $roleReqs
                )
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Add Shift")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "HH:mm"
                        fmt.locale = Locale(identifier: "en_US_POSIX")
                        let start = fmt.string(from: startDate)
                        let end = fmt.string(from: endDate)
                        let floor = roleReqs.map { Int($0.minCount) }.max() ?? 0
                        let effMin = max(minStaff, floor)
                        let effMax = max(maxStaff, effMin)
                        Task {
                            await vm.createAdHocShift(
                                date: date, startTime: start,
                                endTime: end, requiredRole: "",
                                roleRequirements: roleReqs,
                                minEmployees: UInt32(effMin),
                                maxEmployees: UInt32(effMax)
                            )
                            dismiss()
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 420, minHeight: 260, idealHeight: 340)
        #endif
    }
}

// MARK: - Identifiable conformances for sheet bindings

extension FfiShiftInfo: @retroactive Identifiable {}

/// Wrapper to make a date string usable with `.sheet(item:)`.
private struct SheetDate: Identifiable {
    let id: String
    init(_ date: String) { self.id = date }
}
