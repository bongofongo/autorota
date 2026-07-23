# AutoRota TODO

## Formatting rules
- Sections: `## N. Title` — numeric for ordered work, `?.` for parking-lot/unscheduled
- Renumber by hand when reordering; keep one blank line between sections
- Items: `- [ ]` open, `- [x]` done, `- [~]` in progress, `- [!]` blocked
- Sub-bullets under each item carry technical implementation notes (scope, file paths, APIs, gotchas)
- Keep notes terse but specific enough to start work without re-thinking the design
- New items: append to the relevant section; new sections: insert in priority order and bump numbers

## 1. Refine iOS UI
- [ ] Appearance preview tiles (System / Light / Dark) in Settings
  - Mirror Apple's native picker (Settings → Display & Brightness): three rounded card previews side-by-side, each ~110×140pt, with a stylized mock of the app inside, a radio/checkmark below, and the label
  - New view `AppearancePreviewPicker` in `platforms/apple/Apps/AutorotaApp/Shared/Settings/` — `HStack(spacing: 16)` of `AppearancePreviewTile(scheme: AppearanceMode)` where `AppearanceMode = .system | .light | .dark`
  - Tile chrome: `RoundedRectangle(cornerRadius: 14)` with `.strokeBorder(selected ? .tint : .secondary.opacity(0.3), lineWidth: selected ? 2 : 1)`. Inside: scaled `ZStack` mock of nav bar + 2 list rows + tab bar, painted with explicit `.background` / `.foregroundStyle` per scheme so the preview ignores the device's current scheme (do NOT rely on `.preferredColorScheme` inside the tile — it only affects sheets/popovers)
  - System tile: split diagonally (light top-left, dark bottom-right) using `Canvas` or two clipped halves
  - Bind to `@AppStorage("appearanceMode") var appearanceMode: AppearanceMode = .system`; apply at `AutorotaApp.body` root via `.preferredColorScheme(appearanceMode.colorScheme)` (returns `nil` for `.system`)
  - Wrap iOS-only with `#if os(iOS)`; macOS gets a segmented `Picker` fallback in `Platform/macOS/SettingsView_macOS.swift`
  - Add accessibility: `.accessibilityElement(children: .combine)`, label = "Appearance: \(scheme.title), \(selected ? "selected" : "")", trait `.isButton`
  - Snapshot tests in `AutorotaAppTests/AppearancePreviewTileTests.swift` — one per scheme, light + dark device contexts
- [ ] Audit list rows for Dynamic Type at AX5
  - Run `xcrun simctl ui booted content_size accessibility-extra-extra-extra-large` on iPhone 17 Pro Max sim
  - Fix any truncation in `EmployeeRow`, `ShiftRow`, `AssignmentRow` — switch fixed `HStack` to `ViewThatFits` or `Layout` protocol stacks
- [ ] Replace ad-hoc colors with semantic `Color` assets
  - Audit Swift files for `Color(red:…)`, `Color.gray`, hex literals — move to `Assets.xcassets` with light/dark variants
  - Define semantic names: `RotaCellBackground`, `AvailabilityYes`, `AvailabilityMaybe`, `AvailabilityNo`, `WageText`
- [ ] Haptics on confirm/destructive actions
  - `UIImpactFeedbackGenerator(style: .medium)` on Save, `.notificationOccurred(.warning)` on delete confirm
  - Wrap in `HapticsService` (no-op on macOS) so ViewModels stay platform-agnostic
- [ ] Polish empty states (Employees, Shifts, Rota, Edit Log)
  - Use `ContentUnavailableView` (iOS 17+) with SF Symbol, title, description, primary action button
  - Ensure each empty state has a clear next-step CTA wired to the correct flow
