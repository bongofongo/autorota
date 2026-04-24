# Tab Bar + Menu Overflow — Development Report

> **Historical note.** This document originally described a radial fan
> "Quick Bar" iteration (`FloatingMoreButton` + `RadialFanMenuView` +
> `NavigationLayoutManager`). That approach was superseded. The current
> model is a configurable tab bar with a pinned **Menu** tab that hosts
> hidden pages. The historical radial-fan design is archived under
> `docs/superpowers/specs/2026-03-28-radial-menu-design.md` — the files
> it references (`RadialFanMenuView.swift`, `FloatingMoreButton.swift`,
> `CustomTabBar.swift`) no longer exist.

## Current Design

All navigable pages live in `TabPage` (`platforms/apple/Apps/AutorotaApp/Views/TabPage.swift`):

| Page | Title | Icon |
|------|-------|------|
| `rota` | Rota | `calendar` |
| `employees` | Employees | `person.2` |
| `templates` | Shifts | `clock` |
| `overrides` | Exceptions | `exclamationmark.circle` |
| `history` | Edit Log | `clock.arrow.circlepath` |
| `analytics` | Analytics | `chart.bar` |
| `export` | Export | `square.and.arrow.up` |
| `settings` | Menu | `line.3.horizontal` |

`settings` is always pinned to the trailing end of the tab bar and hosts
all pages that did not fit. `TabPage.configurablePages` is the user-sortable
set; `TabPage.defaultTabBar` is `[.rota, .employees, .templates]` on iOS
(max 3 configurable slots) and `[.rota, .employees, .templates, .overrides]`
on macOS (max 4).

## State Management

`TabLayoutManager` (`@Observable`) in the same file owns
`configurableTabBarPages` and persists the full ordered list under the
`tabBarLayout` key in `UserDefaults` as a JSON array of `TabPage` raw
values. `hiddenPages` is derived — everything in
`TabPage.configurablePages` that is not currently in the tab bar. The
Menu tab (`SettingsView`) renders the hidden pages as navigation rows.

## Rota-Specific Overflow

A separate "dots" overflow menu lives on the Rota page only — unrelated
to the tab bar Menu tab. It is described in
`docs/specs/rota-overflow-menu.md`.

## Recommendations for Future Work

- Drag-to-reorder within the Menu tab's layout settings.
- iPad-specific default layout (more room than phone, less than desktop
  sidebar).
- Consider surfacing Edit Log / Analytics as pinned defaults on larger
  devices once they stabilise.
