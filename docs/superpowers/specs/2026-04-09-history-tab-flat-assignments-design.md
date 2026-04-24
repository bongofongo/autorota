# History Tab — Flat Assignment Rows

**Date:** 2026-04-09
**Status:** Implemented (archived). The History tab was later renamed to
the **Edit Log** and the `CommitHistoryView` / `CommitHistoryViewModel`
files referenced below have been replaced by `EditLogView` /
`EditLogViewModel`. The flat-assignment layout described here survived
the rename.

## Context

The history tab's Shifts mode currently uses three levels of nesting: Week → Day → Shift → Assignment. This creates two usability problems:

1. The shift row repeats the date already shown in the day header
2. Multi-person shifts require expanding a disclosure to see who's assigned — extra taps for the most common query ("who's working when?")

The goal is a flatter, more scannable list that answers "who is working which shift on which day" at a glance.

## Design

### Structure

```
Week of 2026-04-06          (disclosure group)
  └─ Tue 7 Apr  (3 shifts)  (disclosure group)
       ├─ Alice                            ●
       │  09:00–14:00  Barista
       ├─ Bob                              ●
       │  09:00–14:00  Barista
       └─ Carol
          14:00–19:00  Cashier
```

Remove the shift-level disclosure group. Each assignment becomes a direct child of the day disclosure.

### Row Layout (Two-Line)

- **Line 1:** Employee name (`.subheadline.bold()`) aligned leading. Orange filled circle (6pt, `circle.fill`) trailing if the parent shift has changed since last commit.
- **Line 2:** `startTime–endTime  requiredRole` in `.caption` / `.secondary`. Role as plain text, no capsule badge.
- **Unassigned shifts:** Line 1 text is `"Unassigned"` styled `.secondary`. One row per unfilled slot (i.e. if `maxEmployees = 2` and 0 assigned, show 1 unassigned row — not 2).

### Sort Order

Within a day, rows are sorted by:
1. `startTime` ascending
2. Employee name ascending (unassigned sorts last)

### Day Disclosure Label

Same as current: `formatShiftDate(day.date)` left, `"N shift(s)"` right in caption.

### What's Removed from Shifts Mode

- `ShiftDisclosureRow` nesting (still used in commit detail sheet — no changes there)
- Status text (Confirmed / Proposed / Overridden) on assignment rows
- Repeated date on shift rows
- Employee count indicator (`2/3`)

### What's Kept

- Week-level disclosure groups with `"Week of {weekStart}"` headline
- Day-level disclosure groups
- Changed indicator (converted from text badge to small orange dot)

## Files to Modify

| File | Change |
|------|--------|
| `Apps/AutorotaApp/Views/CommitHistoryView.swift` | Rewrite `.shifts` case in `commitList`. Replace `ShiftDisclosureRow` usage with new `FlatAssignmentRow`. Add helper to flatten shifts into sorted assignment entries per day. |
| `Apps/AutorotaApp/ViewModels/CommitHistoryViewModel.swift` | Add struct + computed property to produce flattened assignment rows grouped by day, carrying the `isChanged` flag from the parent shift. |

## Verification

1. Build check: `make swift-build-check-ios` and `make swift-build-check-macos`
2. Manual check in simulator:
   - Shifts mode shows two-line rows, no shift-level disclosure
   - Date not repeated on individual rows
   - Multi-person shifts show multiple rows under the same day
   - Unassigned shifts show "(Unassigned)" row
   - Changed dot appears on rows whose parent shift was modified
   - Commit detail sheet unchanged (still uses `ShiftDisclosureRow`)