- [x] App icon previews in Settings should follow in-app dark mode (added 2026-07-23, done 2026-07-23 — asset-only: dark appearance variants added to the three `AppIconPreview*` imagesets; no code change)
  - `AppIconPicker` (`Views/AppSettingsView.swift:180-229`) renders static preview assets via `AppIconOption.previewImageName` (`AppIconPreviewDefault/Jazz/Latte`, lines 158-164) — no dark variants today
  - Add dark preview variants (asset appearance variants in `Assets.xcassets`, or `…Dark`-suffixed assets picked in code) and resolve against the *in-app* effective scheme: `@AppStorage("appAppearance")`, falling back to `@Environment(\.colorScheme)` when `.system`
  - Scope: preview tiles ONLY. Do NOT touch `UIApplication.shared.setAlternateIconName` (line 223) — the home-screen icon must keep following Apple's system dark mode via the asset catalog, never the in-app appearance toggle
  - Gotcha: latte icon's dark art intentionally reuses the sunrise dark art — not a cross-wire

## 2. Edit Log — freshness + generation saves (added 2026-07-23)
- [ ] Edit Log doesn't update as rota changes (reproduced with default sample load)
  - Cause (a): `EditLogView` only loads on `.task` / pull-to-refresh (`Views/EditLogView.swift:64,97`) — it has no `.onReceive(.autorotaDataChanged)` unlike `RotaView.swift:222` / `EmployeeListView.swift:137`. Fix: subscribe and `await vm.loadSaves()`
  - Cause (b): saves are only written by `autoSave()` (`ViewModels/RotaViewModel.swift:523-531`) on edit-mode exit (502-509) or week navigation (`RotaView.swift:112-113`); individual mutations just set `isDirty`. So nothing appears in the log until the session ends. Decide: keep per-session granularity (then (a) alone fixes perceived lag) vs debounced per-mutation auto-save (~2-3s after last change) — debounce preserves grouping without save spam
- [ ] Abbreviate generation/regeneration saves + auto-tag; full detail on tap only
  - `FfiSave` has no origin field (`id, rotaId, savedAt, summary, tags, weekStart, restoredAt` — generated `autorota_ffi.swift:3168-3207`); generation saves are indistinguishable from manual edits. Add a `source` discriminator to Save in core + FFI (`Generation | Regeneration | Manual | Restore`) — new migration
  - Thread origin through: `performSchedule()` (`RotaViewModel.swift:430-441`) / `confirmRegenerate()` (426-428) → currently both just set `isDirty` and share `autoSave()` with manual edits → extend `createSave(rotaId:)` (`Services/LiveAutorotaService.swift:249`) to carry source
  - Auto-label: "Generation" when week had no prior assignments, "Regeneration" otherwise. Render as system tag/badge in `SaveEntryView`; must not count against user tag limits (3 tags / 15 chars, `EditLogViewModel.swift:74-76,103-145`) and must not be user-removable — prefer the `source` field over a reserved tag string
  - Abbreviated rendering: for generation saves, `SaveEntryView` shows summary counts only (`ChangeSummaryCard` style, `EditLogView.swift:379-424`) — suppress per-assignment `ChangeRow`s (449-516)
  - Tap abbreviated entry → push new detail page (`NavigationLink`) listing every change via existing `DayChangesGroup`/`ChangeRow`; page reachable ONLY from abbreviated entries, no other nav path

