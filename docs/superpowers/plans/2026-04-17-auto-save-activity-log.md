# Auto-Save & Activity Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manual commit workflow with session-based auto-save and an activity log view, with full rename of "commit" → "save" across all layers.

**Architecture:** Full rename from `commits` → `saves` across Rust core, FFI, and Swift layers. Auto-save triggers on edit mode exit and week navigation. Activity log replaces commit history with inline-expandable entries, labeling, and restore.

**Tech Stack:** Rust (sqlx, serde, chrono), UniFFI, SwiftUI (Observation framework), Swift Testing

---

### Task 1: Rust — DB migration and model rename

**Files:**
- Create: `crates/autorota-core/migrations/016_rename_commits_to_saves.sql`
- Rename: `crates/autorota-core/src/models/commit.rs` → `crates/autorota-core/src/models/save.rs`
- Modify: `crates/autorota-core/src/models/mod.rs:3`
- Modify: `crates/autorota-core/src/db/mod.rs` (add migration 016)

- [ ] **Step 1: Create migration file**

Create `crates/autorota-core/migrations/016_rename_commits_to_saves.sql`:

```sql
ALTER TABLE commits RENAME TO saves;
ALTER TABLE saves ADD COLUMN label TEXT;
```

- [ ] **Step 2: Wire migration in db/mod.rs**

Add migration 016 after the migration 015 block (after line 238 in `crates/autorota-core/src/db/mod.rs`):

```rust
// Migration 016: rename commits → saves, add label column.
let has_commits_table: bool = sqlx::query_scalar(
    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='commits'",
)
.fetch_one(pool)
.await?;

if has_commits_table {
    let m16 = include_str!("../../migrations/016_rename_commits_to_saves.sql");
    sqlx::raw_sql(m16).execute(pool).await?;
}
```

- [ ] **Step 3: Rename model file and update mod.rs**

Rename `crates/autorota-core/src/models/commit.rs` → `crates/autorota-core/src/models/save.rs`.

In `crates/autorota-core/src/models/mod.rs`, change line 3:

```rust
// Old:
pub mod commit;
// New:
pub mod save;
```

- [ ] **Step 4: Rename all structs and types in save.rs**

In `crates/autorota-core/src/models/save.rs`, apply these renames throughout the entire file:

| Old | New |
|-----|-----|
| `Commit` (struct) | `Save` |
| `CommitSnapshot` | `SaveSnapshot` |
| `CommitShiftSnapshot` | `SaveShiftSnapshot` |
| `CommitAssignmentSnapshot` | `SaveAssignmentSnapshot` |
| `CommitChangeKind` | `ChangeKind` |
| `CommitChangeDetail` | `ChangeDetail` |

Add `label` field to `Save` struct:

```rust
#[derive(Debug, Clone)]
pub struct Save {
    pub id: i64,
    pub rota_id: i64,
    pub committed_at: String,
    pub summary: String,
    pub snapshot_json: String,
    pub label: Option<String>,
}
```

Also rename `committed_at` → `saved_at` in the `Save` struct for consistency:

```rust
pub struct Save {
    pub id: i64,
    pub rota_id: i64,
    pub saved_at: String,
    pub summary: String,
    pub snapshot_json: String,
    pub label: Option<String>,
}
```

Update all doc comments to say "save" instead of "commit". Update `diff_snapshots` function signature types:

```rust
pub fn diff_snapshots(old: &SaveSnapshot, new: &SaveSnapshot) -> Vec<ChangeDetail> {
```

Update `collapse_moves` to use renamed types:

```rust
fn collapse_moves(
    old_by_id: &std::collections::HashMap<i64, &SaveShiftSnapshot>,
    changes: Vec<ChangeDetail>,
) -> Vec<ChangeDetail> {
```

Update all internal usages: `CommitChangeKind::ShiftAdded` → `ChangeKind::ShiftAdded`, etc. throughout the entire file.

- [ ] **Step 5: Update unit tests in save.rs**

Rename the test module and all helper functions. The tests stay structurally identical — only type names change:

```rust
#[cfg(test)]
mod diff_tests {
    use super::*;

    fn shift(
        id: i64,
        date: &str,
        start: &str,
        end: &str,
        role: &str,
        min: u32,
        max: u32,
        assignments: Vec<SaveAssignmentSnapshot>,
    ) -> SaveShiftSnapshot {
        SaveShiftSnapshot {
            shift_id: id,
            date: date.to_string(),
            start_time: start.to_string(),
            end_time: end.to_string(),
            required_role: role.to_string(),
            min_employees: min,
            max_employees: max,
            assignments,
        }
    }

    fn assign(emp_id: i64, name: &str, status: &str) -> SaveAssignmentSnapshot {
        SaveAssignmentSnapshot {
            assignment_id: 0,
            employee_id: emp_id,
            employee_name: name.to_string(),
            status: status.to_string(),
            hourly_wage: None,
            wage_currency: None,
        }
    }

    fn snap(shifts: Vec<SaveShiftSnapshot>) -> SaveSnapshot {
        SaveSnapshot {
            week_start: "2026-04-20".to_string(),
            committed_shift_ids: shifts.iter().map(|s| s.shift_id).collect(),
            shifts,
            total_hours: 0.0,
            total_shifts: 0,
            unique_employees: 0,
        }
    }

    // All 7 existing tests remain identical in logic, just use renamed types:
    // no_changes_returns_empty, detects_new_shift, detects_removed_shift,
    // detects_time_capacity_role_changes, detects_assignment_add_remove_status,
    // collapses_same_day_move, does_not_collapse_across_dates
    //
    // Match patterns change: ChangeKind::ShiftAdded, ChangeKind::ShiftRemoved, etc.
}
```

- [ ] **Step 6: Run Rust tests to verify model rename compiles**

Run: `cargo check -p autorota-core 2>&1 | head -30`

Expected: Compilation errors in `queries.rs` and other files that import `commit` module. This is expected — Task 2 fixes queries.

- [ ] **Step 7: Commit**

```bash
git add crates/autorota-core/migrations/016_rename_commits_to_saves.sql \
  crates/autorota-core/src/models/save.rs \
  crates/autorota-core/src/models/mod.rs \
  crates/autorota-core/src/db/mod.rs
git rm crates/autorota-core/src/models/commit.rs
git commit -m "refactor(core): rename commits to saves, add label column"
```

---

### Task 2: Rust — Rename and modify queries

**Files:**
- Modify: `crates/autorota-core/src/db/queries.rs:1245-1890`

- [ ] **Step 1: Update imports at top of queries.rs**

Find all imports from `commit` module and update:

```rust
// Old:
use crate::models::commit::{
    Commit, CommitAssignmentSnapshot, CommitChangeDetail, CommitSnapshot,
    CommitShiftSnapshot, RestoreResult, ShiftDiff, diff_snapshots,
};
// New:
use crate::models::save::{
    Save, SaveAssignmentSnapshot, ChangeDetail, SaveSnapshot,
    SaveShiftSnapshot, RestoreResult, ShiftDiff, diff_snapshots,
};
```

- [ ] **Step 2: Rename `create_commit` → `create_save` and modify behavior**

Replace the entire `create_commit` function (lines 1249-1376) with `create_save`. Key changes:
- Remove `shift_ids` parameter — always snapshot all shifts for the rota
- Remove the empty-shift-ids guard
- Remove the auto-promotion UPDATE query
- Read from `saves` table instead of `commits`
- Add `label` column (NULL) in INSERT
- Use `saved_at` field name in the Save struct

