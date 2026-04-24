# Radial Fan Menu — iOS Navigation Enhancement

> **Status: SUPERSEDED (archived).** This radial-fan approach shipped
> briefly and was later replaced by a configurable tab bar with a pinned
> **Menu** tab hosting hidden pages. See `docs/quick-bar-report.md` and
> `platforms/apple/Apps/AutorotaApp/Views/TabPage.swift` for the current
> design. The files named below (`RadialFanMenuView.swift`,
> `FloatingMoreButton.swift`, `CustomTabBar.swift`,
> `NavigationLayoutManager`) no longer exist in the codebase.

## Context

The app currently uses a standard 5-tab `TabView` on iOS (Rota, Employees, Templates, Overrides, Settings). As the app grows, the tab bar becomes crowded. This feature adds a configurable "More" button — a visually distinct floating button with its own border, overlaid above the bottom-right corner of the tab bar — that presents additional pages in a radial fan pattern. The button is deliberately separate from the tab bar to make it visually distinguishable. Users can customise which pages appear in the tab bar vs the fan via Settings. macOS is unaffected — it continues using sidebar navigation.

## Design

### Navigation Model

A `TabPage` enum defines all navigable pages:

| Page | Icon | Default Placement |
|------|------|-------------------|
| Rota | `calendar` | Tab Bar |
| Employees | `person.2` | Tab Bar |
| Templates | `clock` | Fan |
| Overrides | `exclamationmark.circle` | Fan |
| Settings | `gear` | Fan |

**Constraints:**
- Tab bar: max 3 pages
- Fan: max 5 pages
- All pages are always reachable through Settings regardless of placement
- The "More" button is not a page — it's a fixed floating control, separate from the tab bar

### Custom Tab Bar (iOS only)

Replace SwiftUI's built-in `TabView` on iOS with a custom implementation:

- A `ZStack` at the root holds the currently selected page view, the custom tab bar, and the floating More button
- The tab bar is an `HStack` at the bottom with items for each tab-bar-assigned page only (no More button in the bar)
- Selected tab is tracked via `@State` on a shared `TabPage?` property
- macOS continues using the existing `TabView` with `.tabViewStyle(.sidebarAdaptable)` — no changes

### Floating "More" Button

The "More" button is a separate floating element, **not part of the tab bar**:

- Circular button (~48pt diameter) positioned in the bottom-right corner, overlapping the trailing edge of the tab bar
- Has its own visible border/stroke (e.g., 2pt border in a contrasting color) to visually distinguish it from the tab bar items
- Slightly elevated with a shadow to reinforce separation
- Accent-colored background (e.g., red/coral) with ☰ icon; toggles to ✕ when fan is open
- Anchored with padding from the trailing and bottom safe area edges so it sits just above/beside the tab bar

### Fan Menu Interaction

**Opening:**
- Tap the "More" button (circular, accent-colored, ☰ icon)
- Fan options spring outward in an arc from the button's position toward upper-left
- Background dims with a semi-transparent overlay
- Other tab bar items fade to ~25% opacity
- "More" button icon animates from ☰ to ✕

**Fan layout:**
- Items are positioned along an arc originating from the "More" button
- Arc spans roughly 90° (from ~180° to ~270° relative to button center, i.e., upward and to the left)
- Items are evenly spaced along this arc at a fixed radius (~80-100pt)
- Each item: circular background (teal/accent) + SF Symbol icon + label below

**Animation:**
- Spring pop-out with staggered delay (each item delayed ~0.05s after the previous)
- `spring(response: 0.4, dampingFraction: 0.7)` for the bouncy feel
- Items scale from 0 → 1 and translate from the button origin to their arc position
- Dismiss animation reverses the sequence

**Closing:**
- Tap outside the fan (on the dimmed overlay) — dismisses
- Tap the "More" button again — dismisses
- Tap a fan option — navigates to that page AND dismisses

**Selection:**
- Tapping a fan option sets the selected page and closes the fan
- The destination view renders in the main content area (same as switching tabs)

### Settings — Tab Layout Configuration

Add a new "Navigation Layout" section to `SettingsView` with two grouped lists:

**"Tab Bar" section** (header shows count, e.g., "Tab Bar (2 of 3)"):
- Lists pages currently assigned to the tab bar
- Each row: icon + page name + "→ More" move button on the trailing edge
- Move button is disabled if the fan is at max capacity (5)

**"More Menu" section** (header shows count, e.g., "More Menu (3 of 5)"):
- Lists pages currently assigned to the fan
- Each row: icon + page name + "← Tab Bar" move button on the trailing edge
- Move button is disabled if the tab bar is at max capacity (3)

**Persistence:**
- Layout stored as a JSON-encoded array via `@AppStorage("tabLayout")`
- Stores an ordered list of `TabPage` raw values for tab bar items; everything else goes to fan
- Default value: `["rota", "employees"]` (remaining pages default to fan)

### State Management

A new `@Observable` class `NavigationLayoutManager`:
- `tabBarPages: [TabPage]` — ordered list of pages in the tab bar
- `fanPages: [TabPage]` — ordered list of pages in the fan
- `selectedPage: TabPage` — currently active page
- `isFanOpen: Bool` — fan visibility state
- `moveToFan(_:)` / `moveToTabBar(_:)` — mutation methods with constraint validation
- Reads/writes `@AppStorage("tabLayout")` for persistence

Injected into the environment at the app root so both `ContentView` and `SettingsView` can access it.

### Platform Scoping

All radial menu code is wrapped in `#if os(iOS)` / `#endif`. On macOS, `ContentView` continues to render the standard `TabView` with sidebar style, receiving all 5 tabs as before.

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `Views/ContentView.swift` | Modify | Platform branch: custom tab bar on iOS, existing TabView on macOS |
| `Views/RadialFanMenuView.swift` | Create | Fan overlay: dimmed background, arc-positioned option buttons, animations |
| `Views/CustomTabBar.swift` | Create | Custom HStack tab bar with dynamic items (no More button) |
| `Views/FloatingMoreButton.swift` | Create | Floating bordered button overlaid above tab bar corner |
| `Views/SettingsView.swift` | Modify | Add "Navigation Layout" section with two-list configuration |
| `Models/TabPage.swift` | Create | `TabPage` enum and `NavigationLayoutManager` observable |

All files under `platforms/apple/Apps/AutorotaApp/AutorotaApp/` or the relevant `Views/` subdirectory.

## Verification

1. **Build check**: `make swift-build-check-ios` compiles without errors
2. **macOS unaffected**: `make swift-build-check-macos` compiles; macOS still shows sidebar TabView
3. **Simulator test**: Run on iPhone simulator — verify:
   - Default layout shows Rota + Employees tabs + More button
   - Tapping More opens fan with Templates, Overrides, Settings
   - Fan items spring outward with staggered animation
   - Tapping a fan item navigates to that page
   - Tapping outside or More button dismisses the fan
   - Background dims and tab items fade when fan is open
4. **Settings config**: Open Settings → Navigation Layout:
   - Move a page from fan to tab bar and back
   - Verify max constraints are enforced (buttons disable at limits)
   - Kill and relaunch app — verify layout persists
5. **Edge cases**: Move all pages to fan (only More button in tab bar) — app remains usable
