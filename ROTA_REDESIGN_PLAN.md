# Rota (Schedule) Tab Redesign Plan

## Context

The Rota tab's interaction model is dated: editing hides behind a global **view-only ⇄ edit-only** toggle, so adding/changing a shift takes multiple steps and managers get no feedback when they assign someone who can't actually work. The visual design (gray-rectangle day containers, boxed shift cards) is heavier than it needs to be. This change makes editing **direct** (tap a shift to edit, tap a day title to add), **safe** (warn when an assignment conflicts with availability or an existing booking), and **lighter** (Apple-Calendar-style day headers). Edit mode is **kept** but demoted to a secondary toggle whose only remaining job is the in-grid swap gesture.

Scope is **Swift-only** — all conflict detection is computed app-side from data already loaded over FFI; no Rust/core changes required.

## Decisions (resolved with user)

- **Edit mode kept, demoted.** Tapping a shift opens the editor and tapping a day title adds a shift **at any time** (no toggle). The edit-mode toggle stays, but its *only* extra power is the existing in-grid **swap** gesture. Swap logic is untouched.
- **Conflicts warn but allow.** Manager can always assign anyway; we surface a ⚠️ + reason.
- **Three hard-conflict reasons** (window resolves to `No`): overlapping existing booking, weekly-template "No", date exception/override "No". `Maybe` → soft amber hint. Shown **both on the grid and in the editor**.
- **Unified shift editor** replaces the separate time-edit + employee-picker sheets. Edits **times + assigned employees + delete**. Role/capacity shown **read-only** (mutating them on a materialized shift needs new FFI — deferred).
- **Calendar restyle = day-header underline only** for now (past/today/future muted colors). Shift-card vertical-compression redesign is **deferred** to a later pass.
- **"Rota" title removed.**
- **Past-week guard:** confirm on **first edit** of a past-week shift, then unlocked for the rest of the visit (replaces the old confirm-on-enter-edit-mode).

## Work items

### 1. Remove the "Rota" title
`RotaView.swift:89` — drop `.navigationTitle("Rota")` (keep `.navigationBarTitleDisplayMode(.inline)` so the bar stays compact). The week picker (`WeekPickerView`, "Week of …") already serves as the header.

### 2. Always-on tap-to-edit / tap-day-to-add; demote edit mode
- **Tap a shift card → unified editor** regardless of `vm.isEditMode`. In `ScheduleGridView`, make `ShiftCard` open `activeSheet = .shiftEditor(shift)` on tap (both portrait `RotaView.swift:459` and landscape `:554`).
- **Tap a day header → add shift.** Make the `Section` header / `dayColumn` header (`RotaView.swift:488` and `:533`) a button → `activeSheet = .addShift(SheetDate(vm.dateForWeekday(day)))`. Remove the edit-mode-gated inline "Add Shift" button (`:479`, `:570`) since the header now does it always.
- **Demote edit mode:** keep the toggle + checkmark/ellipsis menu (`overflowMenu`, `overflowActions`, `RotaView.swift:212-275`) and keep `enterEditMode`/`exitEditMode`/auto-save (`RotaViewModel.swift:142-189`). Edit mode now *only* enables the in-grid swap interaction in `AssignmentRow` (`RotaView.swift:712-822`). Remove edit-mode-only inline affordances that the editor now owns: the per-shift trash, the inline time-edit pencil button, and the per-assignment "Add"/`xmark` buttons inside `ShiftCard`/`AssignmentRow` — those move into the editor. The swap name-tag path in `AssignmentRow` stays gated on `canEdit` (edit mode).
- **Sheet enum:** replace `.employeePicker` + `.timeEdit` cases in `ScheduleSheet` (`RotaView.swift:361-373`) with a single `.shiftEditor(FfiShiftInfo)`; keep `.addShift`.

### 3. Unified shift editor sheet
New `ShiftEditorSheet` (in `RotaView.swift`, replacing `EmployeePickerSheet` + `ShiftTimeEditSheet`):
- **Times:** reuse the start/end `DatePicker` + `HH:mm` parsing from `ShiftTimeEditSheet` (`RotaView.swift:878-935`) → `vm.updateShiftTimes`.
- **Role / capacity:** display read-only (`shift.requiredRole`, `min/maxEmployees`). Note in UI these are template-level today.
- **Assigned employees:** list current `vm.assignments(for: shift.id)` with a remove (`vm.deleteAssignment`) per row, each row showing a ⚠️ + reason if that employee has a conflict (see §4).
- **Add employee:** inline picker over `vm.availableEmployees(for:)` (`RotaViewModel.swift:374`); each candidate row shows its conflict badge/reason but stays tappable → `vm.addEmployeeToShift` (warn-but-allow). Reuse `AddShiftSheet`'s role picker pattern only as needed.
- **Delete shift** action at the bottom → existing delete-confirm path (`shiftToDelete`).
- Keep `AddShiftSheet` (`RotaView.swift:939-1005`) for new shifts (now reachable from the day header at any time).

