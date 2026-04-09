# Rota overflow menu — current spec

Captures the as-built behaviour of the Rota page's dots/options button and
the popover menu it presents, plus follow-up work.

## Triggers (the dots button)

Two triggers, both flip a single shared `RotaUIBridge.overflowOpen` flag:

### Portrait iPhone — system tab bar dots
- Implemented as a `Tab(role: .search)` inside `ContentView`'s
  `TabView { ... }` with the iOS 18+ `Tab` builder.
- Renders as a separated Liquid Glass capsule at the trailing edge of the
  floating tab bar (the same primitive Apple Health uses for its search
  button).
- Visible **only** on the Rota tab in portrait. When another page is
  active, the dots tab is removed entirely so the main tab bar centers
  naturally. Gated by `verticalSizeClass == .regular` and the current
  `selection`.
- Tapping it: `ContentView.onChange(of: selection)` detects the
  `.dots` value, routes selection back to `.page(.rota)`, and **toggles**
  `bridge.overflowOpen` (so a second tap closes the menu).

### Landscape iPhone — floating glass button
- Standalone `Button` rendered inside `RotaView`'s root
  `ZStack(alignment: .bottomTrailing)`, gated by
  `verticalSizeClass == .compact` (`showsFloatingDotsButton`).
- Glyph: `ellipsis` (SF Symbol), 24pt, `.title3.weight(.semibold)`.
- Background: `.glassEffect(.regular.interactive(), in: Circle())` —
  native iOS 26 Liquid Glass material so it matches the tab bar visuals.
- Positioned via `GeometryReader` + `.position(x: width * 0.8, y: height - 28)`
  so it sits ~80% across the screen at the same y-level as the floating
  Liquid Glass tab bar.
- Tapping it toggles `bridge.overflowOpen` inside a
  `withAnimation(.spring(response: 0.3, dampingFraction: 0.78))` block.

## Popover (`RotaOverflowPopover`)

Single shared component used for both triggers — guarantees identical look
in portrait and landscape.

- File: `platforms/apple/Apps/AutorotaApp/Views/RotaOverflowPopover.swift`
- Inputs: `actions: [RotaOverflowAction]`, `isPresented: Binding<Bool>`.
- Layout: `VStack(alignment: .trailing, spacing: 8)` of self-contained rows.
- Each row is its own Liquid Glass capsule:
  - `HStack(spacing: 12)`: title `Text` (`.font(.body)`), `Spacer(minLength: 10)`,
    `Image(systemName:)`. Right-aligned icon, left-aligned text.
  - Padding: `.horizontal 17`, `.vertical 12`.
  - Background: `.glassEffect(.regular.interactive(), in: Capsule())`.
  - Destructive role rows render text and icon in `Color.red`.
- All rows share the same width:
  - Each row reports its natural width via a `RowMaxWidthKey` PreferenceKey.
  - The popover tracks the maximum and applies it back via
    `.frame(width: rowWidth, alignment: .leading)`.
- Container sizing: `VStack` is wrapped in `.fixedSize()` so the popover
  takes only as much space as the widest row needs (no full-screen fill).

### Anchoring
- Rendered as an overlay layer inside `RotaView`'s
  `ZStack(alignment: .bottomTrailing)` when `bridge.overflowOpen == true`.
- Trailing padding: `20`pt.
- Bottom padding (adaptive in `RotaOverflowPopover.bottomPadding`):
  - **Portrait** (`verticalSizeClass == .regular`): `12`pt — sits just
    above the system tab bar so the menu is directly above the dots.
  - **Landscape** (`verticalSizeClass == .compact`): `84`pt — clears the
    floating glass button, which is positioned ~28pt from the bottom.

### Animation
- Transition: `.scale(scale: 0.85, anchor: .bottomTrailing)` combined with
  `.opacity` — pops out from the bottom-right corner.
- Driven by `.animation(.spring(response: 0.3, dampingFraction: 0.78), value: bridge.overflowOpen)`
  on `RotaView`.

### Dismissal
- **Tap outside**: full-screen transparent backdrop (`Color.black.opacity(0.001)`
  with `.contentShape(Rectangle())`) absorbs taps and calls `dismiss()`.
- **Tap a row**: row action runs after a 50ms `DispatchQueue.main.asyncAfter`
  delay so the dismiss animation can start before any sheet/alert presented
  by the action competes with it.
- **Re-tap the dots button**: both triggers toggle `bridge.overflowOpen`,
  so a second tap on the dots closes the open menu.
- **Tab change away from Rota**: `RotaView.onDisappear` resets
  `bridge.overflowOpen = false`.

## Action set (`overflowActions` in `RotaView.swift`)

Computed per current `RotaViewModel` mode. Each entry is a
`RotaOverflowAction { title, systemImage, role?, action }`.

### Normal mode
- **Stage** — `tray.and.arrow.down` — only when `vm.weekHasPastDays` and a
  schedule exists. Calls `vm.enterStagingMode()`.
- **Edit** — `pencil` — only when a schedule exists. Calls
  `Task { await vm.enterEditMode() }`.
- **Share** — `square.and.arrow.up` — only when a schedule exists. Sets
  `showExportSheet = true`.
- **Generate** — `wand.and.stars` — always. Calls
  `Task { await vm.runSchedule() }`.

### Edit mode
- **Lock past days** / **Unlock past days** — `lock.fill` / `lock.open.fill`
  — only when `vm.weekHasPastDays`. Toggles `vm.pastUnlocked`.
- **Delete schedule** — `trash`, role `.destructive` — only when
  `vm.weekCategory != .future`. Sets `vm.showDeleteScheduleConfirmation = true`.
- **Done editing** — `checkmark`. Calls `vm.exitEditMode()`.

### Staging mode
- **Done staging** — `checkmark`. Calls `vm.exitStagingMode()`.

## Files
- `platforms/apple/Apps/AutorotaApp/Views/ContentView.swift` — TabView, dots
  tab gating, selection routing.
- `platforms/apple/Apps/AutorotaApp/Views/RotaView.swift` — landscape
  floating button, overlay rendering, `overflowActions` builder.
- `platforms/apple/Apps/AutorotaApp/Views/RotaOverflowPopover.swift` — the
  popover component.
- `platforms/apple/Apps/AutorotaApp/Views/RotaUIBridge.swift` — shared
  `@Observable` flag.

## TODO

- [ ] **Mode-aware base button.** The dots glyph stays as `ellipsis` in all
      modes today. Consider switching the base button glyph (and/or its
      tint) when in editing or staging mode so the user can see at a glance
      that the menu's contents have changed (e.g. `checkmark.circle` while
      staging, `pencil.circle` while editing).
- [ ] **Landscape button placement + menu placement.** The current
      `GeometryReader { .position(x: width * 0.8, y: height - 28) }` is a
      best-guess; revisit so the button truly sits adjacent to the system
      tab bar (not just at a hand-tuned ratio) and the popover's
      `bottomPadding` (currently `84` in landscape) follows from the actual
      button position rather than a magic number.
- [ ] **Polish the landscape rota page.** General visual cleanup of the
      landscape week-grid layout — column widths, spacing, header
      treatment, etc. — separate from the menu work.
- [ ] **Color the buttons.** Add a subtle tint per action so each row in
      the popover has its own colour (e.g. Generate = blue, Edit = orange,
      Share = green, Delete = red — already done via destructive role).
      Could be applied as a foreground tint on the icon only, or as a
      capsule fill, depending on how loud we want it.
