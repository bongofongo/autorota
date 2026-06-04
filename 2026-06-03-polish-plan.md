# 2026-06-03 Bug-Fix & UI-Polish Plan

## Context

Core logic and overall UI are in a good place. This pass shifts focus to **bug fixes, UI polish, and UX improvements**. This document is a prioritized roadmap (bugs first, then polish) capturing the user's ideas plus the root causes already located during exploration. No code is changed by this document — it is the execution backlog.

---

## P0 — Bugs

### 1. Menu "Other Pages" navigation breaks after first push
**Symptom:** Tapping a page from the Menu's "Other Pages" loads a blank screen ~1s, then dismisses, and disables any further navigation to other menu pages.

**Root cause (already documented):** Nested `NavigationStack`. The Menu page (`SettingsView.swift:62`) wraps content in a `NavigationStack` and pushes via `navigationDestination(for: TabPage.self)` → `page.destinationView` (`TabPage.swift:62-73`). Each destination (`RotaView`, `EmployeeListView`, `EditLogView`, etc.) wraps **itself** in its own `NavigationStack`. On pop, iOS 26 leaves the outer stack inert and swallows subsequent `NavigationLink` taps. See `bugs/unpatched/menu-other-pages-untappable-after-first-nav.md`.

**Dead plumbing to remove:** `MenuNavigationBridge` (`MenuNavigationBridge.swift`, written at `ContentView.swift:62-66`) is no longer read after a prior failed patch.

**Fix approach:** Give each `TabPage.destinationView` a context flag so that when rendered as a *pushed menu destination* it does **not** create its own `NavigationStack` (reuse the outer one). Options: pass an `embedInNavigationStack: Bool` (default true for tab-root use, false for menu-push), or strip the inner `NavigationStack` and let the single outer stack own navigation. Then delete the dead `MenuNavigationBridge`.

**Files:** `TabPage.swift:62-73`, `SettingsView.swift:62,241-243`, each destination view, `MenuNavigationBridge.swift`, `ContentView.swift:62-66`.

### 2. Exceptions: no grid border + don't persist as exceptions
**Symptoms:** (a) Exception days show **no border** on the availability grid. (b) Saving an exception changes the day's availability but it is **not classified as an exception** (absent from the Exceptions list).

**Root cause — single bug, both symptoms:**
- Border is drawn only for `override.source == "exception"` (`WeeklyAvailabilityView.swift:166`; same in `CarouselAvailabilityView.swift:151` and `EmployeeEditSheet.swift` outlined set).
- Exceptions list filters `source == "exception"` (`OverridesTabView.swift:56`).
- Per-date grid edits write `source = existing?.source ?? "manual"` (`WeeklyAvailabilityView.swift:338`), creating `"manual"` rows.
- The Rust upsert (`queries.rs:1149-1162`) `ON CONFLICT(employee_id, date) DO UPDATE` **deliberately never updates `source`**. So saving an exception over an existing `"manual"` row keeps it `"manual"` → no border, not in list, even though availability is written.

