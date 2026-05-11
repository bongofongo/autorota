# AutoRota — iOS Bug List

## Formatting rules
- Each bug: `### N. Short title` heading
- Status line: `**Status:** open | in-progress | fixed | wontfix`
- Required subsections: **Repro**, **Expected**, **Actual**, **Root cause**, **Fix sketch**, **Files**
- Optional: **Notes** for related observations
- Append new bugs at the bottom; renumber only if reordering by severity
- Mark fixed bugs with `**Status:** fixed` and a one-line reference to the commit/PR — keep them in the file as a changelog until next release, then archive

---

### 1. Shift tab flickers list placeholder before settling on empty state
**Status:** fixed (this commit)

**Repro**
1. Launch app on iOS sim with no roles and no shift templates seeded
2. Tap any non-Shifts tab, then tap the Shifts tab
3. Observe the screen during the swap

**Expected**
- Tapping Shifts tab settles directly on the `ContentUnavailableView` ("empty.shifts.title" — clock.badge.plus + "Add shift" button) with no intermediate frame

**Actual**
- A brief flash of the `List`-based template appears first: "Roles" section with grey "No roles yet" placeholder row, "Shifts" section with grey "No shifts yet" placeholder row
- Screen then resolves to the `ContentUnavailableView`

**Root cause**
- `ShiftTemplateListView.isFullyEmpty` (lines 16–19) gates the CUV on `!vm.isLoading && !roleVM.isLoading && vm.templates.isEmpty && roleVM.roles.isEmpty`
- `ShiftTemplateViewModel` and `RoleViewModel` both initialise `isLoading = false`
- Render sequence on tab activation:
  1. View mounts: `isLoading = false` for both VMs, both arrays empty → `isFullyEmpty = true` → CUV path
  2. `.task` modifier fires `vm.load()` and `roleVM.load()`, each sets `isLoading = true` → `isFullyEmpty = false` → `listContent` shown (placeholder rows render here)
  3. Loads complete: `isLoading = false`, arrays still empty → `isFullyEmpty = true` → CUV path again
- The flicker is step 2. Tab switching tears down the view, so this runs every time.

**Fix sketch**
- [x] Add `var hasLoaded = false` to `ShiftTemplateViewModel` and `RoleViewModel`; set `true` at end of `load()` (in both success and error paths)
- [x] Change `isFullyEmpty` to require `vm.hasLoaded && roleVM.hasLoaded` before deciding either branch
- [x] While not yet loaded: render a neutral placeholder (empty `Color.clear` or a low-key `ProgressView`) instead of `listContent` — must NOT render the list with empty placeholder rows (using `Color.clear`)
- [ ] Alternative: collapse to a single load step that pre-checks counts via FFI before mounting either branch (heavier; prefer the `hasLoaded` flag) — _not pursued, `hasLoaded` flag chosen_
- [ ] Add a snapshot or UI test that mounts the view, runs the `.task`, and asserts no `"No roles yet"` / `"No shifts yet"` text ever appears when the final state is the CUV

**Files**
- `platforms/apple/Apps/AutorotaApp/Views/ShiftTemplateListView.swift:16-19, 116-141`
- `platforms/apple/Apps/AutorotaApp/ViewModels/ShiftTemplateViewModel.swift:9-28`
- `platforms/apple/Apps/AutorotaApp/ViewModels/RoleViewModel.swift:7-26`

---

### 2. Rota empty-state "Add employee" button does not switch tab when Employees is in overflow Menu
**Status:** open (prior fix sketch landed but bug still reproduces — needs re-investigation)

**Repro**
1. Settings → Tab Bar layout: remove Employees from the configurable tab bar (so it lives only in the overflow Menu tab)
2. Ensure no employees exist in the database
3. Open the Rota tab → empty-state CUV appears with the "Add employee" button (`empty.rota.action`)
4. Tap "Add employee"

**Expected**
- App switches to the Employees page (via the Menu tab when not in the tab bar) and opens the new-employee sheet

**Actual**
- App stays on the Rota tab. The new-employee sheet does not present. Nothing visible happens.
- When Employees IS in the active tab bar, the same button works correctly (tab switches and sheet presents)

**Root cause**
- `RotaView` empty-state button sets `employeeBridge.requestNewEmployeeSheet = true` (RotaView.swift:69)
- `ContentView.onChange(of: employeeBridge.requestNewEmployeeSheet)` reacts by setting `selection = .page(.employees)` (ContentView.swift:56-60)
- When Employees has been removed from the tab bar, `TabLayoutManager.tabBarPages` does not contain `.employees` (TabLayoutManager.swift:102-108) — only configured pages + `.settings` are emitted as `Tab(value:)` entries
- SwiftUI's `TabView(selection:)` silently drops a selection value that matches no `Tab` — selection state stays on `.rota`, so no navigation occurs
- `EmployeeListView` (which would observe `requestNewEmployeeSheet` and present the sheet) is never instantiated because the Menu/Settings tab does not host it inline