```rust
/// Create a save (immutable snapshot) of all shifts and assignments for a rota.
/// Returns the new save ID.
pub async fn create_save(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<i64, sqlx::Error> {
    let week_start_str: String = sqlx::query_scalar("SELECT week_start FROM rotas WHERE id = ?")
        .bind(rota_id)
        .fetch_one(pool)
        .await?;

    let shifts = list_shifts_for_rota(pool, rota_id).await?;
    if shifts.is_empty() {
        return Err(sqlx::Error::Protocol("no shifts to save".to_string()));
    }

    let all_assignments = list_assignments_for_rota(pool, rota_id).await?;
    let employee_ids: Vec<i64> = all_assignments
        .iter()
        .map(|a| a.employee_id)
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let mut wage_currencies: HashMap<i64, Option<String>> = HashMap::new();
    for &eid in &employee_ids {
        let currency: Option<String> =
            sqlx::query_scalar("SELECT wage_currency FROM employees WHERE id = ?")
                .bind(eid)
                .fetch_optional(pool)
                .await?
                .flatten();
        wage_currencies.insert(eid, currency);
    }

    let mut snapshot_shifts = Vec::new();
    let mut all_employee_ids: HashSet<i64> = HashSet::new();
    let mut total_hours: f32 = 0.0;

    for shift in &shifts {
        let assignment_snapshots: Vec<SaveAssignmentSnapshot> = all_assignments
            .iter()
            .filter(|a| a.shift_id == shift.id)
            .map(|a| {
                all_employee_ids.insert(a.employee_id);
                SaveAssignmentSnapshot {
                    assignment_id: a.id,
                    employee_id: a.employee_id,
                    employee_name: a.employee_name.clone().unwrap_or_default(),
                    status: a.status.to_string(),
                    hourly_wage: a.hourly_wage,
                    wage_currency: wage_currencies.get(&a.employee_id).cloned().flatten(),
                }
            })
            .collect();

        total_hours += shift.duration_hours();

        snapshot_shifts.push(SaveShiftSnapshot {
            shift_id: shift.id,
            date: shift.date.to_string(),
            start_time: shift.start_time.format("%H:%M").to_string(),
            end_time: shift.end_time.format("%H:%M").to_string(),
            required_role: shift.required_role.clone(),
            min_employees: shift.min_employees,
            max_employees: shift.max_employees,
            assignments: assignment_snapshots,
        });
    }

    let committed_shift_ids: Vec<i64> = shifts.iter().map(|s| s.id).collect();
    let snapshot = SaveSnapshot {
        week_start: week_start_str,
        committed_shift_ids,
        shifts: snapshot_shifts,
        total_hours,
        total_shifts: shifts.len(),
        unique_employees: all_employee_ids.len(),
    };

    let snapshot_json =
        serde_json::to_string(&snapshot).map_err(|e| sqlx::Error::Protocol(e.to_string()))?;

    let summary = generate_save_summary(shifts.len(), all_employee_ids.len(), total_hours);
    let now = chrono::Utc::now().to_rfc3339();

    let save_id: i64 = sqlx::query_scalar(
        "INSERT INTO saves (rota_id, committed_at, summary, snapshot_json, label) VALUES (?, ?, ?, ?, NULL) RETURNING id",
    )
    .bind(rota_id)
    .bind(&now)
    .bind(&summary)
    .bind(&snapshot_json)
    .fetch_one(pool)
    .await?;

    Ok(save_id)
}
```

- [ ] **Step 3: Rename `generate_commit_summary` → `generate_save_summary`**

```rust
fn generate_save_summary(
    total_shifts: usize,
    unique_employees: usize,
    total_hours: f32,
) -> String {
    format!(
        "{} shift{}, {} employee{}, {:.0}h",
        total_shifts,
        if total_shifts == 1 { "" } else { "s" },
        unique_employees,
        if unique_employees == 1 { "" } else { "s" },
        total_hours,
    )
}
```

- [ ] **Step 4: Rename remaining query functions**

Rename all commit-related functions and update SQL to read from `saves` table:

| Old function | New function | SQL table change |
|---|---|---|
| `list_commits` | `list_saves` | `FROM commits` → `FROM saves` |
| `get_commit` | `get_save` | `FROM commits` → `FROM saves` |
| `rota_has_commits` | `rota_has_saves` | `FROM commits` → `FROM saves` |
| `commit_from_row` | `save_from_row` | Return `Save` with `label` field |
| `diff_rota_vs_latest_commit` | `diff_rota_vs_latest_save` | `FROM commits` → `FROM saves` |
| `diff_rota_vs_latest_commit_detailed` | `diff_rota_vs_latest_save_detailed` | `FROM commits` → `FROM saves` |
| `diff_commits` | `diff_saves` | uses `get_save` |
| `diff_commit_vs_previous` | `diff_save_vs_previous` | `FROM commits` → `FROM saves` |
| `restore_from_commit` | `restore_from_save` | uses `get_save` |
| `empty_snapshot` | `empty_snapshot` | unchanged |
| `snapshot_from_live` | `snapshot_from_live` | remove `shift_ids` param |

Update `save_from_row` to handle the new `label` column:

```rust
fn save_from_row(row: (i64, i64, String, String, String, Option<String>)) -> Save {
    let (id, rota_id, saved_at, summary, snapshot_json, label) = row;
    Save {
        id,
        rota_id,
        saved_at,
        summary,
        snapshot_json,
        label,
    }
}
```

Update all `query_as` calls for saves to select `label`:

```rust
// In list_saves:
"SELECT id, rota_id, committed_at, summary, snapshot_json, label FROM saves ..."

// In get_save:
"SELECT id, rota_id, committed_at, summary, snapshot_json, label FROM saves WHERE id = ?"
```

Update `snapshot_from_live` — remove `shift_ids` parameter:

```rust
pub async fn snapshot_from_live(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<SaveSnapshot, sqlx::Error> {
    // ... always use list_shifts_for_rota(pool, rota_id), no shift_ids filtering
```

Update all internal type references: `CommitSnapshot` → `SaveSnapshot`, `CommitChangeDetail` → `ChangeDetail`, etc.

- [ ] **Step 5: Add `update_save_label` function**

Add after `restore_from_save`:

```rust
/// Set or clear the label on a save.
pub async fn update_save_label(
    pool: &SqlitePool,
    save_id: i64,
    label: Option<&str>,
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE saves SET label = ? WHERE id = ?")
        .bind(label)
        .bind(save_id)
        .execute(pool)
        .await?;
    Ok(())
}
```

- [ ] **Step 6: Run cargo check**

Run: `cargo check -p autorota-core 2>&1 | head -40`

Expected: Errors in FFI crate (Task 3) and integration tests (Task 4). Core crate should compile.

- [ ] **Step 7: Commit**

```bash
git add crates/autorota-core/src/db/queries.rs
git commit -m "refactor(core): rename query functions commit→save, remove auto-promotion"
```

---

### Task 3: Rust — Update integration tests

**Files:**
- Modify: `crates/autorota-core/tests/edge_cases_test.rs`

- [ ] **Step 1: Update imports in edge_cases_test.rs**

Replace any `commit` module imports with `save`:

```rust
// If present, update:
// use autorota_core::models::commit::*;
// to:
// use autorota_core::models::save::*;
```

- [ ] **Step 2: Rename test functions and update calls**

Rename the 5 commit-related tests:

| Old test | New test |
|---|---|
| `create_commit_and_retrieve` | `create_save_and_retrieve` |
| `create_commit_rejects_empty_shift_ids` | (DELETE — `create_save` no longer takes shift_ids, and the "no shifts" error comes from empty rota, not empty param) |
| `create_commit_auto_promotes_proposed_to_confirmed` | (DELETE — auto-promotion removed) |
| `restore_from_commit_recreates_shifts_and_assignments` | `restore_from_save_recreates_shifts_and_assignments` |
| `restore_from_commit_skips_assignments_for_deleted_employees` | `restore_from_save_skips_assignments_for_deleted_employees` |

For `create_save_and_retrieve`, update the call:

```rust
// Old:
let commit_id = queries::create_commit(&pool, rota_id, &shift_ids).await.unwrap();
let commits = queries::list_commits(&pool, Some(rota_id)).await.unwrap();
// New:
let save_id = queries::create_save(&pool, rota_id).await.unwrap();
let saves = queries::list_saves(&pool, Some(rota_id)).await.unwrap();
```

For restore tests, update:

```rust
// Old:
let result = queries::restore_from_commit(&pool, commit_id).await.unwrap();
// New:
let result = queries::restore_from_save(&pool, save_id).await.unwrap();
```

