# Shelved feature: hold-then-drag lasso on the availability grid

**Status: removed from the app on 2026-07-10.** Multi-select on
`AvailabilityGridView` is now *only* available via the toolbar's sticky
lasso toggle. This document preserves the hold-then-drag implementation in
enough detail to reinstate it verbatim.

## Why it was shelved

The gesture interfered with regular page scrolling. The grid lives inside
scrolling containers everywhere it is editable (a `List` on the employee
detail page, `Form`s in the edit/exception sheets, `ScrollView`s in the
weekly-availability grid layout and the carousel). The hold-then-drag
design tried to disambiguate "scroll" from "select" with a 0.2 s hold
window, but in practice users pausing mid-scroll — or simply touching down
deliberately before scrolling — kept arming the lasso and drawing
selections when they meant to scroll. The verdict from user testing:
"too distracting and frustrating to use in its current implementation."
Any revival needs a better disambiguation story first (see *Revival
notes*).

## History

- Introduced in commit `bd7dd2f` ("feat(app): guided demo mode + inline
  grid editing + drag-to-lasso"), which **replaced** the then-existing
  selection-mode toggle button with the hold-drag gesture.
- The toggle button was revived alongside hold-drag in the demo-tutorial
  work (2026-07-10), giving two activation paths.
- Hold-drag removed the same day; the toggle is now the only path.
- The last commit containing the live hold-drag code is the one preceding
  the removal commit — `git log --follow -- platforms/apple/Apps/AutorotaApp/Views/Shared/AvailabilityGridView.swift`
  will show it; the code is also reproduced in full below.

## Where it lived

`platforms/apple/Apps/AutorotaApp/Views/Shared/AvailabilityGridView.swift`.
Everything was view-local — no ViewModel, FFI, or persistence surface.
The removal touched only this file plus one demo-tour string
(`demo.sub.setAvailability.lassoBlock`, which used to say "…or hold a cell
then drag").

## Shared selection machinery (still in the code, used by the toggle)

The hold-drag gesture wrote into the same state as the toggle's plain
drag; none of this was removed:

- `@State dragAnchorCell: (col, row)?` / `dragCurrentCell` — the selection
  rectangle is `selectionRect`, the min/max box of these two.
- `@State lassoDidDrag: Bool` — set on the first `onChanged` of a new
  drag; that first change also plants `dragAnchorCell` from
  `drag.startLocation`. Reset in `onEnded`. This flag is what makes a new
  drag *replace* the old selection while a touch that never moves leaves
  the prior selection intact.
- Selection persists after the finger lifts. `handleTap` then routes taps:
  inside the rect → `toggleSelectedCells` (majority-state bulk cycle, one
  `onChange` callback); outside → clear (`dragAnchorCell = nil`, etc.).
- `cellAt(point:cellWidth:)` clamps to the nearest cell so a drag that
  wanders past the grid edge keeps tracking the boundary cell; the
  coordinate space is `.named("availGrid")` on the grid's `ZStack`.
- Tutorial hooks: `onEnded` posted
  `NotificationCenter .autorotaTutorialAction` with
  `TutorialAction.lassoDrawn` when `lassoDidDrag && hasSelection`;
  `toggleSelectedCells` posts `.lassoApplied`. (The toggle's plain drag
  still posts both.)

## The removed gesture, verbatim

State that existed only for hold-drag (removed):

```swift
/// True from the moment the hold arms the lasso until the finger lifts.
/// Drives the haptic tick that tells the user dragging now selects.
@State private var lassoArmed = false
```

The gesture builder (removed):

```swift
/// Hold-then-drag lasso, always available when the toggle is off.
/// `maximumDistance` makes the hold fail as soon as the finger drifts —
/// a swipe that starts moving immediately never arms the lasso and
/// scrolls the page instead.
private func holdThenDragLasso(cellWidth: CGFloat) -> some Gesture {
    LongPressGesture(minimumDuration: 0.2, maximumDistance: 8)
        .sequenced(before: DragGesture(minimumDistance: 4, coordinateSpace: .named("availGrid")))
        .onChanged { value in
            switch value {
            case .first(true):
                // Hold succeeded — arm the lasso. The existing selection
                // is NOT cleared here: a stationary press that never
                // drags must leave it intact so tap-inside still applies.
                lassoArmed = true
            case .second(true, let drag?):
                // First real movement starts the new lasso, replacing
                // any old selection.
                if !lassoDidDrag {
                    lassoDidDrag = true
                    dragAnchorCell = cellAt(point: drag.startLocation, cellWidth: cellWidth)
                }
                dragCurrentCell = cellAt(point: drag.location, cellWidth: cellWidth)
            default:
                break
            }
        }
        .onEnded { _ in
            // Selection stays — tap inside applies, tap outside clears.
            if lassoDidDrag, hasSelection {
                NotificationCenter.default.post(name: .autorotaTutorialAction, object: TutorialAction.lassoDrawn)
            }
            lassoArmed = false
            lassoDidDrag = false
        }
}
```

Attachment point — on the grid's clear touch layer (`Color.clear`
`.contentShape(Rectangle())` inside the grid `ZStack`), mutually exclusive
with the toggle's plain drag via `isEnabled`:

```swift
.onTapGesture { location in
    handleTap(at: location, cellWidth: cellWidth)
}
.gesture(plainLassoDrag(cellWidth: cellWidth), isEnabled: lassoToggleActive)
.gesture(holdThenDragLasso(cellWidth: cellWidth), isEnabled: !lassoToggleActive)   // ← removed line
.sensoryFeedback(.impact(weight: .light), trigger: lassoArmed) { _, armed in armed }  // ← removed line
```

## Design intent, piece by piece

- **`LongPressGesture(minimumDuration: 0.2, maximumDistance: 8)`** — the
  hold is the scroll/select disambiguator. 0.2 s was chosen as "brief but
  deliberate"; `maximumDistance: 8` makes the hold FAIL as soon as the
  finger drifts, so a swipe that starts moving immediately never arms and
  the enclosing scroll view receives the drag instead. (This is the part
  that proved insufficient: a finger that rests momentarily and then
  scrolls has already armed.)
- **`.sequenced(before: DragGesture(minimumDistance: 4, coordinateSpace: .named("availGrid")))`**
  — only after the hold succeeds does the drag phase begin;
  `minimumDistance: 4` gives a little slack so micro-jitters during the
  hold don't count as dragging.
- **`case .first(true)`** — hold succeeded, set `lassoArmed = true`.
  Deliberately does NOT clear the existing selection: a stationary press
  that never drags must leave the prior selection intact so tap-inside
  still bulk-applies.
- **`case .second(true, drag?)`** — drag phase running. First movement
  sets `lassoDidDrag` and plants the anchor at `drag.startLocation`
  (grid-space); every change updates `dragCurrentCell` via the clamping
  `cellAt`.
- **Haptic** — `.sensoryFeedback(.impact(weight: .light), trigger: lassoArmed) { _, armed in armed }`
  fired exactly on the arming transition (false→true only, hence the
  condition closure), telling the user "dragging now selects".
- **`onEnded`** — clears `lassoArmed`/`lassoDidDrag` but leaves the
  selection on screen (persistence contract shared with the toggle path);
  posts the `lassoDrawn` tutorial action when a real selection was drawn.
- **Scroll interplay** — unlike the toggle (which flips
  `onLassoModeChange` so containers apply `.scrollDisabled`), hold-drag
  never disabled scrolling; it relied entirely on the failed-hold
  mechanism to hand swipes back to the scroll view. That asymmetry is the
  root of the shelving.
- **TipKit tie-in (already gone)** — when this shipped in `bd7dd2f`, an
  `AvailabilityDragTip` taught the gesture and its `onEnded` donated
  `AvailabilityDragTip.cycleDismissed`. TipKit was removed app-wide in the
  demo-tutorial work, so a revival should teach it via the demo tour
  (`demo.sub.setAvailability.lassoBlock`) instead.

## Revival notes

1. Re-add the `lassoArmed` state, the `holdThenDragLasso` builder, the
   `.gesture(..., isEnabled: !lassoToggleActive)` line, and the
   `.sensoryFeedback` line — all verbatim from above.
2. Update `demo.sub.setAvailability.lassoBlock` to mention the gesture
   again ("…toggle the lasso tool and drag, or hold a cell then drag").
3. Update the view's header doc comment and the `docs/overview.md`
   feature-table row.
4. **Solve the scroll conflict first.** Ideas considered but not built:
   longer hold (0.35–0.5 s) with a visible arming affordance (cell pulse)
   so accidental arming is at least legible; arming only after the hold
   *and* an initial drag directly over a cell (not the gutter); requiring
   the grid to be in an explicit edit mode (pencil) before the gesture is
   attached; or a `UIGestureRecognizer`-level solution that requires the
   scroll view's pan to fail first (SwiftUI's `highPriorityGesture` /
   `simultaneousGesture` can't express that relationship cleanly).
