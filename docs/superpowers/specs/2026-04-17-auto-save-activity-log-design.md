# Auto-Save & Activity Log Design

**Date:** 2026-04-17
**Replaces:** Manual commit system (explicit shift selection + commit button)

---

## Overview

Replace the manual commit workflow with session-based auto-save. The system automatically creates immutable snapshots when the manager finishes editing. An activity log replaces the commit history view, showing a timeline of changes per week with optional user-applied labels and restore capability.

## Core Decisions

| Decision | Choice |
|---|---|
| Save scope | Full rota snapshot (all shifts for the week) |
| Auto-promotion | Removed — auto-save never mutates assignment status |
| Save triggers | Exit edit mode (primary), navigate away from week (safety net) |
| Log granularity | Save-point diffs only, not individual edits |
| Label UX | Text input inside expanded log entry (no star icon, no toast) |
| Commit UI | Removed entirely (button, selection mode, shift picking) |
| Restore UX | Inside expanded log entry, below changes, with confirmation alert |
| Rename scope | Full rename across all layers (Rust, FFI, Swift) |
| App backgrounding | Does NOT trigger save |

---

## 1. Data Model

### Migration

New SQL migration renames the table and adds label column:

```sql
ALTER TABLE commits RENAME TO saves;
ALTER TABLE saves ADD COLUMN label TEXT;
```

### Rust Models

File rename: `models/commit.rs` → `models/save.rs`

| Old | New | Notes |
|---|---|---|
| `Commit` | `Save` | Gains `label: Option<String>` |
| `CommitSnapshot` | `SaveSnapshot` | Unchanged fields |
| `CommitShiftSnapshot` | `SaveShiftSnapshot` | Unchanged |
| `CommitAssignmentSnapshot` | `SaveAssignmentSnapshot` | Unchanged |
| `CommitChangeKind` | `ChangeKind` | Same 9 variants |
| `CommitChangeDetail` | `ChangeDetail` | Same fields |
| `RestoreResult` | `RestoreResult` | Unchanged |

### Rust Queries

| Old | New | Behavior Change |
|---|---|---|
| `create_commit(rota_id, shift_ids)` | `create_save(rota_id)` | No shift_ids param — snapshots all shifts. No auto-promotion of Proposed→Confirmed. |
| `list_commits(rota_id)` | `list_saves(rota_id)` | Reads from `saves` table |
| `get_commit(id)` | `get_save(id)` | Same |
| `rota_has_commits(rota_id)` | `rota_has_saves(rota_id)` | Same |
| `diff_rota_vs_latest_commit_detailed()` | `diff_rota_vs_latest_save_detailed()` | Same |
| `diff_commits()` | `diff_saves()` | Same |
| `diff_commit_vs_previous()` | `diff_save_vs_previous()` | Same |
| `restore_from_commit()` | `restore_from_save()` | Same |
| `snapshot_from_live(rota_id, shift_ids)` | `snapshot_from_live(rota_id)` | No shift_ids — always all shifts |
| — | `update_save_label(id, label)` | **New** — sets or clears label text |

---

## 2. FFI Layer

### Types

| Old | New | Notes |
|---|---|---|
| `FfiCommit` | `FfiSave` | Gains `label: Option<String>` |
| `FfiCommitDetail` | `FfiSaveDetail` | Gains `label: Option<String>` |
| `FfiShiftDiff` | `FfiShiftDiff` | Unchanged |
| `FfiCommitChangeDetail` | `FfiChangeDetail` | Renamed only |
| `FfiRestoreResult` | `FfiRestoreResult` | Unchanged |

### Exported Functions

| Old | New |
|---|---|
| `commit_shifts(rota_id, shift_ids)` | `create_save(rota_id)` |
| `list_commits(rota_id)` | `list_saves(rota_id)` |
| `get_commit_detail(commit_id)` | `get_save_detail(save_id)` |
| `rota_is_committed(rota_id)` | `rota_has_saves(rota_id)` |
| `diff_rota(rota_id)` | `diff_rota(rota_id)` — unchanged |
| `diff_rota_detailed(rota_id)` | `diff_rota_detailed(rota_id)` — unchanged |
| `diff_commits_detailed(old, new)` | `diff_saves_detailed(old, new)` |
| `diff_commit_vs_previous(id)` | `diff_save_vs_previous(id)` |
| `restore_to_commit(id)` | `restore_to_save(id)` |
| — | `update_save_label(id, label)` — **new** |

### AutorotaKit Async Wrappers

Same rename pattern: `commitShiftsAsync` → `createSaveAsync`, etc. New `updateSaveLabelAsync`.

---

## 3. Swift Service Layer

### AutorotaServiceProtocol

| Old | New |
|---|---|
| `commitShifts(rotaId:shiftIds:)` | `createSave(rotaId:)` |
| `listCommits(rotaId:)` | `listSaves(rotaId:)` |
| `getCommitDetail(commitId:)` | `getSaveDetail(saveId:)` |
| `rotaIsCommitted(rotaId:)` | `rotaHasSaves(rotaId:)` |
| `diffCommitsDetailed(old:new:)` | `diffSavesDetailed(old:new:)` |
| `diffCommitVsPrevious(commitId:)` | `diffSaveVsPrevious(saveId:)` |
| `restoreToCommit(commitId:)` | `restoreToSave(saveId:)` |
| `diffRota(rotaId:)` | unchanged |
| `diffRotaDetailed(rotaId:)` | unchanged |
| — | `updateSaveLabel(saveId:label:)` — **new** |

### LiveAutorotaService

