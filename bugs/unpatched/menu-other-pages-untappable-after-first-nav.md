# Menu tab "Other Pages" rows un-tappable after first navigation

**Status:** unpatched. One fix attempt made and failed (see below). Bug still reproduces.

**First reported:** 2026-04-30 (this session)
**Platform:** iOS sim, iPhone 17 Pro Max, iOS 26.2 deployment target. Not yet verified on iPad / macOS / physical device.

## Repro

1. Launch app from a fresh state on iOS sim
2. Switch to the Menu tab (the overflow Settings/Menu tab)
3. Under the **"Other Pages"** section, tap one entry — e.g. **Exceptions**. It opens correctly.
4. Tap the back chevron to return to Menu
5. Tap a different "Other Pages" entry — e.g. **Edit Log**

## Expected

- The tapped row pushes its destination (e.g. `EditLogView`) onto the navigation stack
- Subsequent taps on any row continue to work normally

## Actual

- Row briefly highlights dark grey, then nothing happens
- Once any one row has been tapped + popped, every other row in the same section is dead
- Tab-switching away and back does not recover the row's interactivity

## Files involved

- `platforms/apple/Apps/AutorotaApp/Views/SettingsView.swift` — Menu tab body, hosts the "Other Pages" section
- `platforms/apple/Apps/AutorotaApp/Views/TabPage.swift:62-73` — `destinationView` switch — returns top-level views (`EditLogView()`, `OverridesTabView()`, …) which each wrap their body in their own `NavigationStack`
- `platforms/apple/Apps/AutorotaApp/Views/Shared/MenuNavigationBridge.swift` — bridge added during the bug #2 fix sketch (`IOS_BUGS.md` #2)
- `platforms/apple/Apps/AutorotaApp/Views/ContentView.swift:62-66` — last remaining writer to `MenuNavigationBridge.pendingDestination`

## Hypothesis

Nested `NavigationStack`. `SettingsView` wraps its Form in a `NavigationStack` and registers `.navigationDestination(for: TabPage.self) { page in page.destinationView }`. Every value referenced by `destinationView` (`EditLogView`, `OverridesTabView`, `AnalyticsView`, `ExportTabView`, `EmployeeListView`, `RotaView`) starts its own body with `NavigationStack { … }` (verified by grep). So pushing one of these onto the outer stack creates two nested stacks. iOS 26 appears to leave the outer stack in a state where new pushes are silently swallowed once the inner stack has been popped.

## Failed patch attempt — 2026-04-30

**Hypothesis at the time:** the regression was triggered by the explicit `NavigationPath` binding added to `SettingsView` during the bug #2 fix sketch (`SettingsView.swift` had `@State navPath` + `path: $navPath` + `.onAppear` / `.onChange` consumers calling `consumePendingMenuDestination()`).

**What was changed in `SettingsView.swift`:**
- Removed `@State private var navPath = NavigationPath()`
- Changed `NavigationStack(path: $navPath) { … }` back to `NavigationStack { … }`
- Removed `.onAppear { consumePendingMenuDestination() }` and `.onChange(of: menuNav.pendingDestination) { _, _ in … }`
- Removed the `consumePendingMenuDestination()` private method
- Removed the now-unused `@Environment(MenuNavigationBridge.self) private var menuNav`
- Kept `NavigationLink(value: page)` rows and `.navigationDestination(for: TabPage.self) { … }`

**Result:** bug still reproduces. The `NavigationPath` binding was not the cause (or not the only cause).

**Build status:** compiles + runs. No new diagnostics besides the usual SourceKit `No such module 'AutorotaKit'` index lag.

**Side effect of the failed attempt:** `MenuNavigationBridge.pendingDestination` no longer has a consumer, so bug #2's intended fix mechanism is gone. `ContentView.swift:62-66` still writes to it but nothing reads it. Bug #2 (`IOS_BUGS.md` #2) was already marked open prior to this work — no behavioural regression for that bug, just dead plumbing now.

## Things to try next

- [ ] **Confirm it's the nested stack:** temporarily change `TabPage.destinationView` for one entry (e.g. `.history`) to return `EditLogView`'s inner content with no NavigationStack. If "Other Pages → Edit Log" then keeps working across pop+re-push, the nested stack is the cause.
- [ ] **Cleanest structural fix:** introduce a sibling computed property on each top-level view exposing its inner content (without the `NavigationStack` wrapper), and have `TabPage` provide a separate `menuContent` switch that uses those naked properties for `.navigationDestination`. Keeps `destinationView` for direct tab-bar hosting where the wrapper is wanted. Touches ~6 view files but each change is mechanical.
- [ ] **Lighter alternative:** replace `NavigationLink(value:)` rows in "Other Pages" with `NavigationLink { page.destinationView } label: { … }` (destination-by-closure form). Behaviour should be identical with respect to nested stacks but worth verifying — sometimes the iOS push-coordination differs across the two forms.
- [ ] **Total revert option:** remove `NavigationStack` from each top-level view and rely solely on the host (Tab content / SettingsView) to provide it. This is the SwiftUI-idiomatic structure but is a bigger refactor — probably reserved for a follow-up.
- [ ] **Verify on physical device + iPad + macOS** before committing to a fix — sim-only quirks have happened.
- [ ] **Add a UI test:** tap each "Other Pages" entry in turn from the same Menu instance, asserting each push succeeds.

## Cross-references

- `IOS_BUGS.md` #4 — same bug, currently marked patched-pending-verification (will need to flip back to open)
- `BUG_LOG.md` — top entry, currently marked patched-pending-verification (will need to flip back)
- `IOS_BUGS.md` #2 — related, dead plumbing now lives in `ContentView.swift:62-66` + `MenuNavigationBridge.swift`
