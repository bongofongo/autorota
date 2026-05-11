# Bug Log

Concise running log of bugs encountered. Each entry is one bullet with sub-bullets. New entries appended at top. Patched entries remain `pending verification` until the user confirms.

- **Menu tab "Other Pages" rows un-tappable after first navigation**
  - Date fixed: —
  - Where / what / repro: Menu tab → "Other Pages" section. After tapping one entry (e.g. Exceptions) and returning, tapping a second entry (e.g. Edit Log) only flashes the row dark grey — no navigation. Repro from a fresh state: open Menu, tap Exceptions, go back, tap Edit Log.
  - Patched: no — one fix attempt failed, see `bugs/unpatched/menu-other-pages-untappable-after-first-nav.md`
  - Fix: n/a (open). Hypothesis: nested NavigationStacks (every destination view wraps itself in its own `NavigationStack`).

- **"Required role" Picker in shift template editor cannot be opened**
  - Date fixed: —
  - Where / what / repro: `ShiftTemplateEditSheet` → "Role & Staffing" → "Required role" row tap does nothing — Picker never opens. Repro: create at least one role, create or edit a shift template, try to switch the role away from "Any Role".
  - Patched: no
  - Fix: n/a (open — see `IOS_BUGS.md` #3 for investigation notes)

- **Rota empty-state "Add employee" button does nothing when Employees is in overflow Menu**
  - Date fixed: —
  - Where / what / repro: Rota tab CUV's "Add employee" button. Repro: remove Employees from the configurable tab bar so it lives only in overflow Menu; with no employees, open Rota tab and tap "Add employee" — no tab switch, no sheet.
  - Patched: no
  - Fix: n/a (open — see `IOS_BUGS.md` #2 for proposed fix sketch)

- **Shifts tab list-placeholder flicker on empty state**
  - Date fixed: 2026-04-30 (commit `5cb5e37`)
  - Where / what / repro: `ShiftTemplateListView` briefly flashed grey "No roles yet" / "No shifts yet" rows for one frame before settling on the `ContentUnavailableView`. Repro: launch with no roles/templates, switch to another tab and back to Shifts.
  - Patched: yes — pending user verification
  - Fix: added `hasLoaded` flag to `ShiftTemplateViewModel` and `RoleViewModel`; `isFullyEmpty` now waits for both to finish loading before choosing CUV vs list; renders `Color.clear` while pending instead of the empty list.