Wraps renamed FFI calls. `createSave` and `restoreToSave` still post `.autorotaDataChanged`.

### MockAutorotaService

Same renames. Stubs: `stubbedSaves`, `stubbedSaveDetail`, `stubbedRestoreResult`, `stubbedDetailedDiffResult`.

---

## 4. Auto-Save Trigger Logic

Integrated into `RotaViewModel` (no separate manager).

### Dirty Tracking

- `isDirty: Bool` flag on `RotaViewModel`
- Set `true` on any mutation (create/delete shift, assign/unassign, edit times, move assignment)
- Mutations already flow through ViewModel methods — set flag there

### Trigger Points

1. **Exit edit mode (checkmark tap):** If `isDirty && rotaId != nil`, call `createSave(rotaId:)`, reset `isDirty = false`.

2. **Week navigation (`selectedWeekStart` changes):** If `isDirty` and previous week's rota exists, save previous week before loading new week. Reset flag.

### Flow

```
mutation happens → isDirty = true
trigger fires → if isDirty && rotaId != nil:
    service.createSave(rotaId:)
    isDirty = false
```

---

## 5. Activity Log View

### File Renames

- `CommitHistoryView.swift` → `ActivityLogView.swift`
- `CommitHistoryViewModel.swift` → `ActivityLogViewModel.swift`

### Layout

**Top level:** Grouped by week, most recent first. Saves within each week newest-first. Labeled saves get visual distinction (bold label text).

**Collapsed log entry:**
- Timestamp (relative: "Today 2:15 PM" / absolute: "Mon 12 Apr, 9:30 AM")
- Label if present
- One-line auto-generated summary from diff

**Expanded log entry (tap to toggle):**
- `ChangeSummaryCard` tallies ("2 added, 1 removed, 3 modified")
- Change list grouped by date, using existing `ChangeRow` cards (color-coded, SF Symbols, plain English)
- Text field for label (add/edit)
- Restore button (destructive style) at bottom → confirmation alert

### Removed

- `HistoryMode` picker (shifts vs commits toggle)
- `CommitDetailSheet` (replaced by inline expansion)
- Snapshot JSON viewer
- Shifts-mode flattened view and all supporting code:
  - `latestShiftsByWeek` computed property
  - `flatEntries()` method
  - `SnapshotData`, `ShiftData`, `AssignmentData`, `FlatAssignmentEntry` structs
  - `snapshotsByCommitId` cache
  - `loadAllSnapshotsIfNeeded()` method
  - `refreshChangedShiftsForAllWeeks()` method
  - `changedShiftIdsByWeek` dictionary

### ViewModel Properties

| Old | New |
|---|---|
| `commits` | `saves` |
| `snapshotsByCommitId` | removed |
| `changesByCommitId` | `changesBySaveId` |
| `changedShiftIdsByWeek` | removed |
| `commitsByWeek` | `savesByWeek` |
| `selectedCommitDetail` | removed |
| `mode` | removed |
| — | `expandedSaveId: Int64?` — tracks which entry is expanded |

### ViewModel Methods

| Old | New |
|---|---|
| `loadCommits()` | `loadSaves()` |
| `loadCommitDetail(id:)` | removed |
| `clearDetail()` | removed |
| `loadAllSnapshotsIfNeeded()` | removed |
| `refreshChangedShiftsForAllWeeks()` | removed |
| `flatEntries(for:changedIds:)` | removed |
| `loadChangesForCommit(id:)` | `loadChangesForSave(id:)` |
| `restoreToCommit(id:summary:weekStart:)` | `restoreToSave(id:summary:weekStart:)` |
| — | `updateLabel(saveId:label:)` — **new** |
| — | `toggleExpanded(saveId:)` — **new** |

---

## 6. RotaView Changes

### Removed

- "Commit" button in overflow menu
- `enterSelectMode()` / `isSelectingForCommit` state
- `selectedShiftIds` set
- Bottom bar (shift selection, "Select All", "Commit" button)
- Day header "Select Day" button in selection mode
- `commitSelected()` method
- `selectAllPastShifts()` method

### Added

- `isDirty: Bool` on `RotaViewModel`
- Auto-save call on exit edit mode
- Auto-save call on week navigation (if dirty)

---

## 7. Test Changes

### Rust Tests (204 total)

All tests referencing `create_commit`, `Commit`, `CommitSnapshot`, etc. renamed to `create_save`, `Save`, `SaveSnapshot`. Key behavioral changes:
- `create_save` tests: verify no `shift_ids` param, verify no auto-promotion
- Existing diff tests: rename only, logic unchanged
- Existing restore tests: rename only, logic unchanged
- New test: `update_save_label` sets and clears label

### Swift ViewModel Tests (60 total)

- `CommitHistoryViewModelTests` → `ActivityLogViewModelTests` (if exists)
- `RotaViewModelTests`: remove `commitSelected` tests, add `isDirty` flag tests, add auto-save trigger tests
- Mock stubs renamed throughout

---

## 8. Tab/Navigation Rename

Current tab referencing "Commit History" or similar → "Activity Log". Update `TabPage` enum if it references commit history.

---

## Verification

```bash
cargo fmt && cargo clippy && cargo test       # All Rust tests pass
make swift-build-check                        # Swift compiles (all platforms)
make swift-test-app-macos                     # ViewModel tests pass
```

- Edit a week, tap checkmark → save created, visible in Activity Log
- Navigate away from dirty week → save created automatically
- Tap log entry → expands inline showing changes + label field + restore
- Add label → persists, visible on collapsed entry
- Restore → confirmation alert → rota state restored, toast shown
- No "Commit" button anywhere in UI