**Fix sketch**
- [x] In `ContentView.onChange(of: employeeBridge.requestNewEmployeeSheet)`:
  - [x] If `layoutManager.tabBarPages.contains(.employees)` → keep current behaviour (`selection = .page(.employees)`)
  - [x] Else → `selection = .page(.settings)` AND push a navigation request through a new bridge field (e.g. `MenuNavigationBridge.pendingDestination = .employees`) for `SettingsView` / Menu page to consume on appear
- [x] `SettingsView` (Menu page) needs an `.onChange` or `.onAppear` that, when a pending destination is set, programmatically navigates to the Employees row inside its `NavigationStack` (use `NavigationPath` binding so we can append `.employees` from outside)
- [x] After the Employees view appears, `EmployeeListView`'s existing `requestNewEmployeeSheet` observer presents the add sheet — leave that flag set until consumed, then reset
- [x] Reset both flags after consumption to prevent re-fire on next tab switch
- [ ] Add UI test: with Employees removed from tab bar + zero employees, tap empty-state CTA → assert Menu tab active AND add-employee sheet visible
- [ ] Same fix likely needed for any other CTA that targets a tab that may live in overflow (audit `RotaView`, onboarding, etc.) — _follow-up audit_

**Files**
- `platforms/apple/Apps/AutorotaApp/Views/ContentView.swift:56-60`
- `platforms/apple/Apps/AutorotaApp/Views/RotaView.swift:61-75`
- `platforms/apple/Apps/AutorotaApp/Views/Shared/EmployeeUIBridge.swift`
- `platforms/apple/Apps/AutorotaApp/Views/TabPage.swift:102-116` (overflow logic)
- `platforms/apple/Apps/AutorotaApp/Views/SettingsView.swift` (Menu host — add navigation injection)
- `platforms/apple/Apps/AutorotaApp/Views/EmployeeListView.swift` (existing sheet-trigger observer)

**Notes**
- macOS path is unaffected: `tabBarPages` always returns the full configurable list on macOS (TabLayoutManager.swift:103-104), so `.employees` is always present
- iPad uses the same `selection` binding via `iPadAdaptiveTabView`, so the same fix covers iPad overflow

---

### 3. "Required role" Picker in shift template editor cannot be opened
**Status:** open

**Repro**
1. Launch app on iOS sim with at least one role seeded (e.g. "Barista")
2. Shifts tab → tap `+` on Shifts section header (or tap an existing template row)
3. `ShiftTemplateEditSheet` opens; scroll to the "Role & Staffing" section
4. Tap the "Required role" row (default value "Any Role")

**Expected**
- Picker opens (navigationLink push or inline menu) listing "Any Role" + every role from `roles`
- Selecting a different role updates the row's trailing value and dismisses the picker

**Actual**
- Tap on the row produces no visible response — no navigation, no menu, no haptic
- Same Picker pattern in `RotaView.AddShiftSheet` (RotaView.swift:962-967) works correctly, so the issue is local to `ShiftTemplateEditSheet`

**Root cause**
- Working hypothesis (partially disproven): `ShiftTemplateEditSheet`'s Form had `.dismissesKeyboardOnTap()` (ShiftTemplateListView.swift:326), which originally attached a top-level `onTapGesture` (PlatformAffordances.swift:58-69) that swallowed Picker row taps
- Attempted fix swapped that to `simultaneousGesture(TapGesture)` so the dismiss handler fires alongside child gestures — Picker still inert after rebuild
- So the gesture conflict is _at most_ a contributing factor; primary cause is still unknown
- Candidates to investigate:
  - Default Picker style in a sheet-hosted `Form` inside `NavigationStack` on iOS 26.2 may differ from Rota's `AddShiftSheet` context
  - `Stepper.onChange(of: minStaff)` (ShiftTemplateListView.swift:316) writing back to `maxStaff` may force a body re-evaluation that resets gesture state
  - Section header `HStack` containing the `+` button (added in commit `04bbb08`) may capture hit-testing
  - The simultaneous `Toggle` "Everyday" binding's `get:` does a `Set` equality check on every render — high churn but should be inert

**Fix sketch**
- [ ] Remove `.dismissesKeyboardOnTap()` from `ShiftTemplateEditSheet` entirely and rebuild — confirms whether the helper is involved at all
- [ ] If Picker now works without the helper: replace keyboard dismissal with `@FocusState` cleared from a TextField `onSubmit`, or use built-in `.scrollDismissesKeyboard(.immediately)` on the Form (no gesture overlap)
- [ ] If Picker still broken without the helper: minimise the form to just the Picker, then re-add sections one by one until it breaks — bisect
- [ ] Cross-check `EmployeeEditSheet` (EmployeeEditSheet.swift:430 also calls `.dismissesKeyboardOnTap()`) — does it contain a Picker, and does that Picker work? Establishes whether the helper alone is sufficient to break Pickers
- [ ] Try explicit `.pickerStyle(.navigationLink)` and `.pickerStyle(.menu)` on the Required Role Picker to rule out style-resolution issues
- [ ] Verify on physical device — sim-only quirks have happened before
- [ ] Add a UI test: open new-shift sheet, tap Required Role, assert role list visible