- [ ] **Step 3: Add new test for `create_save` with no shifts returns error**

```rust
#[sqlx::test]
async fn create_save_rejects_empty_rota(pool: SqlitePool) {
    queries::run_migrations(&pool).await.unwrap();
    // Create a rota with no shifts
    let rota_id = queries::create_rota(&pool, "2026-04-20").await.unwrap();
    let result = queries::create_save(&pool, rota_id).await;
    assert!(result.is_err());
}
```

- [ ] **Step 4: Add test for `update_save_label`**

```rust
#[sqlx::test]
async fn update_save_label_sets_and_clears(pool: SqlitePool) {
    queries::run_migrations(&pool).await.unwrap();
    // Setup: create rota with a shift, then save
    let rota_id = helpers::setup_rota_with_shift(&pool).await;
    let save_id = queries::create_save(&pool, rota_id).await.unwrap();

    // Set label
    queries::update_save_label(&pool, save_id, Some("Final schedule")).await.unwrap();
    let save = queries::get_save(&pool, save_id).await.unwrap().unwrap();
    assert_eq!(save.label.as_deref(), Some("Final schedule"));

    // Clear label
    queries::update_save_label(&pool, save_id, None).await.unwrap();
    let save = queries::get_save(&pool, save_id).await.unwrap().unwrap();
    assert!(save.label.is_none());
}
```

Note: If `setup_rota_with_shift` doesn't exist as a helper, create a rota via `create_rota`, then materialise or create shifts manually, matching existing test patterns in the file.

- [ ] **Step 5: Run Rust tests**

Run: `cargo test -p autorota-core 2>&1 | tail -20`

Expected: All tests pass (model diff_tests + integration tests). FFI crate will still have errors.

- [ ] **Step 6: Commit**

```bash
git add crates/autorota-core/tests/edge_cases_test.rs
git commit -m "test(core): update integration tests for save rename"
```

---

### Task 4: FFI — Rename types and functions

**Files:**
- Modify: `crates/autorota-ffi/src/types.rs:198-288`
- Modify: `crates/autorota-ffi/src/lib.rs:1601-1835`

- [ ] **Step 1: Rename FFI types in types.rs**

| Old | New | Additional changes |
|---|---|---|
| `FfiCommit` | `FfiSave` | Add `label: Option<String>`, rename `committed_at` → `saved_at` |
| `FfiCommitDetail` | `FfiSaveDetail` | Add `label: Option<String>`, rename `committed_at` → `saved_at` |
| `FfiCommitChangeDetail` | `FfiChangeDetail` | Rename only |
| Comment "Commits" section header | "Saves" | |

```rust
// ── Saves ──────────────────────────────────────────────────────────────────

/// A save record (for list views — excludes the full snapshot JSON).
#[derive(Clone, uniffi::Record)]
pub struct FfiSave {
    pub id: i64,
    pub rota_id: i64,
    pub saved_at: String,
    pub summary: String,
    /// Denormalized from the rota for display convenience.
    pub week_start: String,
    pub label: Option<String>,
}

/// A save record with the full snapshot JSON (for detail views).
#[derive(Clone, uniffi::Record)]
pub struct FfiSaveDetail {
    pub id: i64,
    pub rota_id: i64,
    pub saved_at: String,
    pub summary: String,
    pub week_start: String,
    pub snapshot_json: String,
    pub label: Option<String>,
}
```

Rename `FfiCommitChangeDetail` → `FfiChangeDetail` (same fields, new name).

Also rename `FfiWeekSchedule.committed` → `FfiWeekSchedule.has_saves`:

```rust
pub struct FfiWeekSchedule {
    pub rota_id: i64,
    pub week_start: String,
    /// Whether this rota has at least one save.
    pub has_saves: bool,
    pub entries: Vec<FfiScheduleEntry>,
    pub shifts: Vec<FfiShiftInfo>,
}
```

- [ ] **Step 2: Rename FFI exported functions in lib.rs**

Replace the entire commits section (lines 1601-1835):

| Old | New |
|---|---|
| `commit_shifts(rota_id, shift_ids)` | `create_save(rota_id)` |
| `list_commits(rota_id)` | `list_saves(rota_id)` |
| `get_commit_detail(commit_id)` | `get_save_detail(save_id)` |
| `rota_is_committed(rota_id)` | `rota_has_saves(rota_id)` |
| `restore_to_commit(commit_id)` | `restore_to_save(save_id)` |
| `diff_rota_detailed(rota_id)` | `diff_rota_detailed(rota_id)` — keep name, update types |
| `diff_commits_detailed(old, new)` | `diff_saves_detailed(old, new)` |
| `diff_commit_vs_previous(id)` | `diff_save_vs_previous(id)` |
| `change_detail_to_ffi` | `change_detail_to_ffi` — update types |

Key function changes:

```rust
#[uniffi::export]
pub fn create_save(rota_id: i64) -> Result<i64, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::create_save(pool, rota_id))
        .map_err(Into::into)
}

#[uniffi::export]
pub fn list_saves(rota_id: Option<i64>) -> Result<Vec<FfiSave>, FfiError> {
    let pool = pool()?;
    let result: Result<Vec<FfiSave>, sqlx::Error> = rt().block_on(async move {
        let saves = queries::list_saves(pool, rota_id).await?;
        let mut ffi_saves = Vec::new();
        for s in saves {
            let week_start: Option<String> =
                sqlx::query_scalar("SELECT week_start FROM rotas WHERE id = ?")
                    .bind(s.rota_id)
                    .fetch_optional(pool)
                    .await?;
            let Some(week_start) = week_start else { continue };
            ffi_saves.push(FfiSave {
                id: s.id,
                rota_id: s.rota_id,
                saved_at: s.saved_at,
                summary: s.summary,
                week_start,
                label: s.label,
            });
        }
        Ok(ffi_saves)
    });
    result.map_err(Into::into)
}

#[uniffi::export]
pub fn get_save_detail(save_id: i64) -> Result<Option<FfiSaveDetail>, FfiError> {
    let pool = pool()?;
    let result: Result<Option<FfiSaveDetail>, sqlx::Error> = rt().block_on(async move {
        let save = match queries::get_save(pool, save_id).await? {
            Some(s) => s,
            None => return Ok(None),
        };
        let week_start: Option<String> =
            sqlx::query_scalar("SELECT week_start FROM rotas WHERE id = ?")
                .bind(save.rota_id)
                .fetch_optional(pool)
                .await?;
        let Some(week_start) = week_start else { return Ok(None) };
        Ok(Some(FfiSaveDetail {
            id: save.id,
            rota_id: save.rota_id,
            saved_at: save.saved_at,
            summary: save.summary,
            week_start,
            snapshot_json: save.snapshot_json,
            label: save.label,
        }))
    });
    result.map_err(Into::into)
}

#[uniffi::export]
pub fn rota_has_saves(rota_id: i64) -> Result<bool, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::rota_has_saves(pool, rota_id))
        .map_err(Into::into)
}

#[uniffi::export]
pub fn restore_to_save(save_id: i64) -> Result<FfiRestoreResult, FfiError> {
    let pool = pool()?;
    let result = rt().block_on(queries::restore_from_save(pool, save_id))?;
    Ok(FfiRestoreResult {
        rota_id: result.rota_id,
        shifts_restored: result.shifts_restored as u32,
        assignments_restored: result.assignments_restored as u32,
        assignments_skipped: result.assignments_skipped as u32,
    })
}

#[uniffi::export]
pub fn update_save_label(save_id: i64, label: Option<String>) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::update_save_label(pool, save_id, label.as_deref()))
        .map_err(Into::into)
}
```

Update `change_detail_to_ffi` to use renamed types:

```rust
fn change_detail_to_ffi(
    d: autorota_core::models::save::ChangeDetail,
) -> FfiChangeDetail {
    use autorota_core::models::save::ChangeKind as K;
    let mut out = FfiChangeDetail {
        // ... same field initialization, just different type names
    };
    // ... same match arms, using K:: instead of CommitChangeKind::
    out
}
```

