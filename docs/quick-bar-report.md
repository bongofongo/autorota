# Quick Bar Component — Development Report

## Overview

The Quick Bar is a radial fan menu for the iOS build of Autorota, designed to give users fast access to pages that aren't pinned to the bottom tab bar. A floating circular button in the bottom-right corner of the screen opens a fan of page shortcuts that arc upward and to the left. Users can configure which pages appear in the tab bar versus the Quick Bar through a collapsible "Layout" section in Settings.

## Design

The component consists of four pieces:

- **TabPage model** (`TabPage.swift`): An enum of all navigable pages (Rota, Employees, Templates, Overrides, Settings) with a `NavigationLayoutManager` observable class that tracks which pages are in the tab bar vs. the Quick Bar, persisted to `UserDefaults` as JSON. The manager enforces constraints: max 3 pages in the tab bar, max 5 in the Quick Bar.

- **FloatingMoreButton** (`FloatingMoreButton.swift`): A 48pt circular button with a red fill, white border stroke, and drop shadow to visually separate it from the native tab bar. The icon toggles between a hamburger menu and an X with a rotation animation.

- **RadialFanMenuView** (`RadialFanMenuView.swift`): When the fan opens, items fade in at positions calculated along a 90-degree arc (from straight up to straight left relative to the button). A `GeometryReader` determines the button's screen position, and standard trigonometry places each item at the correct angle and radius. Tapping a fan item presents that page as a full-screen cover with a "Done" button to dismiss. Tapping outside the fan dismisses it.

- **ContentView integration**: On iOS, the native `TabView` displays only the tab-bar-assigned pages. The fan overlay and floating button are layered on top via a `ZStack`. A semi-transparent rectangle overlays the tab bar when the fan is open to dim it. On macOS, nothing changes — the existing sidebar `TabView` renders all five pages as before.

- **Settings UI**: A `DisclosureGroup("Layout")` section in `SettingsView` shows two lists — "Tab Bar" and "Quick Bar" — with move buttons on each row. Constraints are enforced by disabling buttons when either section is at capacity.

## Current State and Known Issues

The fan's position math was iterated on several times. SwiftUI's coordinate system (y-axis increases downward) required negating the sine component to get upward movement. The final version uses `GeometryReader` with absolute positioning rather than offset-from-corner, which proved more reliable across device sizes.

Fan pages open as `.fullScreenCover` presentations rather than switching within the `TabView`, since pages not in the tab bar can't be selected via `TabView(selection:)`. This works but means fan-accessed pages don't show the tab bar — the user must tap "Done" to return.

The tab bar dimming uses a plain rectangle overlay rather than modifying the native `UITabBar` appearance, which is a pragmatic workaround for SwiftUI's limited tab bar customization API.

## Recommendations for Future Work

If this component is revisited, consider: (1) allowing drag-to-reorder within the Layout settings, (2) haptic feedback on fan open/close, (3) adapting the fan radius and arc for iPad screen sizes, and (4) exploring whether a custom tab bar (replacing the native `TabView` entirely) would give better control over dimming and slide animations without the compromises encountered during this iteration.