## 3. Rota — manual shift creation
- [ ] Inline employee assignment in the Add Shift sheet (with role-aware filtering)
  - Edit `AddShiftSheet` in `platforms/apple/Apps/AutorotaApp/Views/RotaView.swift:939` — currently asks for time + role only and calls `vm.createAdHocShift(date:startTime:endTime:requiredRole:)`
  - Add new `Section("Assign")` with an Employee picker; default selection = sentinel `nil` (or `Optional<Int64>.none`) labelled "Empty" → leaves shift unassigned (existing behaviour)
  - Load employees via `RotaViewModel.employees` (already populated for `EmployeePickerSheet`); if not yet loaded for ad-hoc paths, fetch lazily on sheet `.task`
  - **Role → employee filter:** when `selectedRole != ""`, the employee picker shows only employees whose `roles` array contains `selectedRole`. "Empty" stays selectable. If the currently-selected employee no longer satisfies the role, snap selection back to `nil` and surface a subtle inline note ("Previous employee removed — role changed")
  - **Employee → role filter:** when `selectedEmployee != nil`, all roles remain visible in the role picker but roles the employee does NOT hold are rendered disabled — `.foregroundStyle(.tertiary)`, `.disabled(true)`. Do NOT hide them. "Any Role" stays enabled regardless. If the user picks an employee whose roles don't include the currently-selected role, snap role back to `""` (Any Role)
  - SwiftUI `Picker` does not support per-row `.disabled` cleanly — replace the `Picker("Role", …)` with a `Menu` whose label shows current selection and whose content is a `ForEach` of `Button`s, each with `.disabled(!employeeHasRole)` and a tertiary foreground when disabled. Same pattern for the employee picker so "Empty" can sit at the top with a divider
  - On Create: call `vm.createAdHocShift(...)` first; if it returns the new shift id and `selectedEmployee != nil`, follow with `vm.addEmployeeToShift(shiftId: newId, employeeId: selectedEmployee!)`. If `createAdHocShift` does not currently return the new id, extend its FFI return type or expose a `lastCreatedShiftId` on the VM — do not refetch and guess by timestamp
  - Wrap both calls in a single VM method `createAdHocShiftWithAssignment(date:startTime:endTime:requiredRole:employeeId:)` so the sheet stays thin and the two-step is atomic from the UI's perspective. Assignment failure after shift creation should NOT roll back the shift — surface a non-blocking warning ("Shift created, but assignment failed: …") and leave the shift in place
  - Accessibility: announce filter changes via `.accessibilityValue` on the pickers; ensure VoiceOver reads disabled roles as "Barista, dimmed, unavailable for selected employee"
  - Tests: extend `RotaViewModelTests` with cases for (a) shift+assign happy path, (b) role filter excluding employees, (c) employee filter disabling roles, (d) assignment failure after successful shift creation

## 4. Onboarding refinement
- [ ] Skip-to-end affordance for returning users
  - Detect prior install via Keychain flag `onboarding.completed` (survives app reinstall on same Apple ID)
- [ ] Animate role/availability sample data seed
  - Show progress with `ProgressView(value:)` driven by FFI seeding callback; fall back to indeterminate if FFI lacks progress
- [ ] iCloud sync prompt copy review
  - Current copy in `OnboardingICloudView.swift`; align with Apple HIG ("Use iCloud" not "Enable iCloud sync")

## ?. Branding + App Store assets
- [ ] Design logo (icon + wordmark)
  - 1024×1024 vector master (Figma/Sketch); export via Xcode 26's single-size `AppIcon` slot
  - Provide light, dark, and tinted variants in `Assets.xcassets/AppIcon.appiconset` (iOS 18+ supports all three; tinted requires grayscale source)
  - Wordmark as separate `Wordmark.imageset` — SVG source, PNG @1x/@2x/@3x fallbacks; light/dark variants
- [ ] App Store screenshots (iPhone, iPad, Mac)
  - Required: iPhone 6.9" (1320×2868), iPad 13" (2064×2752), Mac (2880×1800) — App Store Connect rejects other sizes
  - Drive sims to canonical states (Rota week, Edit Log diff, Analytics chart, Export sheet) via UI automation script in `scripts/screenshot.sh`
  - Capture via XcodeBuildMCP `screenshot` for iOS/iPadOS, `screencapture -R` for macOS window
  - Optional: frame with device chrome via fastlane `frameit` — App Store no longer requires it
- [ ] Marketing copy + feature highlights
  - Subtitle ≤30 chars, promo text ≤170, description ≤4000, keywords ≤100 comma-separated
  - Draft in `docs/store-listing.md`; ASO keyword pass before submission (use App Store Connect search popularity)
- [ ] App Store preview video (optional)
  - 15–30s, H.264 or HEVC, ≤500 MB; portrait for iPhone, landscape for Mac
  - Capture via XcodeBuildMCP `record_sim_video`; edit in Final Cut / DaVinci; add captions for accessibility
- [ ] Localized store listings matching #1
  - Locale set must match in-app `Localizable.strings` coverage
  - Per locale: subtitle, description, keywords, screenshots
  - Automate via fastlane `deliver` or App Store Connect API (avoid hand-editing in web UI)