Also update `get_week_schedule` (around line 737) to use renamed query:

```rust
// Old:
let committed = queries::rota_has_commits(pool, rota.id).await?;
// New:
let has_saves = queries::rota_has_saves(pool, rota.id).await?;
```

And the FfiWeekSchedule construction:

```rust
// Old:
committed,
// New:
has_saves,
```

- [ ] **Step 3: Update diff_rota and diff_rota_detailed**

```rust
#[uniffi::export]
pub fn diff_rota(rota_id: i64) -> Result<Vec<FfiShiftDiff>, FfiError> {
    let pool = pool()?;
    let result: Result<Vec<FfiShiftDiff>, sqlx::Error> = rt().block_on(async move {
        let diffs = queries::diff_rota_vs_latest_save(pool, rota_id).await?;
        Ok(diffs
            .into_iter()
            .map(|d| FfiShiftDiff {
                shift_id: d.shift_id,
                is_new: d.is_new,
                is_changed: d.is_changed,
            })
            .collect())
    });
    result.map_err(Into::into)
}

#[uniffi::export]
pub fn diff_rota_detailed(rota_id: i64) -> Result<Vec<FfiChangeDetail>, FfiError> {
    let pool = pool()?;
    let details = rt().block_on(queries::diff_rota_vs_latest_save_detailed(pool, rota_id))?;
    Ok(details.into_iter().map(change_detail_to_ffi).collect())
}

#[uniffi::export]
pub fn diff_saves_detailed(
    old_save_id: i64,
    new_save_id: i64,
) -> Result<Vec<FfiChangeDetail>, FfiError> {
    let pool = pool()?;
    let details = rt().block_on(queries::diff_saves(pool, old_save_id, new_save_id))?;
    Ok(details.into_iter().map(change_detail_to_ffi).collect())
}

#[uniffi::export]
pub fn diff_save_vs_previous(save_id: i64) -> Result<Vec<FfiChangeDetail>, FfiError> {
    let pool = pool()?;
    let details = rt().block_on(queries::diff_save_vs_previous(pool, save_id))?;
    Ok(details.into_iter().map(change_detail_to_ffi).collect())
}
```

- [ ] **Step 4: Run full Rust build**

Run: `cargo fmt && cargo clippy && cargo test 2>&1 | tail -30`

Expected: All 204+ tests pass. No warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/autorota-ffi/src/types.rs crates/autorota-ffi/src/lib.rs
git commit -m "refactor(ffi): rename commit types and exports to save"
```

---

### Task 5: FFI — Rebuild XCFramework and update Swift wrappers

**Files:**
- Modify: `platforms/apple/AutorotaKit/Sources/AutorotaKit/AutorotaKit.swift`

- [ ] **Step 1: Rebuild XCFramework**

Run: `make swift-build-xcframework-debug`

This regenerates the UniFFI Swift bindings with the new function/type names.

- [ ] **Step 2: Rename async wrappers in AutorotaKit.swift**

Update the Commits section (around line 304):

```swift
// MARK: - Saves

public func createSaveAsync(rotaId: Int64) async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try createSave(rotaId: rotaId)
    }.value
}

public func listSavesAsync(rotaId: Int64?) async throws -> [FfiSave] {
    try await Task.detached(priority: .userInitiated) {
        try listSaves(rotaId: rotaId)
    }.value
}

public func getSaveDetailAsync(saveId: Int64) async throws -> FfiSaveDetail? {
    try await Task.detached(priority: .userInitiated) {
        try getSaveDetail(saveId: saveId)
    }.value
}

public func rotaHasSavesAsync(rotaId: Int64) async throws -> Bool {
    try await Task.detached(priority: .userInitiated) {
        try rotaHasSaves(rotaId: rotaId)
    }.value
}

public func restoreToSaveAsync(saveId: Int64) async throws -> FfiRestoreResult {
    try await Task.detached(priority: .userInitiated) {
        try restoreToSave(saveId: saveId)
    }.value
}

public func diffRotaDetailedAsync(rotaId: Int64) async throws -> [FfiChangeDetail] {
    try await Task.detached(priority: .userInitiated) {
        try diffRotaDetailed(rotaId: rotaId)
    }.value
}

public func diffSavesDetailedAsync(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail] {
    try await Task.detached(priority: .userInitiated) {
        try diffSavesDetailed(oldSaveId: oldSaveId, newSaveId: newSaveId)
    }.value
}

public func diffSaveVsPreviousAsync(saveId: Int64) async throws -> [FfiChangeDetail] {
    try await Task.detached(priority: .userInitiated) {
        try diffSaveVsPrevious(saveId: saveId)
    }.value
}

public func updateSaveLabelAsync(saveId: Int64, label: String?) async throws {
    try await Task.detached(priority: .userInitiated) {
        try updateSaveLabel(saveId: saveId, label: label)
    }.value
}
```

Remove the old commit wrappers: `commitShiftsAsync`, `listCommitsAsync`, `getCommitDetailAsync`, `rotaIsCommittedAsync`, `restoreToCommitAsync`, `diffRotaDetailedAsync` (old version), `diffCommitsDetailedAsync`, `diffCommitVsPreviousAsync`.

Also update `diffRotaAsync` to use renamed query:

```swift
public func diffRotaAsync(rotaId: Int64) async throws -> [FfiShiftDiff] {
    try await Task.detached(priority: .userInitiated) {
        try diffRota(rotaId: rotaId)
    }.value
}
```

- [ ] **Step 3: Commit**

```bash
git add platforms/apple/AutorotaKit/Sources/AutorotaKit/AutorotaKit.swift
git commit -m "refactor(kit): rename async wrappers commit→save"
```

---

### Task 6: Swift — Rename service protocol and implementations

**Files:**
- Modify: `platforms/apple/Apps/AutorotaApp/Services/AutorotaServiceProtocol.swift`
- Modify: `platforms/apple/Apps/AutorotaApp/Services/LiveAutorotaService.swift`
- Modify: `platforms/apple/Apps/AutorotaApp/AutorotaAppTests/MockAutorotaService.swift`

- [ ] **Step 1: Update AutorotaServiceProtocol**

Replace the commit methods (around lines 61-70):

```swift
// MARK: - Saves
func createSave(rotaId: Int64) async throws -> Int64
func listSaves(rotaId: Int64?) async throws -> [FfiSave]
func getSaveDetail(saveId: Int64) async throws -> FfiSaveDetail?
func rotaHasSaves(rotaId: Int64) async throws -> Bool
func diffSavesDetailed(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail]
func diffSaveVsPrevious(saveId: Int64) async throws -> [FfiChangeDetail]
func restoreToSave(saveId: Int64) async throws -> FfiRestoreResult
func updateSaveLabel(saveId: Int64, label: String?) async throws
```

Keep `diffRota` and `diffRotaDetailed` unchanged (same names, just return `FfiChangeDetail` instead of `FfiCommitChangeDetail`).

Remove: `commitShifts(rotaId:shiftIds:)`, `listCommits(rotaId:)`, `getCommitDetail(commitId:)`, `rotaIsCommitted(rotaId:)`, `diffCommitsDetailed(oldCommitId:newCommitId:)`, `diffCommitVsPrevious(commitId:)`, `restoreToCommit(commitId:)`.

- [ ] **Step 2: Update LiveAutorotaService**

Replace commit implementations:

```swift
// Saves
func createSave(rotaId: Int64) async throws -> Int64 {
    let id = try await createSaveAsync(rotaId: rotaId)
    NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    return id
}
func listSaves(rotaId: Int64?) async throws -> [FfiSave] { try await listSavesAsync(rotaId: rotaId) }
func getSaveDetail(saveId: Int64) async throws -> FfiSaveDetail? { try await getSaveDetailAsync(saveId: saveId) }
func rotaHasSaves(rotaId: Int64) async throws -> Bool { try await rotaHasSavesAsync(rotaId: rotaId) }
func diffSavesDetailed(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail] {
    try await diffSavesDetailedAsync(oldSaveId: oldSaveId, newSaveId: newSaveId)
}
func diffSaveVsPrevious(saveId: Int64) async throws -> [FfiChangeDetail] {
    try await diffSaveVsPreviousAsync(saveId: saveId)
}
func restoreToSave(saveId: Int64) async throws -> FfiRestoreResult {
    let result = try await restoreToSaveAsync(saveId: saveId)
    NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    return result
}
func updateSaveLabel(saveId: Int64, label: String?) async throws {
    try await updateSaveLabelAsync(saveId: saveId, label: label)
}
```

Update `diffRotaDetailed` return type:

```swift
func diffRotaDetailed(rotaId: Int64) async throws -> [FfiChangeDetail] {
    try await diffRotaDetailedAsync(rotaId: rotaId)
}
```

Remove old commit function implementations.

- [ ] **Step 3: Update MockAutorotaService**

Replace commit stubs:

```swift
// MARK: - Saves