**Fix:** Allow promotion to `"exception"` while never downgrading. In `upsert_employee_availability_override`:
```sql
ON CONFLICT(employee_id, date) DO UPDATE SET
  availability = excluded.availability,
  notes = excluded.notes,
  source = CASE WHEN excluded.source = 'exception'
                THEN 'exception'
                ELSE employee_availability_overrides.source END,
  last_modified = excluded.last_modified,
  sync_status = 0
```
This makes `"exception"` sticky (grid edits passing `"manual"` won't downgrade) and lets the Exceptions UI promote a `"manual"` row. Update the comment at `queries.rs:1144-1148` to match. Add/adjust a Rust unit test (promotion + no-downgrade). Rebuild XCFramework after the core change.

**Files:** `crates/autorota-core/src/db/queries.rs:1138-1164` (+ test). No Swift change required for the fix; verify border + list afterward.

### 3. Error alerts: unprofessional copy + swallowed errors
**Symptoms:** Generic `.alert("Error")` with raw `error.localizedDescription`; some VM errors never surfaced (e.g. `OverridesTabView` has no `.alert`, so a failed save dismisses silently).

**Findings:** Generic alert pattern repeated across 8 views (`RotaView.swift:146-150`, `EmployeeListView.swift:125-129`, `ShiftTemplateListView.swift:198-202`, `AnalyticsView`, `ExportSheetView`, `EmployeeShiftHistoryView`, `RosterImportView`, `SendSchedulePicker`). Non-FFI errors fall back to raw system strings (`FfiError+UserMessage.swift:41`). `OverrideViewModel` sets `error` but the tab never presents it.

**Fix approach:**
- Introduce one reusable error-presentation modifier (e.g. `.errorAlert($vm.error)`) with a friendly title, clean message, and an optional **Retry**; replace the 8 ad-hoc alerts.
- Audit `userFacingMessage` so non-FFI/system errors map to friendly copy instead of raw `localizedDescription`.
- Wire the modifier into `OverridesTabView` (currently missing) so save failures are visible.

**Files:** new `Shared/ErrorAlert.swift` (or extend `FfiError+UserMessage.swift`), the 8 views above, `OverridesTabView.swift`.

---

## P1 — UI Polish

### 4. Rota tab cleanup
- **Remove Current/Future/Past pills** (`CategoryBadge`, `RotaView.swift:281-309`). Replace with **very subtle date-range text coloring** — tint `vm.weekDateRangeShort` (header at `RotaView.swift:76-98`) with a low-saturation hue per `WeekCategory` (`RotaViewModel.swift:15-73`). Keep it understated.
- **Align employees to weekday columns.** Today employees stack vertically inside each `ShiftCard` (`RotaView.swift:562-630`, `AssignmentRow:653-758`); landscape lays out day columns but does not align employees across them. Restructure so assignment rows line up with the correct weekday column.
- **Stack shift time ranges like Apple Calendar.** Header currently shows times side-by-side (`RotaView.swift:577-587`); stack start over end vertically.

### 5. "Shifts roles shifts" naming
Tab is "Shifts" (`TabPage.swift:24`); the page then has section headers "Roles" (`ShiftTemplateListView.swift:66`) and "Shifts" (`:124`), reading as "Shifts → Roles → Shifts". Rename the second section to **"Shift Templates"** (or "Shift Types") for a clear hierarchy. Also revisit the cross-reference copy at `EmployeeEditSheet.swift:202`.

### 6. Shift roles via open text cell
Shift-level role requirements currently use a Menu picker of existing roles (`RoleStaffingSection`, `RotaView.swift:843-852`). Add a **free-text entry** to add a role inline (mirroring `AddRoleSheet`'s `TextField`, `ShiftTemplateListView.swift:225`), creating the role on the fly if new. Keep the picker for existing roles.

### 7. Menu tab ordering
Default order is hardcoded in `TabPage.defaultTabBar` / `configurablePages` (`TabPage.swift:76-91`); hidden pages computed at `:110-116`, reorderable in `SettingsView.swift:131-189`. Define a more sensible default ordering for the Menu's "Other Pages" list and the configurable defaults.

### 8. Reduce page length / compress repetitive info
Cross-cutting density pass: collapse repeated labels, tighten section spacing, reorder so the most-used controls sit first. Primary targets: `OverridesTabView`, `RotaView` shift cards, `ShiftTemplateListView`, `EmployeeEditSheet`. Do per-page after the structural fixes above land.

---

## P2 — Features

### 9. Availability grid touch-and-hold multi-select
Grid already has a drag-rectangle "selection mode" gated behind a toggle (`AvailabilityGridView.swift:57-122`, `311-361`). Add **touch-and-hold to paint**: long-press a cell to begin a drag that paints cells directly (no mode toggle), updating state continuously. Reuse the existing rect/`toggleSelectedCells` logic; add a `LongPressGesture`→`DragGesture` sequence. Keep the explicit selection-mode toggle as fallback.

**Files:** `AvailabilityGridView.swift` (gesture block ~107-122, cell hit-testing).

### 10. Edit Log audit ("needs to be perfect")
Structure is solid (`EditLogView.swift`, `EditLogViewModel.swift`): grouped saves, lazy diff load, tags, restore with confirmation + toast. Rough spots to harden:
- Change-kind strings are hardcoded in `ChangeRow.category` (`EditLogView.swift:382-398`) — silent fallthrough to `.modified` if Rust strings change. Centralize/enum them.
- Restore toast reports skipped-assignment counts but not **which/why** (`EditLogViewModel.swift:160-179`).
- `FfiChangeDetail` optionals can render as "?" in edge cases (`ChangeRow:424-491`).
- macOS tag popover UX (`presentationCompactAdaptation(.popover)`) on small windows.
Treat as a focused review pass once P0/P1 land.

---

## Deferred

### Finer availability granularity (half-hour / sub-hour)
Deferred per decision. Current model is hourly: `Availability(HashMap<(Weekday,u8),State>)` (`availability.rs`), per-date `DayAvailability(HashMap<u8,State>)` (`overrides.rs:11-13`), grid 7×24. Future options when revisited: (a) touch-hold **zoom** to subdivide a single cell (mixed-resolution, sparse `u16` slots); (b) global 30-min grid (`u8` 0–47); (c) configurable 60/30/15 setting. All require model + serde + FFI + scheduler + grid changes. Capture here; do not build now.

---

## Verification

- **Exceptions (P0.2):** `cargo test` for the new upsert promotion test. Then build XCFramework (`make swift-build-xcframework-debug`), run app: create a per-date manual edit, then add an exception on the same day → confirm orange column border appears AND the row shows in the Exceptions list. Confirm a later grid edit does not strip the exception.
- **Menu nav (P0.1):** Build, open Menu → tap an Other Page → back → tap a different Other Page repeatedly. No blank/dismiss, navigation stays live.
- **Error alerts (P0.3):** Force a save failure (e.g. offline) in Overrides and Rota → friendly alert appears with Retry; nothing dismisses silently.
- **Polish (P1):** Visual check on iPhone 17 Pro Max sim (rebuild + relaunch after SwiftUI edits). Compile-check via `make swift-build-check` before sim runs.
- General: `cargo fmt && cargo clippy && cargo test` for any Rust change; `make swift-build-check` after Swift edits.