**Files**
- `platforms/apple/Apps/AutorotaApp/Views/ShiftTemplateListView.swift:301-311` — Picker definition
- `platforms/apple/Apps/AutorotaApp/Views/ShiftTemplateListView.swift:326` — `.dismissesKeyboardOnTap()` call site
- `platforms/apple/Apps/AutorotaApp/AutorotaApp/DesignSystem/Components/PlatformAffordances.swift:58-72` — helper definition (recently changed from `onTapGesture` to `simultaneousGesture`, uncommitted)
- `platforms/apple/Apps/AutorotaApp/Views/RotaView.swift:957-1005` — working Picker for comparison
- `platforms/apple/Apps/AutorotaApp/Views/Shared/Content/EmployeeEditSheet.swift:430` — other consumer of `dismissesKeyboardOnTap()`

**Notes**
- The `simultaneousGesture` refactor of `dismissesKeyboardOnTap()` is uncommitted on disk. Keep or revert pending bisect — `simultaneousGesture` is generally safer than `onTapGesture` for forms regardless of whether it fully resolves this bug
- Default selection state: `role = ""` maps to the `Text("Any Role").tag("")` row. Picker should still be openable when only one option exists

---

### 4. Menu tab "Other Pages" rows un-tappable after first navigation
**Status:** open. One fix attempt on 2026-04-30 (removed `NavigationPath` binding from `SettingsView`) failed — bug still reproduces. Detailed write-up + next steps in `bugs/unpatched/menu-other-pages-untappable-after-first-nav.md`. Side effect of the failed attempt: `MenuNavigationBridge.pendingDestination` no longer has a consumer (dead plumbing in `ContentView.swift:62-66`); bug #2 status unchanged.

**Repro**
1. Launch app on iOS sim from a fresh state
2. Switch to the Menu tab (the overflow Settings/Menu tab)
3. Under the "Other Pages" section, tap one entry (e.g. "Exceptions") — it opens correctly
4. Tap the back chevron to return to Menu
5. Tap a different "Other Pages" entry (e.g. "Edit Log")

**Expected**
- Tapped row navigates to the destination view (push transition into `EditLogView`)

**Actual**
- Row briefly highlights dark grey but no navigation occurs. Stays on Menu.
- Subsequent taps on any "Other Pages" row do nothing
- Did not occur before the bug #2 fix sketch landed (`SettingsView.navPath` + `MenuNavigationBridge`)

**Root cause**
- Strong suspicion: nested NavigationStacks. `SettingsView` body wraps content in `NavigationStack(path: $navPath)` (SettingsView.swift:65) and registers `.navigationDestination(for: TabPage.self) { page in page.destinationView }` (SettingsView.swift:244). `page.destinationView` (TabPage.swift:62-73) returns full top-level views (`EditLogView()`, `OverridesTabView()`, etc.) — most of which wrap themselves in their own `NavigationStack`. Pushing one of these onto the outer path nests stacks; SwiftUI's pop+re-push behaviour on nested `NavigationStack` instances is known to leave the outer path in a state where subsequent `NavigationLink(value:)` taps are ignored.
- Secondary suspect: `consumePendingMenuDestination()` may fire on `.onAppear` after pop and silently mutate `navPath` if `pendingDestination` is non-nil from a prior interaction, racing with the user's tap.

**Fix sketch**
- [ ] Audit `EditLogView`, `OverridesTabView`, `AnalyticsView`, `ExportTabView`, `EmployeeListView`, `RotaView`, `ShiftTemplateListView` — each, check whether body starts with `NavigationStack`. If so, the inner stack must be removed when hosted as a `navigationDestination` (or the outer stack's destination should unwrap to the inner content)
- [ ] Cleanest fix: introduce a `var menuDestinationView: some View` on `TabPage` that returns the inner content WITHOUT a NavigationStack wrapper, and use that from `SettingsView.navigationDestination` instead of `destinationView`. Keep `destinationView` for direct tab-bar hosting where the wrapper is wanted
- [ ] Add an explicit guard in `consumePendingMenuDestination()` so it never fires from `.onAppear` triggered by a pop (only from external `MenuNavigationBridge` writes) — e.g. compare a sequence number or only consume when navPath is empty
- [ ] Manual verification: from fresh state, open every Other Pages entry in sequence (Exceptions, Edit Log, Analytics, Export) without app restart — each tap should push correctly

**Files**
- `platforms/apple/Apps/AutorotaApp/Views/SettingsView.swift:65, 244-258` — outer NavigationStack + destination registration + pendingDestination consumer
- `platforms/apple/Apps/AutorotaApp/Views/TabPage.swift:62-73` — `destinationView` returns wrapped views
- `platforms/apple/Apps/AutorotaApp/Views/EditLogView.swift` — verify NavigationStack wrapping
- `platforms/apple/Apps/AutorotaApp/Views/Shared/MenuNavigationBridge.swift` — bridge that may re-fire
- `platforms/apple/Apps/AutorotaApp/Views/ContentView.swift:62-66` — bridge writer