var stubbedSaves: [FfiSave] = []
var stubbedSaveDetail: FfiSaveDetail? = nil
var stubbedHasSaves = false
var stubbedDiffResult: [FfiShiftDiff] = []
var stubbedDetailedDiffResult: [FfiChangeDetail] = []
var stubbedRestoreResult = FfiRestoreResult(
    rotaId: 1, shiftsRestored: 0, assignmentsRestored: 0, assignmentsSkipped: 0
)

func createSave(rotaId: Int64) async throws -> Int64 {
    callLog.append("createSave:\(rotaId)")
    if let e = errorToThrow { throw e }
    return 1
}

func diffRota(rotaId: Int64) async throws -> [FfiShiftDiff] {
    callLog.append("diffRota:\(rotaId)")
    if let e = errorToThrow { throw e }
    return stubbedDiffResult
}

func listSaves(rotaId: Int64?) async throws -> [FfiSave] {
    callLog.append("listSaves:\(String(describing: rotaId))")
    if let e = errorToThrow { throw e }
    return stubbedSaves
}

func getSaveDetail(saveId: Int64) async throws -> FfiSaveDetail? {
    callLog.append("getSaveDetail:\(saveId)")
    if let e = errorToThrow { throw e }
    return stubbedSaveDetail
}

func rotaHasSaves(rotaId: Int64) async throws -> Bool {
    callLog.append("rotaHasSaves:\(rotaId)")
    if let e = errorToThrow { throw e }
    return stubbedHasSaves
}

func diffRotaDetailed(rotaId: Int64) async throws -> [FfiChangeDetail] {
    callLog.append("diffRotaDetailed:\(rotaId)")
    if let e = errorToThrow { throw e }
    return stubbedDetailedDiffResult
}

func diffSavesDetailed(oldSaveId: Int64, newSaveId: Int64) async throws -> [FfiChangeDetail] {
    callLog.append("diffSavesDetailed:\(oldSaveId):\(newSaveId)")
    if let e = errorToThrow { throw e }
    return stubbedDetailedDiffResult
}

func diffSaveVsPrevious(saveId: Int64) async throws -> [FfiChangeDetail] {
    callLog.append("diffSaveVsPrevious:\(saveId)")
    if let e = errorToThrow { throw e }
    return stubbedDetailedDiffResult
}

func restoreToSave(saveId: Int64) async throws -> FfiRestoreResult {
    callLog.append("restoreToSave:\(saveId)")
    if let e = errorToThrow { throw e }
    return stubbedRestoreResult
}

func updateSaveLabel(saveId: Int64, label: String?) async throws {
    callLog.append("updateSaveLabel:\(saveId):\(label ?? "nil")")
    if let e = errorToThrow { throw e }
}
```

Remove old commit stubs: `stubbedCommits`, `stubbedCommitDetail`, `stubbedRotaIsCommitted`, `commitShifts`, `listCommits`, `getCommitDetail`, `rotaIsCommitted`, `diffCommitsDetailed`, `diffCommitVsPrevious`, `restoreToCommit`.

- [ ] **Step 4: Commit**

```bash
git add platforms/apple/Apps/AutorotaApp/Services/AutorotaServiceProtocol.swift \
  platforms/apple/Apps/AutorotaApp/Services/LiveAutorotaService.swift \
  platforms/apple/Apps/AutorotaApp/AutorotaAppTests/MockAutorotaService.swift
