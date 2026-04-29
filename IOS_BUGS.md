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
**Status:** open

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
- Add `var hasLoaded = false` to `ShiftTemplateViewModel` and `RoleViewModel`; set `true` at end of `load()` (in both success and error paths)
- Change `isFullyEmpty` to require `vm.hasLoaded && roleVM.hasLoaded` before deciding either branch
- While not yet loaded: render a neutral placeholder (empty `Color.clear` or a low-key `ProgressView`) instead of `listContent` — must NOT render the list with empty placeholder rows
- Alternative: collapse to a single load step that pre-checks counts via FFI before mounting either branch (heavier; prefer the `hasLoaded` flag)
- Add a snapshot or UI test that mounts the view, runs the `.task`, and asserts no `"No roles yet"` / `"No shifts yet"` text ever appears when the final state is the CUV

**Files**
- `platforms/apple/Apps/AutorotaApp/Views/ShiftTemplateListView.swift:16-19, 116-141`
- `platforms/apple/Apps/AutorotaApp/ViewModels/ShiftTemplateViewModel.swift:9-28`
- `platforms/apple/Apps/AutorotaApp/ViewModels/RoleViewModel.swift:7-26`

---

### 2. Rota empty-state "Add employee" button does not switch tab when Employees is in overflow Menu
**Status:** open

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
- In `ContentView.onChange(of: employeeBridge.requestNewEmployeeSheet)`:
  - If `layoutManager.tabBarPages.contains(.employees)` → keep current behaviour (`selection = .page(.employees)`)
  - Else → `selection = .page(.settings)` AND push a navigation request through a new bridge field (e.g. `MenuNavigationBridge.pendingDestination = .employees`) for `SettingsView` / Menu page to consume on appear
- `SettingsView` (Menu page) needs an `.onChange` or `.onAppear` that, when a pending destination is set, programmatically navigates to the Employees row inside its `NavigationStack` (use `NavigationPath` binding so we can append `.employees` from outside)
- After the Employees view appears, `EmployeeListView`'s existing `requestNewEmployeeSheet` observer presents the add sheet — leave that flag set until consumed, then reset
- Reset both flags after consumption to prevent re-fire on next tab switch
- Add UI test: with Employees removed from tab bar + zero employees, tap empty-state CTA → assert Menu tab active AND add-employee sheet visible
- Same fix likely needed for any other CTA that targets a tab that may live in overflow (audit `RotaView`, onboarding, etc.)

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
