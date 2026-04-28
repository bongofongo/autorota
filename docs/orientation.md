# Orientation & in-app tooltips

How autorota introduces new users to the app, and the schema that lets future
ports (Android, Tauri) mirror the same coverage with native tooltip libraries.

## Two surfaces

1. **Onboarding carousel** — a short, ad-style walkthrough shown once on first
   launch. Four animated SwiftUI mockup slides + the existing `TierPickView`.
   Performs **zero database writes**. Source: `Views/OnboardingView.swift`,
   `Views/Onboarding/CarouselSlideView.swift`, `Views/Onboarding/SlideMockups.swift`.
2. **TipKit tooltips** — first-visit hints attached to controls inside the
   live app. Each tip fires once and persists its dismissed state through
   `Tips.configure(...)` in `AutorotaAppApp.init()`. Source: `AutorotaApp/AutorotaTips.swift`.

The user can replay both at any time:

- **Carousel:** Settings → "View onboarding again". Resets `hasCompletedOnboarding`.
- **Tooltips:** the same Settings action also calls `Tips.resetDatastore()`.

Sample data is **never** written to the user's database. The only place sample
data is shown after onboarding is the PDF export preview sheet, which renders
the canonical fixture from `crates/autorota-core/src/sample.rs` entirely
in-memory (year 2099, so it can never be confused with a real week).

## Carousel slides

| Order | Mockup view (Swift)        | Title key                              | Body key                              |
| ----- | -------------------------- | -------------------------------------- | ------------------------------------- |
| 1     | `ScheduleMockup`           | `onboarding.page.schedule.title`       | `onboarding.page.schedule.body`       |
| 2     | `AvailabilityMockup`       | `onboarding.page.availability.title`   | `onboarding.page.availability.body`   |
| 3     | `AutoGenerateMockup`       | `onboarding.page.generate.title`       | `onboarding.page.generate.body`       |
| 4     | `ExportMockup`             | `onboarding.page.export.title`         | `onboarding.page.export.body`         |
| 5     | `TierPickView` (existing)  | n/a (dedicated screen)                 | n/a                                   |

Other ports should reproduce the same four feature slides (animated where
practical) and end on their platform's purchase / plan picker.

## Tooltip schema

Each tip has a stable ID, the control it anchors, and a localized title /
body string pair. Apple's TipKit uses `displayFrequency: .immediate` plus
the implicit per-Tip eligibility rule (shown once, dismissed forever unless
the datastore is reset).

| Tip ID                       | Anchored control                            | Title key                       | Message key                       |
| ---------------------------- | ------------------------------------------- | ------------------------------- | --------------------------------- |
| `EmployeeRolesTip`           | Roles section in `EmployeeDetailView`       | `tip.employee.roles.title`      | `tip.employee.roles.message`      |
| `AvailabilityModeTip`        | Mode toggle in `EmployeeDetailView`         | `tip.availability.mode.title`   | `tip.availability.mode.message`   |
| `AvailabilityCycleTip`       | Cell tap in `AvailabilityGridView`          | `tip.availability.cycle.title`  | `tip.availability.cycle.message`  |
| `AvailabilityDragTip`        | Cell drag in `AvailabilityGridView`         | `tip.availability.drag.title`   | `tip.availability.drag.message`   |
| `RotaTwoPassTip`             | Empty-state in `RotaView`                   | `tip.rota.twopass.title`        | `tip.rota.twopass.message`        |
| `RotaShareTip`               | Overflow menu in `RotaView`                 | `tip.rota.share.title`          | `tip.rota.share.message`          |
| `EmployeesAddTip`            | Toolbar menu in `EmployeeListView`          | `tip.employees.add.title`       | `tip.employees.add.message`       |
| `ShiftTemplateAddTip`        | Toolbar menu in `ShiftTemplateListView`     | `tip.shifts.template.title`     | `tip.shifts.template.message`     |
| `ExportProfileTip`           | Profile picker in `SettingsView`            | `tip.export.profile.title`      | `tip.export.profile.message`      |
| `EditLogRestoreTip`          | Restore button in `EditLogView`             | `tip.editlog.restore.title`     | `tip.editlog.restore.message`     |

## Cross-platform port notes

When porting to Android (Compose) or Tauri (web):

1. Reuse the same anchor concept — surface each tip on the *same* control as
   the Apple version. Stable IDs above are the contract.
2. Localized strings live in `Localizable.xcstrings` today; future ports
   should mirror the keys (`tip.<area>.<name>.{title,message}`) into their
   own resource files.
3. Honor "show once + remember dismissal" semantics. On Android, use
   DataStore-backed flags. In Tauri, use `localStorage` keyed by tip ID.
4. The carousel's animated mockups are SwiftUI primitives — re-implement them
   with whatever the host platform uses (Compose `AnimatedContent`, web CSS
   animations). Keep the four-slide order consistent so marketing copy stays
   in sync.

## Maintenance

- Adding a new tip: add a `struct ___Tip: Tip` to `AutorotaTips.swift`,
  register the title/message keys in `Localizable.xcstrings`, attach with
  `.popoverTip(_:)` on the target control, and append a row to the table
  above.
- Changing the carousel: edit `OnboardingView.swift`'s `pages` array and
  the matching `Mockup` cases in `slide(for:)`. Update the table above.
- Replaying the tour for QA: Settings → "View onboarding again" resets
  both surfaces in one tap.