git commit -m "refactor(swift): rename service protocol commit→save"
```

---

### Task 7: Swift — RotaViewModel auto-save + remove commit UI

**Files:**
- Modify: `platforms/apple/Apps/AutorotaApp/ViewModels/RotaViewModel.swift`
- Modify: `platforms/apple/Apps/AutorotaApp/Views/RotaView.swift`

- [ ] **Step 1: Update RotaViewModel — remove commit state, add dirty flag**

In `RotaViewModel.swift`:

Remove these properties:
- `isSelectingForCommit` (line 39)
- `selectedShiftIds` (line 40)
- `changedShiftIds` (line 43)
- `hasNewChanges` computed property (line 46)
- `isCommitted` computed property (lines 365-367)

Remove these methods:
- `refreshChangedShifts()` (lines 82-92)
- `selectDay(_:)` (lines 385-390)
- `selectAllPastShifts()` (lines 392-397)
- `clearSelection()` (lines 399-401)
- `commitSelected()` (lines 403-413)
- `enterSelectMode()` (lines 415-418)
- `exitSelectMode()` (lines 420-423)

Add new property:

```swift
/// Tracks whether any mutations have occurred since the last save.
var isDirty = false
```

Update `exitEditMode()`:

```swift
func exitEditMode() {
    isEditMode = false
    pastUnlocked = false
    if isDirty {
        Task { await autoSave() }
    }
}
```

Update `resetModes()` — remove `isSelectingForCommit`:

```swift
func resetModes() {
    isEditMode = false
    pastUnlocked = false
    showGenerateConfirmation = false
    showDeleteScheduleConfirmation = false
    cancelSwap()
}
```

Add auto-save method:

```swift
/// Save the current rota state if changes exist.
private func autoSave() async {
    guard isDirty, let rotaId = schedule?.rotaId else { return }
    do {
        _ = try await service.createSave(rotaId: rotaId)
        isDirty = false
    } catch {
        // Non-fatal: save failed but user can continue editing
    }
}
```

Remove `refreshChangedShifts()` call from `loadSchedule()` (line 78).

Also update `loadSchedule()` to remove reference to `schedule.committed`.

- [ ] **Step 2: Add dirty flag to mutation methods**

Find every method in RotaViewModel that mutates rota data and add `isDirty = true` after the service call succeeds. These include methods that call:
- `service.createAssignment`
- `service.deleteAssignment`
- `service.updateAssignmentStatus`
- `service.swapAssignments`
- `service.moveAssignment`
- `service.deleteShift`
- `service.updateShiftTimes`
- `service.createAdHocShift`
- `service.runSchedule`
- `service.materialiseWeek`

For each, add `isDirty = true` after the successful service call, before `loadSchedule()`.

- [ ] **Step 3: Add week-navigation auto-save**

In `RotaView.swift`, update the `onChange(of: vm.selectedWeekStart)` handler (line 31):

```swift
.onChange(of: vm.selectedWeekStart) { oldValue, _ in
    if vm.isDirty, let rotaId = vm.schedule?.rotaId {
        Task {
            _ = try? await vm.service.createSave(rotaId: rotaId)
            vm.isDirty = false
        }
    }
    vm.resetModes()
    Task { await vm.loadSchedule() }
}
```

Note: `autoSave()` is private on the VM, so for the view's onChange we call the service directly. Alternatively, make `autoSave()` internal (remove `private`). Better approach — make it internal:

In RotaViewModel, change `private func autoSave()` to `func autoSave()`.

Then in RotaView:

```swift
.onChange(of: vm.selectedWeekStart) { _, _ in
    Task { await vm.autoSave() }
    vm.resetModes()
    Task { await vm.loadSchedule() }
}
```

- [ ] **Step 4: Remove commit UI from RotaView**

In `RotaView.swift`:

Remove the commit button from overflow menu (lines 176-183):

```swift
// DELETE this block:
if vm.weekHasPastDays {
    actions.append(RotaOverflowAction(
        title: "Commit",
        systemImage: "tray.and.arrow.down"
    ) {
        vm.enterSelectMode()
    })
}
```

Remove the selection mode bottom bar (lines 315-335):

```swift
// DELETE this block:
if vm.isSelectingForCommit {
    HStack(spacing: 12) { ... }
}
```

Remove the "Select Day" button in day headers (lines 439-448):

```swift
// DELETE this block:
if vm.isSelectingForCommit && vm.isDayPast(day) {
    Button { ... } label: { Text("Select Day") ... }
}
```

Remove the "Committed" / "New changes" badge from WeekPickerView (lines 227-237):

```swift
// DELETE this block:
if isCommitted {
    let label = hasNewChanges ? "New changes" : "Committed"
    ...
}
```

Update `WeekPickerView` to remove `isCommitted` and `hasNewChanges` parameters. Update the call site (line 28):

```swift
// Old:
WeekPickerView(selectedWeek: $vm.selectedWeekStart, category: vm.weekCategory, isCommitted: vm.isCommitted, hasNewChanges: vm.hasNewChanges)
// New:
WeekPickerView(selectedWeek: $vm.selectedWeekStart, category: vm.weekCategory)
```

Remove `isSelectingForCommit` from the checkmark/ellipsis icon logic (line 67):

```swift
// Old:
Image(systemName: (vm.isSelectingForCommit || vm.isEditMode) ? "checkmark" : "ellipsis")
// New:
Image(systemName: vm.isEditMode ? "checkmark" : "ellipsis")
```

Remove `isSelectingForCommit` from the exit-select-mode tap handler (around line 57-62):

```swift
// Old:
} else if vm.isSelectingForCommit {
    vm.exitSelectMode()
} else if vm.isEditMode {
// New:
} else if vm.isEditMode {
```

Update any remaining `isSelectingForCommit` references (shift card selection logic, etc.) — remove them.

- [ ] **Step 5: Update FfiWeekSchedule references**

The `committed` field on `FfiWeekSchedule` was renamed to `has_saves`. Update Swift references:

In RotaViewModel (if `schedule?.committed` was referenced), it's now `schedule?.hasSaves`. But since we removed `isCommitted` computed property and `refreshChangedShifts`, there should be no remaining references.

In RotaViewModelTests (line 31): `committed: false` → `hasSaves: false`.

- [ ] **Step 6: Run Swift build check**

Run: `make swift-build-check-macos 2>&1 | tail -20`

Expected: Compilation errors in CommitHistoryView/ViewModel (Task 8 fixes those). RotaView and RotaViewModel should compile.

- [ ] **Step 7: Commit**

```bash
git add platforms/apple/Apps/AutorotaApp/ViewModels/RotaViewModel.swift \
  platforms/apple/Apps/AutorotaApp/Views/RotaView.swift \
  platforms/apple/Apps/AutorotaApp/AutorotaAppTests/RotaViewModelTests.swift
git commit -m "feat(swift): add auto-save on edit mode exit, remove commit UI"
```

---

### Task 8: Swift — Rename and rewrite ActivityLogViewModel

**Files:**
- Rename: `platforms/apple/Apps/AutorotaApp/ViewModels/CommitHistoryViewModel.swift` → `platforms/apple/Apps/AutorotaApp/ViewModels/ActivityLogViewModel.swift`

- [ ] **Step 1: Create ActivityLogViewModel**

Replace entire file content. Remove `HistoryMode` enum, snapshot decoding models (`SnapshotData`, `ShiftData`, `AssignmentData`), `FlatAssignmentEntry`, and all snapshot-related logic. Keep `RestoreToast`.

```swift
import Foundation
import Observation
import AutorotaKit

// MARK: - Restore toast

/// Ephemeral message shown after a successful restore.
struct RestoreToast: Equatable {
    let saveSummary: String
    let weekStart: String
    let shiftsRestored: Int
    let assignmentsRestored: Int
    let assignmentsSkipped: Int
}

@Observable
final class ActivityLogViewModel {
    var saves: [FfiSave] = []
    var isLoading = false
    var error: String?

    /// Changes for each save, keyed by save ID. Loaded on demand when expanded.
    var changesBySaveId: [Int64: [FfiChangeDetail]] = [:]

    /// Which save entry is currently expanded (nil = all collapsed).
    var expandedSaveId: Int64?

    /// Toast shown after a successful restore. Non-nil = visible.
    var restoreToast: RestoreToast?

    /// Whether a restore is currently in flight.
    var isRestoring = false

    let service: AutorotaServiceProtocol

    init(service: AutorotaServiceProtocol = LiveAutorotaService()) {
        self.service = service
    }

    /// Load all saves across all weeks, sorted by saved_at descending.
    func loadSaves() async {
        isLoading = true
        error = nil
        do {
            saves = try await service.listSaves(rotaId: nil)
        } catch {
            self.error = userFacingMessage(error)
        }
        isLoading = false
    }

    /// Toggle expansion of a save entry. Loads changes on first expand.
    func toggleExpanded(saveId: Int64) async {
        if expandedSaveId == saveId {
            expandedSaveId = nil
        } else {
            expandedSaveId = saveId
            await loadChangesForSave(id: saveId)
        }
    }

    /// Load detailed changes between this save and the previous save.
    func loadChangesForSave(id: Int64) async {
        guard changesBySaveId[id] == nil else { return }
        do {
            let changes = try await service.diffSaveVsPrevious(saveId: id)
            changesBySaveId[id] = changes
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    /// Update the label on a save.
    func updateLabel(saveId: Int64, label: String?) async {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            try await service.updateSaveLabel(saveId: saveId, label: finalLabel)
            // Update local cache
            if let idx = saves.firstIndex(where: { $0.id == saveId }) {
                saves[idx] = FfiSave(
                    id: saves[idx].id,
                    rotaId: saves[idx].rotaId,
                    savedAt: saves[idx].savedAt,
                    summary: saves[idx].summary,
                    weekStart: saves[idx].weekStart,
                    label: finalLabel
                )
            }
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    /// Restore the rota to the state captured by a save.
    func restoreToSave(id: Int64, summary: String, weekStart: String) async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            let result = try await service.restoreToSave(saveId: id)
            restoreToast = RestoreToast(
                saveSummary: summary,
                weekStart: weekStart,
                shiftsRestored: Int(result.shiftsRestored),
                assignmentsRestored: Int(result.assignmentsRestored),
                assignmentsSkipped: Int(result.assignmentsSkipped)
            )
        } catch {
            self.error = userFacingMessage(error)
        }
    }

    /// Saves grouped by week_start for display.
    var savesByWeek: [(weekStart: String, saves: [FfiSave])] {
        let grouped = Dictionary(grouping: saves, by: \.weekStart)
        return grouped
            .sorted { $0.key > $1.key }
            .map { (weekStart: $0.key, saves: $0.value) }
    }
}
```

- [ ] **Step 2: Update Xcode project references**

In `project.pbxproj`, update file references from `CommitHistoryViewModel.swift` to `ActivityLogViewModel.swift`. The file path entries need updating (search for `CommitHistoryViewModel` in the pbxproj and replace with `ActivityLogViewModel`).

- [ ] **Step 3: Commit**

```bash
git rm platforms/apple/Apps/AutorotaApp/ViewModels/CommitHistoryViewModel.swift
git add platforms/apple/Apps/AutorotaApp/ViewModels/ActivityLogViewModel.swift \
  platforms/apple/Apps/AutorotaApp/AutorotaApp.xcodeproj/project.pbxproj
git commit -m "refactor(swift): replace CommitHistoryViewModel with ActivityLogViewModel"
```

---

### Task 9: Swift — Rewrite ActivityLogView

**Files:**
- Rename: `platforms/apple/Apps/AutorotaApp/Views/CommitHistoryView.swift` → `platforms/apple/Apps/AutorotaApp/Views/ActivityLogView.swift`
- Modify: `platforms/apple/Apps/AutorotaApp/Views/TabPage.swift:48`

- [ ] **Step 1: Create ActivityLogView**

Replace entire file. Key layout:
- Grouped by week, most recent first
- Each save entry: timestamp + label + summary (collapsed)
- Tap to expand: ChangeSummaryCard, ChangeRows grouped by date, label input, restore button
- RestoreToastBanner overlay

Reuse existing `ChangeSummaryCard`, `ChangeRow`, `DayChangesGroup` components from the old `CommitHistoryView` — copy them into the new file (they're view-local types).

```swift
import SwiftUI
import AutorotaKit

struct ActivityLogView: View {
    @State private var vm = ActivityLogViewModel()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Group {
                    if vm.isLoading && vm.saves.isEmpty {
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.saves.isEmpty {
                        ContentUnavailableView(
                            "No activity yet",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Saves will appear here as you edit schedules.")
                        )
                    } else {
                        savesList
                    }
                }

                if let toast = vm.restoreToast {
                    RestoreToastBanner(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            Task {
                                try? await Task.sleep(for: .seconds(4))
                                withAnimation { vm.restoreToast = nil }
                            }
                        }
                }
            }
            .navigationTitle("Activity Log")
            .task { await vm.loadSaves() }
        }
    }

    private var savesList: some View {
        List {
            ForEach(vm.savesByWeek, id: \.weekStart) { weekGroup in
                Section("Week of \(weekGroup.weekStart)") {
                    ForEach(weekGroup.saves, id: \.id) { save in
                        SaveEntryView(save: save, vm: vm)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.loadSaves() }
    }
}

// MARK: - Save Entry (collapsed + expandable)

struct SaveEntryView: View {
    let save: FfiSave
    let vm: ActivityLogViewModel
    @State private var labelText: String = ""
    @State private var showRestoreConfirmation = false

    private var isExpanded: Bool { vm.expandedSaveId == save.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Collapsed header — always visible
            Button {
                Task { await vm.toggleExpanded(saveId: save.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(formattedDate(save.savedAt))
                                .font(.subheadline.bold())
                            if let label = save.label {
                                Text(label)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundStyle(.accent)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(save.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                Divider()

                if let changes = vm.changesBySaveId[save.id] {
                    if changes.isEmpty {
                        Text("No changes from previous save")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ChangeSummaryCard(changes: changes)
                        DayChangesGroup(changes: changes)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }

                // Label input
                HStack {
                    TextField("Add label…", text: $labelText)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                    if !labelText.isEmpty || save.label != nil {
                        Button("Save") {
                            Task { await vm.updateLabel(saveId: save.id, label: labelText) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .onAppear { labelText = save.label ?? "" }

                // Restore button
                Button(role: .destructive) {
                    showRestoreConfirmation = true
                } label: {
                    Label("Restore to this point", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isRestoring)
                .confirmationDialog(
                    "Restore schedule?",
                    isPresented: $showRestoreConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Restore", role: .destructive) {
                        Task {
                            await vm.restoreToSave(
                                id: save.id,
                                summary: save.summary,
                                weekStart: save.weekStart
                            )
                            await vm.loadSaves()
                        }
                    }
                } message: {
                    Text("This will overwrite the current schedule for week of \(save.weekStart) with the state from this save. This cannot be undone.")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Change Summary Card

struct ChangeSummaryCard: View {
    let changes: [FfiChangeDetail]

    var body: some View {
        let counts = changeCounts(changes)
        HStack(spacing: 12) {
            ForEach(counts, id: \.label) { item in
                HStack(spacing: 4) {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color)
                    Text("\(item.count)")
                        .font(.caption.bold())
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private struct CountItem {
        let label: String
        let count: Int
        let icon: String
        let color: Color
    }

    private func changeCounts(_ changes: [FfiChangeDetail]) -> [CountItem] {
        var added = 0, removed = 0, modified = 0, moved = 0
        for c in changes {
            switch c.kind {
            case "shift_added", "assignment_added": added += 1
            case "shift_removed", "assignment_removed": removed += 1
            case "employee_moved": moved += 1
            default: modified += 1
            }
        }
        var items: [CountItem] = []
        if added > 0 { items.append(CountItem(label: "added", count: added, icon: "plus.circle.fill", color: .green)) }
        if removed > 0 { items.append(CountItem(label: "removed", count: removed, icon: "minus.circle.fill", color: .red)) }
        if modified > 0 { items.append(CountItem(label: "changed", count: modified, icon: "pencil.circle.fill", color: .orange)) }
        if moved > 0 { items.append(CountItem(label: "moved", count: moved, icon: "arrow.right.circle.fill", color: .purple)) }
        return items
    }
}

// MARK: - Day Changes Group

struct DayChangesGroup: View {
    let changes: [FfiChangeDetail]

    var body: some View {
        let grouped = Dictionary(grouping: changes, by: \.date)
        let sorted = grouped.sorted { $0.key < $1.key }
        ForEach(sorted, id: \.key) { date, dayChanges in
            VStack(alignment: .leading, spacing: 4) {
                Text(date)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(Array(dayChanges.enumerated()), id: \.offset) { _, change in
                    ChangeRow(change: change)
                }
            }
        }
    }
}

// MARK: - Change Row

struct ChangeRow: View {
    let change: FfiChangeDetail

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(summary)
                .font(.caption)
        }
        .padding(.vertical, 1)
    }

    private var category: ChangeCategory {
        switch change.kind {
        case "shift_added": return .added
        case "shift_removed": return .removed
        case "assignment_added": return .added
        case "assignment_removed": return .removed
        case "employee_moved": return .moved
        default: return .modified
        }
    }

    private enum ChangeCategory {
        case added, removed, modified, moved
    }

    private var color: Color {
        switch category {
        case .added: return .green
        case .removed: return .red
        case .modified: return .orange
        case .moved: return .purple
        }
    }

    private var icon: String {
        switch category {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .moved: return "arrow.right.circle.fill"
        }
    }

    private var summary: String {
        switch change.kind {
        case "shift_added":
            return "New shift \(change.newStartTime ?? "") – \(change.newEndTime ?? "") (\(change.newRequiredRole ?? "any"))"
        case "shift_removed":
            return "Removed shift \(change.oldStartTime ?? "") – \(change.oldEndTime ?? "")"
        case "shift_time_changed":
            return "Time changed \(change.oldStartTime ?? "") – \(change.oldEndTime ?? "") → \(change.newStartTime ?? "") – \(change.newEndTime ?? "")"
        case "shift_capacity_changed":
            return "Capacity changed \(change.oldMinEmployees.map(String.init) ?? "?")–\(change.oldMaxEmployees.map(String.init) ?? "?") → \(change.newMinEmployees.map(String.init) ?? "?")–\(change.newMaxEmployees.map(String.init) ?? "?")"
        case "shift_role_changed":
            return "Role changed \(change.oldRequiredRole ?? "?") → \(change.newRequiredRole ?? "?")"
        case "assignment_added":
            return "\(change.employeeName ?? "Unknown") joined"
        case "assignment_removed":
            return "\(change.employeeName ?? "Unknown") removed"
        case "assignment_status_changed":
            return "\(change.employeeName ?? "Unknown") status: \(change.oldStatus ?? "?") → \(change.newStatus ?? "?")"
        case "employee_moved":
            return "\(change.employeeName ?? "Unknown") moved from \(change.fromStartTime ?? "") – \(change.fromEndTime ?? "")"
        default:
            return change.kind
        }
    }
}

// MARK: - Restore Toast Banner

struct RestoreToastBanner: View {
    let toast: RestoreToast

    var body: some View {
        VStack(spacing: 4) {
            Label("Restored to: \(toast.saveSummary)", systemImage: "checkmark.circle.fill")
                .font(.subheadline.bold())
            Text("Week of \(toast.weekStart) — \(toast.shiftsRestored) shifts, \(toast.assignmentsRestored) assignments")
                .font(.caption)
            if toast.assignmentsSkipped > 0 {
                Text("\(toast.assignmentsSkipped) assignment(s) skipped (employees deleted)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
```

- [ ] **Step 2: Update TabPage.swift**

In `platforms/apple/Apps/AutorotaApp/Views/TabPage.swift`, line 48:

```swift
// Old:
case .history: CommitHistoryView()
// New:
case .history: ActivityLogView()
```

Optionally rename the tab title from "History" to "Activity Log" (line 21):

```swift
case .history: "Activity"
```

- [ ] **Step 3: Update Xcode project references**

In `project.pbxproj`, rename `CommitHistoryView.swift` references to `ActivityLogView.swift`.

- [ ] **Step 4: Commit**

```bash
git rm platforms/apple/Apps/AutorotaApp/Views/CommitHistoryView.swift
git add platforms/apple/Apps/AutorotaApp/Views/ActivityLogView.swift \
  platforms/apple/Apps/AutorotaApp/Views/TabPage.swift \
  platforms/apple/Apps/AutorotaApp/AutorotaApp.xcodeproj/project.pbxproj
git commit -m "feat(swift): replace CommitHistoryView with ActivityLogView"
```

---

### Task 10: Swift — Rename and rewrite ViewModel tests

**Files:**
- Rename: `platforms/apple/Apps/AutorotaApp/AutorotaAppTests/CommitHistoryViewModelTests.swift` → `platforms/apple/Apps/AutorotaApp/AutorotaAppTests/ActivityLogViewModelTests.swift`
- Modify: `platforms/apple/Apps/AutorotaApp/AutorotaApp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write ActivityLogViewModelTests**

```swift
import Foundation
import Testing
import AutorotaKit
@testable import AutorotaApp

@Suite("ActivityLogViewModel")
struct ActivityLogViewModelTests {

    private func makeMock() -> MockAutorotaService {
        MockAutorotaService()
    }

    private func makeSave(id: Int64 = 1, rotaId: Int64 = 1, weekStart: String = "2026-03-30", label: String? = nil) -> FfiSave {
        FfiSave(
            id: id,
            rotaId: rotaId,
            savedAt: "2026-03-30T12:00:00Z",
            summary: "2 shifts, 1 employee, 8h",
            weekStart: weekStart,
            label: label
        )
    }

    // MARK: - Loading

    @Test("loadSaves surfaces clean error message from FfiError")
    func loadSavesSurfacesCleanFfiError() async {
        let mock = makeMock()
        mock.errorToThrow = FfiError.Db(msg: "A referenced record no longer exists.")
        let vm = ActivityLogViewModel(service: mock)

        await vm.loadSaves()

        #expect(vm.error == "A referenced record no longer exists.")
    }

    @Test("loadSaves surfaces clean error for non-FfiError")
    func loadSavesSurfacesGenericError() async {
        let mock = makeMock()
        mock.errorToThrow = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something went wrong"])
        let vm = ActivityLogViewModel(service: mock)

        await vm.loadSaves()

        #expect(vm.error == "Something went wrong")
    }

    @Test("loadSaves with empty result shows no error")
    func loadSavesEmptyNoError() async {
        let mock = makeMock()
        let vm = ActivityLogViewModel(service: mock)

        await vm.loadSaves()

        #expect(vm.error == nil)
        #expect(vm.saves.isEmpty)
    }

    // MARK: - Grouping

    @Test("savesByWeek groups and sorts by week descending")
    func savesByWeekGroupsCorrectly() async {
        let mock = makeMock()
        mock.stubbedSaves = [
            makeSave(id: 1, weekStart: "2026-03-30"),
            makeSave(id: 2, weekStart: "2026-04-06"),
            makeSave(id: 3, weekStart: "2026-03-30"),
        ]
        let vm = ActivityLogViewModel(service: mock)
        await vm.loadSaves()

        let weeks = vm.savesByWeek
        #expect(weeks.count == 2)
        #expect(weeks[0].weekStart == "2026-04-06")
        #expect(weeks[1].weekStart == "2026-03-30")
        #expect(weeks[1].saves.count == 2)
    }

    // MARK: - Expand/Collapse

    @Test("toggleExpanded expands and collapses")
    func toggleExpandedWorks() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave()]
        mock.stubbedDetailedDiffResult = []
        let vm = ActivityLogViewModel(service: mock)
        await vm.loadSaves()

        await vm.toggleExpanded(saveId: 1)
        #expect(vm.expandedSaveId == 1)

        await vm.toggleExpanded(saveId: 1)
        #expect(vm.expandedSaveId == nil)
    }

    // MARK: - Label

    @Test("updateLabel trims whitespace and updates local cache")
    func updateLabelTrimsAndUpdates() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave()]
        let vm = ActivityLogViewModel(service: mock)
        await vm.loadSaves()

        await vm.updateLabel(saveId: 1, label: "  Final schedule  ")

        #expect(vm.saves[0].label == "Final schedule")
        #expect(mock.callLog.contains("updateSaveLabel:1:Final schedule"))
    }

    @Test("updateLabel with empty string clears label")
    func updateLabelEmptyClearsLabel() async {
        let mock = makeMock()
        mock.stubbedSaves = [makeSave(label: "Old label")]
        let vm = ActivityLogViewModel(service: mock)
        await vm.loadSaves()

        await vm.updateLabel(saveId: 1, label: "")

        #expect(vm.saves[0].label == nil)
        #expect(mock.callLog.contains("updateSaveLabel:1:nil"))
    }

    // MARK: - Restore

    @Test("restoreToSave sets toast on success")
    func restoreToSaveSetsToast() async {
        let mock = makeMock()
        mock.stubbedRestoreResult = FfiRestoreResult(
            rotaId: 1, shiftsRestored: 5, assignmentsRestored: 3, assignmentsSkipped: 1
        )
        let vm = ActivityLogViewModel(service: mock)

        await vm.restoreToSave(id: 1, summary: "test save", weekStart: "2026-03-30")

        #expect(vm.restoreToast != nil)
        #expect(vm.restoreToast?.shiftsRestored == 5)
        #expect(vm.restoreToast?.assignmentsSkipped == 1)
    }

    @Test("restoreToSave surfaces error")
    func restoreToSaveSurfacesError() async {
        let mock = makeMock()
        mock.errorToThrow = FfiError.NotFound(msg: "Save not found")
        let vm = ActivityLogViewModel(service: mock)

        await vm.restoreToSave(id: 999, summary: "x", weekStart: "2026-03-30")

        #expect(vm.error == "Save not found")
        #expect(vm.restoreToast == nil)
    }
}
```

- [ ] **Step 2: Update Xcode project references**

In `project.pbxproj`, rename `CommitHistoryViewModelTests.swift` references to `ActivityLogViewModelTests.swift`.

- [ ] **Step 3: Run Swift tests**

Run: `make swift-test-app-macos 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git rm platforms/apple/Apps/AutorotaApp/AutorotaAppTests/CommitHistoryViewModelTests.swift
git add platforms/apple/Apps/AutorotaApp/AutorotaAppTests/ActivityLogViewModelTests.swift \
  platforms/apple/Apps/AutorotaApp/AutorotaApp.xcodeproj/project.pbxproj
git commit -m "test(swift): rewrite ViewModel tests for ActivityLog"
```

---

### Task 11: Update remaining references and final verification

**Files:**
- Modify: Any remaining files referencing "commit" in user-facing strings
- Modify: `crates/app-desktop/src-tauri/src/lib.rs` (if it references commit FFI functions)

- [ ] **Step 1: Grep for remaining "commit" references**

Run:

```bash
grep -ri "commit" --include="*.swift" platforms/apple/Apps/AutorotaApp/ | grep -v ".pbxproj" | grep -v "git commit"
grep -ri "commit" --include="*.rs" crates/ | grep -v target | grep -v "git commit"
```

Fix any remaining references.

- [ ] **Step 2: Check Tauri desktop crate**

Look for commit-related FFI calls in `crates/app-desktop/src-tauri/src/lib.rs` and rename if present.

- [ ] **Step 3: Run full test suite**

```bash
cargo fmt && cargo clippy && cargo test
make swift-build-check
make swift-test-app-macos
```

Expected: All Rust tests pass. All Swift platforms compile. All Swift ViewModel tests pass.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: clean up remaining commit→save references"
```