### 4. Conflict-detection engine + warning UI
New file `ShiftConflict.swift` (model + pure functions) consumed by `RotaViewModel`:
- `enum ConflictReason { case overlap(String), noAvailability, exception, dateOverride, maybe }` (carry a short human string for overlap, e.g. "Already on 12:00–16:00").
- **Overlap:** from `schedule.entries` (each carries `employeeId`, `date`, `startTime`, `endTime`) — same `employeeId`, same `date`, different `shiftId`, with `startA < endB && startB < endA` on `HH:mm`→minutes. (Note same-day assumption; flag overnight as a follow-up.)
- **Availability window:** mirror Rust `Availability::for_window` / `DayAvailability::for_window` exactly (`crates/autorota-core/src/models/availability.rs:112`, `overrides.rs:53`): `startHour = Int(startTime[0..2])`, `endHour = Int(endTime[0..2])`, hours = `endHour > startHour ? startHour..<endHour : (startHour..<24)+(0..<endHour)`; worst state across hours (`No` > `Maybe` > `Yes`). Matches `Shift::start_hour/end_hour` (hour-truncated).
- **Effective state for (employee, date):** if a date override exists for that `employeeId+date` use its `DayAvailability`; else the employee's weekly `availability`. Distinguish reason by the override's `source`: `"exception"` → `.exception`, `"manual"` → `.dateOverride`; weekly `No` → `.noAvailability`; any `Maybe` → `.maybe` (soft).
- **Data sources (already exposed):** `FfiEmployee.availability` (weekly slots) is on `vm.employees` (loaded in `enterEditMode`; load it on `loadSchedule` too so warnings work without entering edit mode). Date overrides via `service.listAllEmployeeAvailabilityOverrides()` (`AutorotaServiceProtocol.swift:59`) cached by `employeeId+date` on schedule load.
- **ViewModel API:** `func conflict(employeeId: Int64, shift: FfiShiftInfo) -> ConflictReason?` used by both the grid and the editor.
- **Grid UI:** in `AssignmentRow` (`RotaView.swift:712`), show a ⚠️ (amber dot for `.maybe`) next to the name when `vm.conflict(...)` is non-nil; accessibility label includes the reason. Editor reuses the same call.

### 5. Calendar day-header restyle (underline)
Replace the `.background(.regularMaterial)` day-header container in both layouts (`RotaView.swift:488-499` portrait, `:533-543` landscape) with a minimalist header: weekday text + a thin bottom **underline** (overlay/`Divider`-style rule) tinted by time alignment — past = `.secondary`/gray (muted), today = accent (`.blue` ~ existing `DayFlourish`), future = faint/tertiary. Reuse `vm.isDayToday` / `vm.isDayPast` (`RotaViewModel.swift:319-331`). `DayFlourish` (`RotaView.swift:589`) can be folded into the underline color or kept as a small accent. Keep shift cards' current look this pass.

### 6. Past-week confirm-on-first-edit
Replace the `onChange(of: vm.isEditMode)` past-unlock prompt (`RotaView.swift:444-448`) with a guard triggered on the **first edit action** while `vm.weekCategory == .past && !vm.pastUnlocked`: opening the editor's save, add/remove employee, add shift, or delete on a past-week shift shows the existing `showUnlockPastConfirmation` alert; confirming sets `vm.pastUnlocked = true` for the rest of the visit. Keep `isShiftLocked`/`isDayLocked`/`pastUnlocked` (`RotaViewModel.swift:300-327`) and the reset on week change.

## Deferred (future todos, not this pass)
- **Shift-card redesign:** vertically compress, left-justified, flatten the rounded box/shadow (`ShiftCard`, `RotaView.swift:610-708`).
- **Role/capacity editing on materialized shifts:** needs new core + FFI (`updateShift`-style) — only `updateShiftTimes`/`deleteShift`/`createAdHocShift` exist today.
- **Overnight-shift overlap** correctness in the conflict check.

## Critical files
- `platforms/apple/Apps/AutorotaApp/Views/RotaView.swift` — title, grid headers/underline, tap gestures, `ScheduleSheet` enum, new `ShiftEditorSheet`, conflict badges, past-edit guard.
- `platforms/apple/Apps/AutorotaApp/ViewModels/RotaViewModel.swift` — load `employees`+overrides on `loadSchedule`, `conflict(...)` API, past-unlock-on-first-edit; keep edit/swap/auto-save.
- `platforms/apple/Apps/AutorotaApp/Views/ShiftConflict.swift` *(new)* — `ConflictReason` + detection mirroring Rust `for_window`.
- Reference (mirror, do not edit): `crates/autorota-core/src/models/availability.rs:98-124`, `overrides.rs:39-63`, `shift.rs:58-67`.

## Verification
- `make swift-build-check` (macOS + iOS + iPad compile) after editing Swift.
- ViewModel unit tests (no XCFramework): extend `AutorotaAppTests/RotaViewModelTests.swift` with `MockAutorotaService` fixtures covering `conflict(...)`: (a) overlapping booking, (b) weekly `No`, (c) exception override `No`, (d) manual override `No`, (e) `Maybe` → soft, (f) `Yes`/clear → nil. Run `make swift-test-app-macos`.
- Manual (sim — rebuild + relaunch iPhone 17 Pro Max after visual changes): confirm tap-shift opens editor without edit mode; tap day header adds a shift; assigning a conflicted employee is allowed and shows ⚠️ on grid + editor; day headers render the past/today/future underline; no "Rota" title; editing a past week prompts once on first edit.
