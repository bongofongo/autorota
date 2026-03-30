# iCloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync all domain data across a user's Apple devices via CKSyncEngine and CloudKit private database.

**Architecture:** Add change-tracking columns and sync tables to SQLite (Rust migration). Expose sync query/update functions via FFI. Build a Swift `AutorotaSyncEngine` conforming to `CKSyncEngineDelegate` that maps SQLite rows to CKRecords, handles per-field conflict resolution via base snapshots, and integrates into the app launch flow with a first-device prompt.

**Tech Stack:** Rust (SQLite/sqlx migrations, queries, UniFFI), Swift (CKSyncEngine, CloudKit, SwiftUI)

**Spec:** `docs/superpowers/specs/2026-03-30-icloud-sync-design.md`

---

## File Structure

### Rust — New/Modified Files

| File | Responsibility |
|------|---------------|
| `crates/autorota-core/migrations/011_sync_support.sql` | Add `last_modified`, `sync_status`, `sync_base_snapshot` to all 8 tables; create `sync_metadata` and `sync_tombstones` tables |
| `crates/autorota-core/src/db/mod.rs` | Add migration 011 conditional check + execution |
| `crates/autorota-core/src/db/queries.rs` | Add sync query functions: pending records, mark synced, apply remote, tombstones, metadata |
| `crates/autorota-core/src/models/sync.rs` | `SyncRecord`, `MergeConflict`, `BaseSnapshot`, `Tombstone`, `SyncMetadata` structs |
| `crates/autorota-core/src/models/mod.rs` | Add `pub mod sync;` |
| `crates/autorota-ffi/src/types.rs` | Add `FfiSyncRecord`, `FfiMergeConflict`, `FfiBaseSnapshot`, `FfiTombstone` |
| `crates/autorota-ffi/src/lib.rs` | Add sync FFI exports: `get_pending_sync_records`, `mark_records_synced`, `apply_remote_records`, `get_sync_metadata`, `set_sync_metadata`, `get_base_snapshots`, `get_pending_tombstones`, `clear_tombstones` |

### Swift — New/Modified Files

| File | Responsibility |
|------|---------------|
| `platforms/apple/AutorotaKit/Sources/AutorotaKit/AutorotaKit.swift` | Add async wrappers for new sync FFI functions |
| `platforms/apple/Apps/AutorotaApp/Services/AutorotaSyncEngine.swift` | `CKSyncEngineDelegate` implementation, record mapping, push/pull orchestration |
| `platforms/apple/Apps/AutorotaApp/Services/SyncRecordMapper.swift` | Convert between `FfiSyncRecord` JSON fields and `CKRecord` fields, per-table field definitions |
| `platforms/apple/Apps/AutorotaApp/Services/SyncConflictResolver.swift` | Three-way merge logic: base vs local vs server per-field resolution |
| `platforms/apple/Apps/AutorotaApp/AutorotaApp/AutorotaAppApp.swift` | Add sync engine initialization, first-launch cloud data prompt |
| `platforms/apple/Apps/AutorotaApp/Views/SettingsView.swift` | Add sync status indicator section |
| `platforms/apple/Apps/AutorotaApp/Views/SyncPromptView.swift` | First-launch iCloud data prompt sheet |

### Xcode Project Config

| File | Change |
|------|--------|
| `platforms/apple/Apps/AutorotaApp/AutorotaApp/AutorotaApp.entitlements` | Add CloudKit container `iCloud.com.toadmountain.autorota`, background modes |

---

## Task 1: SQL Migration — Sync Columns and Tables

**Files:**
- Create: `crates/autorota-core/migrations/011_sync_support.sql`
- Modify: `crates/autorota-core/src/db/mod.rs`

- [ ] **Step 1: Write the migration SQL**

Create `crates/autorota-core/migrations/011_sync_support.sql`:

```sql
-- Add sync tracking columns to all 8 domain tables.
-- last_modified: ISO 8601 timestamp, updated on every write.
-- sync_status: 0 = pending sync, 1 = synced.
-- sync_base_snapshot: JSON blob of field values at last successful sync.

ALTER TABLE employees ADD COLUMN last_modified TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z';
ALTER TABLE employees ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;
ALTER TABLE employees ADD COLUMN sync_base_snapshot TEXT DEFAULT NULL;

ALTER TABLE shift_templates ADD COLUMN last_modified TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z';
ALTER TABLE shift_templates ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;
ALTER TABLE shift_templates ADD COLUMN sync_base_snapshot TEXT DEFAULT NULL;

ALTER TABLE rotas ADD COLUMN last_modified TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z';
ALTER TABLE rotas ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;
ALTER TABLE rotas ADD COLUMN sync_base_snapshot TEXT DEFAULT NULL;

ALTER TABLE shifts ADD COLUMN last_modified TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z';
ALTER TABLE shifts ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;
ALTER TABLE shifts ADD COLUMN sync_base_snapshot TEXT DEFAULT NULL;

ALTER TABLE assignments ADD COLUMN last_modified TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z';
ALTER TABLE assignments ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;
ALTER TABLE assignments ADD COLUMN sync_base_snapshot TEXT DEFAULT NULL;

ALTER TABLE roles ADD COLUMN last_modified TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z';
ALTER TABLE roles ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;
ALTER TABLE roles ADD COLUMN sync_base_snapshot TEXT DEFAULT NULL;

ALTER TABLE employee_availability_overrides ADD COLUMN last_modified TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z';
ALTER TABLE employee_availability_overrides ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;
ALTER TABLE employee_availability_overrides ADD COLUMN sync_base_snapshot TEXT DEFAULT NULL;

ALTER TABLE shift_template_overrides ADD COLUMN last_modified TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z';
ALTER TABLE shift_template_overrides ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;
ALTER TABLE shift_template_overrides ADD COLUMN sync_base_snapshot TEXT DEFAULT NULL;

-- Sync metadata: stores CKSyncEngine state (change tokens, device ID, etc.)
CREATE TABLE IF NOT EXISTS sync_metadata (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);

-- Tombstones for hard-deleted rows that need to be synced before cleanup.
CREATE TABLE IF NOT EXISTS sync_tombstones (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    table_name TEXT NOT NULL,
    record_id INTEGER NOT NULL,
    deleted_at TEXT NOT NULL
);
```

- [ ] **Step 2: Add migration 011 to the migration runner**

In `crates/autorota-core/src/db/mod.rs`, after the migration 010 block (after line ~161), add:

```rust
    // Migration 011: add sync tracking columns and tables.
    let has_sync_status: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('employees') WHERE name = 'sync_status'",
    )
    .fetch_one(pool)
    .await?;

    if !has_sync_status {
        let m11 = include_str!("../../migrations/011_sync_support.sql");
        sqlx::raw_sql(m11).execute(pool).await?;
    }
```

- [ ] **Step 3: Run Rust tests to verify migration applies cleanly**

Run: `cargo test -p autorota-core`

Expected: All existing tests pass. The migration adds columns with defaults so existing queries are unaffected.

- [ ] **Step 4: Commit**

```bash
git add crates/autorota-core/migrations/011_sync_support.sql crates/autorota-core/src/db/mod.rs
git commit -m "feat: add migration 011 — sync tracking columns and tables"
```

---

## Task 2: Rust Sync Models

**Files:**
- Create: `crates/autorota-core/src/models/sync.rs`
- Modify: `crates/autorota-core/src/models/mod.rs`

- [ ] **Step 1: Create the sync model structs**

Create `crates/autorota-core/src/models/sync.rs`:

```rust
use serde::{Deserialize, Serialize};

/// A row from any syncable table, serialized generically for the sync layer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncRecord {
    pub table_name: String,
    pub record_id: i64,
    /// JSON object of all syncable field values (excludes sync_status, sync_base_snapshot).
    pub fields: String,
    pub last_modified: String,
}

/// Result of a merge when both local and remote changed the same row.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MergeConflict {
    pub record_id: i64,
    /// JSON object of the resolved field values after per-field merge.
    pub resolved_fields: String,
}

/// The base snapshot for a synced row, used for three-way merge.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BaseSnapshot {
    pub record_id: i64,
    /// JSON object of field values at last successful sync.
    pub snapshot: String,
}

/// A tombstone for a hard-deleted row awaiting sync.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tombstone {
    pub id: i64,
    pub table_name: String,
    pub record_id: i64,
    pub deleted_at: String,
}
```

- [ ] **Step 2: Add module declaration**

In `crates/autorota-core/src/models/mod.rs`, add:

```rust
pub mod sync;
```

And add to the pub use block (if one exists) or ensure `sync` types are accessible:

```rust
pub use sync::{SyncRecord, MergeConflict, BaseSnapshot, Tombstone};
```

- [ ] **Step 3: Verify compilation**

Run: `cargo check -p autorota-core`

Expected: Compiles cleanly.

- [ ] **Step 4: Commit**

```bash
git add crates/autorota-core/src/models/sync.rs crates/autorota-core/src/models/mod.rs
git commit -m "feat: add sync model structs (SyncRecord, MergeConflict, BaseSnapshot, Tombstone)"
```

---

## Task 3: Rust Sync Queries

**Files:**
- Modify: `crates/autorota-core/src/db/queries.rs`

This task adds all the database query functions needed by the sync layer. All functions follow the existing pattern: `async fn(pool: &SqlitePool, ...) -> Result<T, sqlx::Error>`.

- [ ] **Step 1: Write test for sync metadata get/set**

Add to `crates/autorota-core/tests/db_integration.rs` (or the appropriate test file):

```rust
#[tokio::test]
async fn test_sync_metadata_roundtrip() {
    let pool = test_pool().await;

    // Initially empty
    let val = queries::get_sync_metadata(&pool, "test_key").await.unwrap();
    assert!(val.is_none());

    // Set and get
    queries::set_sync_metadata(&pool, "test_key", "test_value").await.unwrap();
    let val = queries::get_sync_metadata(&pool, "test_key").await.unwrap();
    assert_eq!(val, Some("test_value".to_string()));

    // Overwrite
    queries::set_sync_metadata(&pool, "test_key", "updated").await.unwrap();
    let val = queries::get_sync_metadata(&pool, "test_key").await.unwrap();
    assert_eq!(val, Some("updated".to_string()));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p autorota-core test_sync_metadata_roundtrip`

Expected: FAIL — `get_sync_metadata` and `set_sync_metadata` don't exist yet.

- [ ] **Step 3: Implement sync metadata functions**

Add to `crates/autorota-core/src/db/queries.rs`:

```rust
// ── Sync metadata ──

pub async fn get_sync_metadata(
    pool: &SqlitePool,
    key: &str,
) -> Result<Option<String>, sqlx::Error> {
    sqlx::query_scalar("SELECT value FROM sync_metadata WHERE key = ?")
        .bind(key)
        .fetch_optional(pool)
        .await
}

pub async fn set_sync_metadata(
    pool: &SqlitePool,
    key: &str,
    value: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("INSERT INTO sync_metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        .bind(key)
        .bind(value)
        .execute(pool)
        .await?;
    Ok(())
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p autorota-core test_sync_metadata_roundtrip`

Expected: PASS

- [ ] **Step 5: Write test for tombstone operations**

```rust
#[tokio::test]
async fn test_tombstone_lifecycle() {
    let pool = test_pool().await;

    // Insert tombstones
    queries::insert_tombstone(&pool, "employees", 42).await.unwrap();
    queries::insert_tombstone(&pool, "roles", 7).await.unwrap();

    // List pending
    let tombstones = queries::get_pending_tombstones(&pool).await.unwrap();
    assert_eq!(tombstones.len(), 2);
    assert_eq!(tombstones[0].table_name, "employees");
    assert_eq!(tombstones[0].record_id, 42);

    // Clear specific ones
    let ids: Vec<i64> = tombstones.iter().map(|t| t.id).collect();
    queries::clear_tombstones(&pool, &ids).await.unwrap();

    let tombstones = queries::get_pending_tombstones(&pool).await.unwrap();
    assert_eq!(tombstones.len(), 0);
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `cargo test -p autorota-core test_tombstone_lifecycle`

Expected: FAIL — functions don't exist yet.

- [ ] **Step 7: Implement tombstone functions**

Add to `crates/autorota-core/src/db/queries.rs`:

```rust
use crate::models::sync::Tombstone;

pub async fn insert_tombstone(
    pool: &SqlitePool,
    table_name: &str,
    record_id: i64,
) -> Result<i64, sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    let result = sqlx::query(
        "INSERT INTO sync_tombstones (table_name, record_id, deleted_at) VALUES (?, ?, ?)",
    )
    .bind(table_name)
    .bind(record_id)
    .bind(&now)
    .execute(pool)
    .await?;
    Ok(result.last_insert_rowid())
}

pub async fn get_pending_tombstones(
    pool: &SqlitePool,
) -> Result<Vec<Tombstone>, sqlx::Error> {
    let rows: Vec<(i64, String, i64, String)> = sqlx::query_as(
        "SELECT id, table_name, record_id, deleted_at FROM sync_tombstones ORDER BY id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(id, table_name, record_id, deleted_at)| Tombstone {
            id,
            table_name,
            record_id,
            deleted_at,
        })
        .collect())
}

pub async fn clear_tombstones(
    pool: &SqlitePool,
    ids: &[i64],
) -> Result<(), sqlx::Error> {
    if ids.is_empty() {
        return Ok(());
    }
    let placeholders: String = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!("DELETE FROM sync_tombstones WHERE id IN ({})", placeholders);
    let mut query = sqlx::query(&sql);
    for id in ids {
        query = query.bind(id);
    }
    query.execute(pool).await?;
    Ok(())
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `cargo test -p autorota-core test_tombstone_lifecycle`

Expected: PASS

- [ ] **Step 9: Write test for get_pending_sync_records**

```rust
#[tokio::test]
async fn test_get_pending_sync_records_employees() {
    let pool = test_pool().await;

    // Create an employee (sync_status defaults to 0 = pending)
    let emp = helpers::sample_employee();
    let id = queries::insert_employee(&pool, &emp).await.unwrap();

    // Should appear in pending sync records
    let pending = queries::get_pending_sync_records(&pool, "employees").await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].record_id, id);
    assert_eq!(pending[0].table_name, "employees");

    // fields should be valid JSON containing first_name
    let fields: serde_json::Value = serde_json::from_str(&pending[0].fields).unwrap();
    assert_eq!(fields["first_name"], emp.first_name);
}
```

- [ ] **Step 10: Run test to verify it fails**

Run: `cargo test -p autorota-core test_get_pending_sync_records_employees`

Expected: FAIL — `get_pending_sync_records` doesn't exist.

- [ ] **Step 11: Implement get_pending_sync_records**

Add to `crates/autorota-core/src/db/queries.rs`:

```rust
use crate::models::sync::SyncRecord;

/// Returns all rows from `table_name` where sync_status = 0.
/// Fields are serialized as a JSON object (excluding sync_status, sync_base_snapshot).
pub async fn get_pending_sync_records(
    pool: &SqlitePool,
    table_name: &str,
) -> Result<Vec<SyncRecord>, sqlx::Error> {
    // Build a query that selects all columns except sync-internal ones as JSON.
    // We use SQLite's json_object() to build a generic JSON representation.
    let columns = syncable_columns(table_name);
    let json_pairs: String = columns
        .iter()
        .map(|c| format!("'{}', {}", c, c))
        .collect::<Vec<_>>()
        .join(", ");

    let sql = format!(
        "SELECT id, json_object({}) AS fields, last_modified FROM {} WHERE sync_status = 0",
        json_pairs, table_name
    );

    let rows: Vec<(i64, String, String)> = sqlx::query_as(&sql).fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .map(|(record_id, fields, last_modified)| SyncRecord {
            table_name: table_name.to_string(),
            record_id,
            fields,
            last_modified,
        })
        .collect())
}

/// Returns the list of syncable column names for each table.
/// Excludes: sync_status, sync_base_snapshot (internal sync state).
fn syncable_columns(table_name: &str) -> Vec<&'static str> {
    match table_name {
        "employees" => vec![
            "id", "first_name", "last_name", "nickname", "roles", "start_date",
            "target_weekly_hours", "weekly_hours_deviation", "max_daily_hours",
            "notes", "bank_details", "hourly_wage", "wage_currency",
            "default_availability", "availability", "deleted", "last_modified",
        ],
        "shift_templates" => vec![
            "id", "name", "weekdays", "start_time", "end_time", "required_role",
            "min_employees", "max_employees", "deleted", "last_modified",
        ],
        "rotas" => vec![
            "id", "week_start", "finalized", "last_modified",
        ],
        "shifts" => vec![
            "id", "template_id", "rota_id", "date", "start_time", "end_time",
            "required_role", "min_employees", "max_employees", "last_modified",
        ],
        "assignments" => vec![
            "id", "rota_id", "shift_id", "employee_id", "status",
            "employee_name", "hourly_wage", "last_modified",
        ],
        "roles" => vec![
            "id", "name", "last_modified",
        ],
        "employee_availability_overrides" => vec![
            "id", "employee_id", "date", "availability", "notes", "last_modified",
        ],
        "shift_template_overrides" => vec![
            "id", "template_id", "date", "cancelled", "start_time", "end_time",
            "min_employees", "max_employees", "notes", "last_modified",
        ],
        _ => vec![],
    }
}
```

- [ ] **Step 12: Run test to verify it passes**

Run: `cargo test -p autorota-core test_get_pending_sync_records_employees`

Expected: PASS

- [ ] **Step 13: Write test for mark_records_synced**

```rust
#[tokio::test]
async fn test_mark_records_synced() {
    let pool = test_pool().await;

    let emp = helpers::sample_employee();
    let id = queries::insert_employee(&pool, &emp).await.unwrap();

    // Mark as synced with a base snapshot
    let snapshot = r#"{"first_name":"Alice","last_name":"Smith"}"#.to_string();
    queries::mark_records_synced(&pool, "employees", &[id], &[snapshot.clone()]).await.unwrap();

    // Should no longer appear in pending
    let pending = queries::get_pending_sync_records(&pool, "employees").await.unwrap();
    assert_eq!(pending.len(), 0);

    // Base snapshot should be stored
    let snapshots = queries::get_base_snapshots(&pool, "employees", &[id]).await.unwrap();
    assert_eq!(snapshots.len(), 1);
    assert_eq!(snapshots[0].snapshot, snapshot);
}
```

- [ ] **Step 14: Run test to verify it fails**

Run: `cargo test -p autorota-core test_mark_records_synced`

Expected: FAIL

- [ ] **Step 15: Implement mark_records_synced and get_base_snapshots**

Add to `crates/autorota-core/src/db/queries.rs`:

```rust
use crate::models::sync::BaseSnapshot;

pub async fn mark_records_synced(
    pool: &SqlitePool,
    table_name: &str,
    record_ids: &[i64],
    base_snapshots: &[String],
) -> Result<(), sqlx::Error> {
    for (id, snapshot) in record_ids.iter().zip(base_snapshots.iter()) {
        let sql = format!(
            "UPDATE {} SET sync_status = 1, sync_base_snapshot = ? WHERE id = ?",
            table_name
        );
        sqlx::query(&sql)
            .bind(snapshot)
            .bind(id)
            .execute(pool)
            .await?;
    }
    Ok(())
}

pub async fn get_base_snapshots(
    pool: &SqlitePool,
    table_name: &str,
    record_ids: &[i64],
) -> Result<Vec<BaseSnapshot>, sqlx::Error> {
    if record_ids.is_empty() {
        return Ok(vec![]);
    }
    let placeholders: String = record_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!(
        "SELECT id, sync_base_snapshot FROM {} WHERE id IN ({}) AND sync_base_snapshot IS NOT NULL",
        table_name, placeholders
    );
    let mut query = sqlx::query_as::<_, (i64, String)>(&sql);
    for id in record_ids {
        query = query.bind(id);
    }
    let rows = query.fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .map(|(record_id, snapshot)| BaseSnapshot {
            record_id,
            snapshot,
        })
        .collect())
}
```

- [ ] **Step 16: Run test to verify it passes**

Run: `cargo test -p autorota-core test_mark_records_synced`

Expected: PASS

- [ ] **Step 17: Write test for apply_remote_record (upsert)**

```rust
#[tokio::test]
async fn test_apply_remote_record_insert() {
    let pool = test_pool().await;

    // Apply a remote role that doesn't exist locally
    let record = SyncRecord {
        table_name: "roles".to_string(),
        record_id: 999,
        fields: r#"{"id": 999, "name": "RemoteRole", "last_modified": "2026-03-30T12:00:00Z"}"#.to_string(),
        last_modified: "2026-03-30T12:00:00Z".to_string(),
    };

    queries::apply_remote_record(&pool, &record).await.unwrap();

    let roles = queries::list_roles(&pool).await.unwrap();
    assert!(roles.iter().any(|r| r.name == "RemoteRole"));
}

#[tokio::test]
async fn test_apply_remote_record_update() {
    let pool = test_pool().await;

    // Create a local role
    let id = queries::insert_role(&pool, "LocalRole").await.unwrap();

    // Apply a remote update
    let record = SyncRecord {
        table_name: "roles".to_string(),
        record_id: id,
        fields: format!(r#"{{"id": {}, "name": "UpdatedRole", "last_modified": "2026-03-30T12:00:00Z"}}"#, id),
        last_modified: "2026-03-30T12:00:00Z".to_string(),
    };

    queries::apply_remote_record(&pool, &record).await.unwrap();

    let roles = queries::list_roles(&pool).await.unwrap();
    assert!(roles.iter().any(|r| r.name == "UpdatedRole"));
    assert!(!roles.iter().any(|r| r.name == "LocalRole"));
}
```

- [ ] **Step 18: Run tests to verify they fail**

Run: `cargo test -p autorota-core test_apply_remote_record`

Expected: FAIL

- [ ] **Step 19: Implement apply_remote_record**

Add to `crates/autorota-core/src/db/queries.rs`:

```rust
/// Applies a remote record to the local database.
/// If the record exists locally, updates all syncable fields.
/// If it doesn't exist, inserts it.
/// In both cases, sets sync_status = 1 (already synced) and saves the base snapshot.
pub async fn apply_remote_record(
    pool: &SqlitePool,
    record: &SyncRecord,
) -> Result<(), sqlx::Error> {
    let columns = syncable_columns(&record.table_name);
    let fields: serde_json::Value =
        serde_json::from_str(&record.fields).map_err(|e| sqlx::Error::Protocol(e.to_string()))?;

    // Check if row exists
    let exists: bool = sqlx::query_scalar(&format!(
        "SELECT COUNT(*) > 0 FROM {} WHERE id = ?",
        record.table_name
    ))
    .bind(record.record_id)
    .fetch_one(pool)
    .await?;

    if exists {
        // UPDATE: set all syncable columns from the remote fields
        let set_clauses: Vec<String> = columns
            .iter()
            .filter(|c| **c != "id")
            .map(|c| format!("{} = json_extract(?, '$.{}')", c, c))
            .collect();
        let sql = format!(
            "UPDATE {} SET {}, sync_status = 1, sync_base_snapshot = ? WHERE id = ?",
            record.table_name,
            set_clauses.join(", ")
        );
        let mut query = sqlx::query(&sql);
        for _ in columns.iter().filter(|c| **c != "id") {
            query = query.bind(&record.fields);
        }
        query = query.bind(&record.fields).bind(record.record_id);
        query.execute(pool).await?;
    } else {
        // INSERT: build column list and values from JSON
        let col_list = columns.join(", ");
        let value_exprs: Vec<String> = columns
            .iter()
            .map(|c| format!("json_extract(?, '$.{}')", c))
            .collect();
        let sql = format!(
            "INSERT INTO {} ({}, sync_status, sync_base_snapshot) VALUES ({}, 1, ?)",
            record.table_name,
            col_list,
            value_exprs.join(", ")
        );
        let mut query = sqlx::query(&sql);
        for _ in &columns {
            query = query.bind(&record.fields);
        }
        query = query.bind(&record.fields);
        query.execute(pool).await?;
    }

    Ok(())
}
```

- [ ] **Step 20: Run tests to verify they pass**

Run: `cargo test -p autorota-core test_apply_remote_record`

Expected: PASS

- [ ] **Step 21: Update existing write queries to set last_modified and sync_status**

Every INSERT and UPDATE in `queries.rs` needs to set `last_modified = now()` and `sync_status = 0`. This is a systematic change across all existing query functions.

For each `INSERT` query: add `last_modified` and `sync_status` to the column list and bind `chrono::Utc::now().to_rfc3339()` and `0`.

For each `UPDATE` query: add `last_modified = ?, sync_status = 0` to the SET clause and bind `chrono::Utc::now().to_rfc3339()`.

For hard `DELETE` queries (assignments, shifts, rotas, roles, overrides): insert a tombstone before deleting the row. For soft-delete queries (employees, shift_templates): just update the row (tombstone not needed since the row persists).

Example for `insert_employee`:
```rust
// Before:
"INSERT INTO employees (first_name, last_name, ...) VALUES (?, ?, ...)"
// After:
"INSERT INTO employees (first_name, last_name, ..., last_modified, sync_status) VALUES (?, ?, ..., ?, 0)"
// Bind: chrono::Utc::now().to_rfc3339()
```

Example for `update_employee`:
```rust
// Before:
"UPDATE employees SET first_name = ?, ... WHERE id = ?"
// After:
"UPDATE employees SET first_name = ?, ..., last_modified = ?, sync_status = 0 WHERE id = ?"
// Bind: chrono::Utc::now().to_rfc3339()
```

Example for `delete_assignment`:
```rust
pub async fn delete_assignment(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    insert_tombstone(pool, "assignments", id).await?;
    sqlx::query("DELETE FROM assignments WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}
```

Apply this pattern to ALL write functions in queries.rs. The full list:
- `insert_employee`, `update_employee`, `delete_employee` (soft-delete, no tombstone)
- `insert_shift_template`, `update_shift_template`, `delete_shift_template` (soft-delete, no tombstone)
- `insert_rota`, `finalize_rota`, `delete_rota` (hard delete — add tombstone for rota)
- `insert_shift`, `delete_shift`, `delete_shifts_for_rota`, `update_shift_times` (hard delete — add tombstone)
- `insert_assignment`, `delete_proposed_assignments`, `update_assignment_status`, `update_assignment_shift`, `swap_assignment_shifts`, `delete_assignment` (hard delete — add tombstone)
- `insert_role`, `update_role`, `delete_role` (hard delete — add tombstone)
- `upsert_employee_availability_override`, `delete_employee_availability_override` (hard delete — add tombstone)
- `upsert_shift_template_override`, `delete_shift_template_override` (hard delete — add tombstone)
- `materialise_shifts` (calls insert_shift internally, so it's covered)

- [ ] **Step 22: Run full Rust test suite**

Run: `cargo test -p autorota-core`

Expected: All tests pass. Existing behavior unchanged; sync columns populated automatically.

- [ ] **Step 23: Commit**

```bash
git add crates/autorota-core/src/db/queries.rs crates/autorota-core/tests/
git commit -m "feat: add sync query functions and update all writes with change tracking"
```

---

## Task 4: FFI Sync Types and Exports

**Files:**
- Modify: `crates/autorota-ffi/src/types.rs`
- Modify: `crates/autorota-ffi/src/lib.rs`

- [ ] **Step 1: Add FFI sync types**

Add to `crates/autorota-ffi/src/types.rs`:

```rust
#[derive(Clone, uniffi::Record)]
pub struct FfiSyncRecord {
    pub table_name: String,
    pub record_id: i64,
    pub fields: String,
    pub last_modified: String,
}

#[derive(Clone, uniffi::Record)]
pub struct FfiMergeConflict {
    pub record_id: i64,
    pub resolved_fields: String,
}

#[derive(Clone, uniffi::Record)]
pub struct FfiBaseSnapshot {
    pub record_id: i64,
    pub snapshot: String,
}

#[derive(Clone, uniffi::Record)]
pub struct FfiTombstone {
    pub id: i64,
    pub table_name: String,
    pub record_id: i64,
    pub deleted_at: String,
}
```

- [ ] **Step 2: Add FFI sync export functions**

Add to `crates/autorota-ffi/src/lib.rs`:

```rust
use autorota_core::models::sync::{SyncRecord, Tombstone, BaseSnapshot};

#[uniffi::export]
pub fn get_pending_sync_records(table_name: String) -> Result<Vec<FfiSyncRecord>, FfiError> {
    let pool = pool()?;
    let records = rt()
        .block_on(queries::get_pending_sync_records(pool, &table_name))
        .map_err(FfiError::from)?;
    Ok(records
        .into_iter()
        .map(|r| FfiSyncRecord {
            table_name: r.table_name,
            record_id: r.record_id,
            fields: r.fields,
            last_modified: r.last_modified,
        })
        .collect())
}

#[uniffi::export]
pub fn mark_records_synced(
    table_name: String,
    record_ids: Vec<i64>,
    base_snapshots: Vec<String>,
) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::mark_records_synced(
        pool,
        &table_name,
        &record_ids,
        &base_snapshots,
    ))
    .map_err(FfiError::from)?;
    Ok(())
}

#[uniffi::export]
pub fn apply_remote_record(table_name: String, record: FfiSyncRecord) -> Result<(), FfiError> {
    let pool = pool()?;
    let core_record = SyncRecord {
        table_name: record.table_name,
        record_id: record.record_id,
        fields: record.fields,
        last_modified: record.last_modified,
    };
    rt().block_on(queries::apply_remote_record(pool, &core_record))
        .map_err(FfiError::from)?;
    Ok(())
}

#[uniffi::export]
pub fn get_sync_metadata(key: String) -> Result<Option<String>, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::get_sync_metadata(pool, &key))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn set_sync_metadata(key: String, value: String) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::set_sync_metadata(pool, &key, &value))
        .map_err(FfiError::from)?;
    Ok(())
}

#[uniffi::export]
pub fn get_base_snapshots(
    table_name: String,
    record_ids: Vec<i64>,
) -> Result<Vec<FfiBaseSnapshot>, FfiError> {
    let pool = pool()?;
    let snapshots = rt()
        .block_on(queries::get_base_snapshots(pool, &table_name, &record_ids))
        .map_err(FfiError::from)?;
    Ok(snapshots
        .into_iter()
        .map(|s| FfiBaseSnapshot {
            record_id: s.record_id,
            snapshot: s.snapshot,
        })
        .collect())
}

#[uniffi::export]
pub fn get_pending_tombstones() -> Result<Vec<FfiTombstone>, FfiError> {
    let pool = pool()?;
    let tombstones = rt()
        .block_on(queries::get_pending_tombstones(pool))
        .map_err(FfiError::from)?;
    Ok(tombstones
        .into_iter()
        .map(|t| FfiTombstone {
            id: t.id,
            table_name: t.table_name,
            record_id: t.record_id,
            deleted_at: t.deleted_at,
        })
        .collect())
}

#[uniffi::export]
pub fn clear_tombstones(ids: Vec<i64>) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::clear_tombstones(pool, &ids))
        .map_err(FfiError::from)?;
    Ok(())
}

/// Returns the count of employees in the database (used for first-launch detection).
#[uniffi::export]
pub fn count_employees() -> Result<i64, FfiError> {
    let pool = pool()?;
    let count: i64 = rt()
        .block_on(sqlx::query_scalar("SELECT COUNT(*) FROM employees").fetch_one(pool))
        .map_err(FfiError::from)?;
    Ok(count)
}
```

- [ ] **Step 3: Verify compilation**

Run: `cargo check -p autorota-ffi`

Expected: Compiles cleanly.

- [ ] **Step 4: Commit**

```bash
git add crates/autorota-ffi/src/types.rs crates/autorota-ffi/src/lib.rs
git commit -m "feat: add sync FFI types and export functions"
```

---

## Task 5: Regenerate Swift Bindings and Add Async Wrappers

**Files:**
- Modify: `platforms/apple/AutorotaKit/Sources/AutorotaKit/generated/autorota_ffi.swift` (auto-generated)
- Modify: `platforms/apple/AutorotaKit/Sources/AutorotaKit/AutorotaKit.swift`

- [ ] **Step 1: Rebuild the XCFramework with new FFI functions**

Run: `make swift-build-xcframework-debug`

This regenerates the Swift bindings in `AutorotaKit/Sources/AutorotaKit/generated/autorota_ffi.swift` with the new sync types and functions.

Expected: Build succeeds. New types (`FfiSyncRecord`, `FfiBaseSnapshot`, `FfiTombstone`, `FfiMergeConflict`) and functions (`getPendingSyncRecords`, `markRecordsSynced`, etc.) appear in the generated Swift file.

- [ ] **Step 2: Add async wrappers for sync FFI functions**

Add to `platforms/apple/AutorotaKit/Sources/AutorotaKit/AutorotaKit.swift`, following the existing pattern:

```swift
// MARK: - Sync

public func getPendingSyncRecordsAsync(tableName: String) async throws -> [FfiSyncRecord] {
    try await Task.detached(priority: .userInitiated) {
        try getPendingSyncRecords(tableName: tableName)
    }.value
}

public func markRecordsSyncedAsync(tableName: String, recordIds: [Int64], baseSnapshots: [String]) async throws {
    try await Task.detached(priority: .userInitiated) {
        try markRecordsSynced(tableName: tableName, recordIds: recordIds, baseSnapshots: baseSnapshots)
    }.value
}

public func applyRemoteRecordAsync(tableName: String, record: FfiSyncRecord) async throws {
    try await Task.detached(priority: .userInitiated) {
        try applyRemoteRecord(tableName: tableName, record: record)
    }.value
}

public func getSyncMetadataAsync(key: String) async throws -> String? {
    try await Task.detached(priority: .userInitiated) {
        try getSyncMetadata(key: key)
    }.value
}

public func setSyncMetadataAsync(key: String, value: String) async throws {
    try await Task.detached(priority: .userInitiated) {
        try setSyncMetadata(key: key, value: value)
    }.value
}

public func getBaseSnapshotsAsync(tableName: String, recordIds: [Int64]) async throws -> [FfiBaseSnapshot] {
    try await Task.detached(priority: .userInitiated) {
        try getBaseSnapshots(tableName: tableName, recordIds: recordIds)
    }.value
}

public func getPendingTombstonesAsync() async throws -> [FfiTombstone] {
    try await Task.detached(priority: .userInitiated) {
        try getPendingTombstones()
    }.value
}

public func clearTombstonesAsync(ids: [Int64]) async throws {
    try await Task.detached(priority: .userInitiated) {
        try clearTombstones(ids: ids)
    }.value
}

public func countEmployeesAsync() async throws -> Int64 {
    try await Task.detached(priority: .userInitiated) {
        try countEmployees()
    }.value
}
```

- [ ] **Step 3: Verify Swift compilation**

Run: `make swift-build-check`

Expected: All platforms compile cleanly.

- [ ] **Step 4: Commit**

```bash
git add platforms/apple/AutorotaKit/
git commit -m "feat: add Swift async wrappers for sync FFI functions"
```

---

## Task 6: Sync Record Mapper

**Files:**
- Create: `platforms/apple/Apps/AutorotaApp/Services/SyncRecordMapper.swift`

This file converts between `FfiSyncRecord` (JSON fields) and `CKRecord` fields, and defines the CloudKit record type names per table.

- [ ] **Step 1: Create SyncRecordMapper**

Create `platforms/apple/Apps/AutorotaApp/Services/SyncRecordMapper.swift`:

```swift
import CloudKit
import Foundation

enum SyncRecordMapper {
    /// All table names that participate in sync, in dependency order
    /// (parents before children for inserts, reverse for deletes).
    static let allTables = [
        "roles",
        "employees",
        "shift_templates",
        "rotas",
        "shifts",
        "assignments",
        "employee_availability_overrides",
        "shift_template_overrides",
    ]

    /// The CloudKit record zone used for all synced data.
    static let zoneName = "AutorotaZone"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName)

    /// Maps a table name to a CloudKit record type name.
    static func recordType(for tableName: String) -> String {
        switch tableName {
        case "employees": return "Employee"
        case "shift_templates": return "ShiftTemplate"
        case "rotas": return "Rota"
        case "shifts": return "Shift"
        case "assignments": return "Assignment"
        case "roles": return "Role"
        case "employee_availability_overrides": return "EmployeeAvailabilityOverride"
        case "shift_template_overrides": return "ShiftTemplateOverride"
        default: return tableName
        }
    }

    /// Extracts the table name and SQLite row ID from a CKRecord.ID.
    /// Record names follow the pattern "{table_name}_{id}".
    static func parseRecordID(_ recordID: CKRecord.ID) -> (tableName: String, rowID: Int64)? {
        let name = recordID.recordName
        guard let lastUnderscore = name.lastIndex(of: "_") else { return nil }
        let table = String(name[name.startIndex..<lastUnderscore])
        let idStr = String(name[name.index(after: lastUnderscore)...])
        guard let rowID = Int64(idStr) else { return nil }
        return (table, rowID)
    }

    /// Builds a CKRecord.ID for a given table and row.
    static func makeRecordID(tableName: String, rowID: Int64) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(tableName)_\(rowID)", zoneID: zoneID)
    }

    /// Converts an FfiSyncRecord to a CKRecord, setting all fields from the JSON.
    static func toCKRecord(_ syncRecord: FfiSyncRecord) -> CKRecord? {
        let ckRecordType = recordType(for: syncRecord.tableName)
        let recordID = makeRecordID(tableName: syncRecord.tableName, rowID: syncRecord.recordId)
        let record = CKRecord(recordType: ckRecordType, recordID: recordID)

        guard let data = syncRecord.fields.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        for (key, value) in json {
            if key == "id" { continue } // ID is in the record name, not a field
            switch value {
            case let s as String: record[key] = s as CKRecordValue
            case let n as NSNumber: record[key] = n as CKRecordValue
            case let b as Bool: record[key] = (b ? 1 : 0) as CKRecordValue
            case is NSNull: record[key] = nil
            default: record[key] = "\(value)" as CKRecordValue
            }
        }

        return record
    }

    /// Converts a CKRecord back to an FfiSyncRecord.
    static func fromCKRecord(_ record: CKRecord) -> FfiSyncRecord? {
        guard let (tableName, rowID) = parseRecordID(record.recordID) else { return nil }

        var json: [String: Any] = ["id": rowID]
        for key in record.allKeys() {
            if let value = record[key] {
                json[key] = value
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let fields = String(data: data, encoding: .utf8)
        else { return nil }

        let lastModified = (json["last_modified"] as? String) ?? ""

        return FfiSyncRecord(
            tableName: tableName,
            recordId: rowID,
            fields: fields,
            lastModified: lastModified
        )
    }
}
```

- [ ] **Step 2: Verify Swift compilation**

Run: `make swift-build-check-ios`

Expected: Compiles cleanly.

- [ ] **Step 3: Commit**

```bash
git add platforms/apple/Apps/AutorotaApp/Services/SyncRecordMapper.swift
git commit -m "feat: add SyncRecordMapper for CKRecord ↔ FfiSyncRecord conversion"
```

---

## Task 7: Sync Conflict Resolver

**Files:**
- Create: `platforms/apple/Apps/AutorotaApp/Services/SyncConflictResolver.swift`

- [ ] **Step 1: Create SyncConflictResolver**

Create `platforms/apple/Apps/AutorotaApp/Services/SyncConflictResolver.swift`:

```swift
import CloudKit
import Foundation

enum SyncConflictResolver {
    /// Performs a three-way merge between base, local, and server versions of a record.
    ///
    /// - Parameters:
    ///   - base: The field values at last successful sync (from sync_base_snapshot). Nil if no base exists (first sync).
    ///   - local: The current local field values (from SQLite).
    ///   - server: The field values from the CloudKit server record.
    ///   - localLastModified: The local row's last_modified timestamp.
    ///   - serverLastModified: The server record's last_modified timestamp.
    /// - Returns: The merged field values as a JSON dictionary.
    static func merge(
        base: [String: Any]?,
        local: [String: Any],
        server: [String: Any],
        localLastModified: String,
        serverLastModified: String
    ) -> [String: Any] {
        // If no base snapshot exists, fall back to timestamp-based last-write-wins at row level.
        guard let base else {
            return serverLastModified >= localLastModified ? server : local
        }

        var result = local // Start with local, apply server changes

        for key in Set(local.keys).union(server.keys) {
            if key == "id" || key == "last_modified" { continue }

            let baseVal = base[key]
            let localVal = local[key]
            let serverVal = server[key]

            let localChanged = !valuesEqual(baseVal, localVal)
            let serverChanged = !valuesEqual(baseVal, serverVal)

            if !localChanged && serverChanged {
                // Only server changed this field — take server's value
                result[key] = serverVal
            } else if localChanged && !serverChanged {
                // Only local changed — keep local (already in result)
                continue
            } else if localChanged && serverChanged {
                // Both changed — later timestamp wins, server as tiebreaker
                if serverLastModified >= localLastModified {
                    result[key] = serverVal
                }
                // else keep local (already in result)
            }
            // Neither changed — keep base/local (already in result)
        }

        // Use the later timestamp
        result["last_modified"] = max(localLastModified, serverLastModified)

        return result
    }

    /// Compares two JSON values for equality, handling nil/NSNull.
    private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (is NSNull, nil), (nil, is NSNull), (is NSNull, is NSNull): return true
        case (nil, _), (_, nil): return false
        case (let a as String, let b as String): return a == b
        case (let a as NSNumber, let b as NSNumber): return a == b
        case (let a as Bool, let b as Bool): return a == b
        default: return "\(a!)" == "\(b!)"
        }
    }
}
```

- [ ] **Step 2: Verify Swift compilation**

Run: `make swift-build-check-ios`

Expected: Compiles cleanly.

- [ ] **Step 3: Commit**

```bash
git add platforms/apple/Apps/AutorotaApp/Services/SyncConflictResolver.swift
git commit -m "feat: add SyncConflictResolver with three-way per-field merge"
```

---

## Task 8: AutorotaSyncEngine (CKSyncEngine Delegate)

**Files:**
- Create: `platforms/apple/Apps/AutorotaApp/Services/AutorotaSyncEngine.swift`

This is the core sync engine. It conforms to `CKSyncEngineDelegate` and orchestrates push/pull operations.

- [ ] **Step 1: Create AutorotaSyncEngine**

Create `platforms/apple/Apps/AutorotaApp/Services/AutorotaSyncEngine.swift`:

```swift
import CloudKit
import Foundation
import os

@Observable
final class AutorotaSyncEngine: @unchecked Sendable {
    enum SyncStatus: Sendable {
        case idle
        case syncing
        case error(String)
    }

    private(set) var status: SyncStatus = .idle
    private var engine: CKSyncEngine?
    private let logger = Logger(subsystem: "com.toadmountain.autorota", category: "sync")

    /// Initialize the sync engine. Call after `autorotaInitDb()`.
    func start() async {
        do {
            let config = try await loadOrCreateConfiguration()
            let engine = CKSyncEngine(config)
            engine.delegate = self
            self.engine = engine
            logger.info("CKSyncEngine started")
        } catch {
            logger.error("Failed to start CKSyncEngine: \(error)")
            status = .error(error.localizedDescription)
        }
    }

    /// Notify the engine that local data has changed and needs to be pushed.
    func schedulePush() {
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: SyncRecordMapper.zoneID))
        ])
        scheduleRecordChanges()
    }

    /// Queues all pending local records for push.
    private func scheduleRecordChanges() {
        guard let engine else { return }
        do {
            var pendingIDs: [CKRecord.ID] = []
            for table in SyncRecordMapper.allTables {
                let records = try getPendingSyncRecords(tableName: table)
                for record in records {
                    pendingIDs.append(SyncRecordMapper.makeRecordID(tableName: table, rowID: record.recordId))
                }
            }
            let tombstones = try getPendingTombstones()
            var deletionIDs: [CKRecord.ID] = []
            for t in tombstones {
                deletionIDs.append(SyncRecordMapper.makeRecordID(tableName: t.tableName, rowID: t.recordId))
            }
            if !pendingIDs.isEmpty {
                engine.state.add(pendingRecordZoneChanges: pendingIDs.map { .saveRecord($0) })
            }
            if !deletionIDs.isEmpty {
                engine.state.add(pendingRecordZoneChanges: deletionIDs.map { .deleteRecord($0) })
            }
        } catch {
            logger.error("Failed to schedule record changes: \(error)")
        }
    }

    // MARK: - Configuration Persistence

    private func loadOrCreateConfiguration() async throws -> CKSyncEngine.Configuration {
        var savedState: CKSyncEngine.State.Serialization?

        if let stateData = try getSyncMetadata(key: "ck_engine_state"),
           let data = stateData.data(using: .utf8) {
            savedState = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }

        let database = CKContainer(identifier: "iCloud.com.toadmountain.autorota").privateCloudDatabase
        let config = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: savedState,
            delegate: self
        )
        return config
    }

    private func saveEngineState(_ state: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(state)
            if let str = String(data: data, encoding: .utf8) {
                try setSyncMetadata(key: "ck_engine_state", value: str)
            }
        } catch {
            logger.error("Failed to save engine state: \(error)")
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension AutorotaSyncEngine: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveEngineState(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedDatabaseChanges(let fetchedChanges):
            // Zone creations/deletions — we only use one zone so this is mostly a no-op.
            for deletion in fetchedChanges.deletions {
                if deletion.zoneID == SyncRecordMapper.zoneID {
                    logger.warning("AutorotaZone was deleted from iCloud")
                }
            }

        case .fetchedRecordZoneChanges(let fetchedChanges):
            handleFetchedRecordZoneChanges(fetchedChanges)

        case .sentRecordZoneChanges(let sentChanges):
            handleSentRecordZoneChanges(sentChanges)

        case .sentDatabaseChanges:
            break

        case .willFetchChanges:
            status = .syncing

        case .didFetchChanges:
            status = .idle

        case .willSendChanges:
            status = .syncing

        case .didSendChanges:
            status = .idle

        @unknown default:
            logger.info("Unknown CKSyncEngine event: \(String(describing: event))")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let allPendingChanges = engine?.state.pendingRecordZoneChanges ?? []
        let filteredChanges = allPendingChanges.filter { scope.contains($0) }
        guard !filteredChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: filteredChanges) { recordID in
            guard let (tableName, rowID) = SyncRecordMapper.parseRecordID(recordID) else { return nil }
            do {
                let records = try getPendingSyncRecords(tableName: tableName)
                guard let record = records.first(where: { $0.recordId == rowID }) else { return nil }
                return SyncRecordMapper.toCKRecord(record)
            } catch {
                self.logger.error("Failed to build CKRecord for \(recordID): \(error)")
                return nil
            }
        }
    }

    // MARK: - Handling Fetched Changes (Pull)

    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        // Handle modifications (inserts + updates from other devices)
        for modification in changes.modifications {
            let record = modification.record
            guard let syncRecord = SyncRecordMapper.fromCKRecord(record) else {
                logger.warning("Could not parse CKRecord: \(record.recordID)")
                continue
            }

            do {
                // Check if we have a local version for conflict resolution
                let snapshots = try getBaseSnapshots(tableName: syncRecord.tableName, recordIds: [syncRecord.recordId])
                let localRecords = try getPendingSyncRecords(tableName: syncRecord.tableName)
                let localRecord = localRecords.first(where: { $0.recordId == syncRecord.recordId })

                if let localRecord, localRecord.recordId == syncRecord.recordId {
                    // Potential conflict: merge using base snapshot
                    let base = snapshots.first.flatMap { parseJSON($0.snapshot) }
                    let local = parseJSON(localRecord.fields) ?? [:]
                    let server = parseJSON(syncRecord.fields) ?? [:]

                    let merged = SyncConflictResolver.merge(
                        base: base,
                        local: local,
                        server: server,
                        localLastModified: localRecord.lastModified,
                        serverLastModified: syncRecord.lastModified
                    )

                    if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
                       let mergedFields = String(data: mergedData, encoding: .utf8) {
                        let mergedRecord = FfiSyncRecord(
                            tableName: syncRecord.tableName,
                            recordId: syncRecord.recordId,
                            fields: mergedFields,
                            lastModified: (merged["last_modified"] as? String) ?? syncRecord.lastModified
                        )
                        try applyRemoteRecord(tableName: syncRecord.tableName, record: mergedRecord)
                    }
                } else {
                    // No local conflict — just apply the remote record
                    try applyRemoteRecord(tableName: syncRecord.tableName, record: syncRecord)
                }
            } catch {
                logger.error("Failed to apply remote record \(syncRecord.tableName)_\(syncRecord.recordId): \(error)")
            }
        }

        // Handle deletions
        for deletion in changes.deletions {
            guard let (tableName, _) = SyncRecordMapper.parseRecordID(deletion.recordID) else { continue }
            // The record was deleted on another device. We need to delete it locally.
            // For soft-delete tables, set deleted=1. For others, hard delete.
            let deleteRecord = FfiSyncRecord(
                tableName: tableName,
                recordId: 0, // Not used for deletion
                fields: "{\"deleted\": 1}",
                lastModified: ""
            )
            // Deletion handling will be done via a dedicated FFI function in a future iteration.
            // For now, log it.
            logger.info("Remote deletion: \(deletion.recordID.recordName)")
            _ = deleteRecord // suppress unused warning
        }
    }

    // MARK: - Handling Sent Changes (Push confirmation)

    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        // Mark successfully saved records as synced
        var successesByTable: [String: [(Int64, String)]] = [:]

        for success in changes.savedRecords {
            guard let syncRecord = SyncRecordMapper.fromCKRecord(success) else { continue }
            successesByTable[syncRecord.tableName, default: []].append((syncRecord.recordId, syncRecord.fields))
        }

        for (tableName, records) in successesByTable {
            let ids = records.map { $0.0 }
            let snapshots = records.map { $0.1 }
            do {
                try markRecordsSynced(tableName: tableName, recordIds: ids, baseSnapshots: snapshots)
            } catch {
                logger.error("Failed to mark records synced for \(tableName): \(error)")
            }
        }

        // Clear tombstones for successfully deleted records
        var clearedTombstoneIDs: [Int64] = []
        for deletedID in changes.deletedRecordIDs {
            guard let (tableName, rowID) = SyncRecordMapper.parseRecordID(deletedID) else { continue }
            // Find the tombstone ID for this record
            do {
                let tombstones = try getPendingTombstones()
                if let tombstone = tombstones.first(where: { $0.tableName == tableName && $0.recordId == rowID }) {
                    clearedTombstoneIDs.append(tombstone.id)
                }
            } catch {
                logger.error("Failed to find tombstone for \(deletedID): \(error)")
            }
        }
        if !clearedTombstoneIDs.isEmpty {
            do {
                try clearTombstones(ids: clearedTombstoneIDs)
            } catch {
                logger.error("Failed to clear tombstones: \(error)")
            }
        }

        // Handle failures — CKSyncEngine will retry automatically for transient errors
        for failure in changes.failedRecordSaves {
            logger.warning("Failed to save record \(failure.record.recordID): \(failure.error)")
        }
    }

    // MARK: - Account Changes

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            logger.info("iCloud account signed in — scheduling full push")
            schedulePush()
        case .signOut:
            logger.info("iCloud account signed out — sync paused")
            status = .idle
        case .switchAccounts:
            logger.warning("iCloud account switched — data may be stale")
            status = .error("iCloud account changed. Please restart the app.")
        @unknown default:
            break
        }
    }

    // MARK: - Helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
```

- [ ] **Step 2: Verify Swift compilation**

Run: `make swift-build-check-ios`

Expected: Compiles cleanly. Note: there may be warnings about `CKSyncEngine.Configuration` initializer — adjust if the API requires different parameters for your Xcode version.

- [ ] **Step 3: Commit**

```bash
git add platforms/apple/Apps/AutorotaApp/Services/AutorotaSyncEngine.swift
git commit -m "feat: add AutorotaSyncEngine with CKSyncEngineDelegate implementation"
```

---

## Task 9: First-Launch Sync Prompt View

**Files:**
- Create: `platforms/apple/Apps/AutorotaApp/Views/SyncPromptView.swift`

- [ ] **Step 1: Create SyncPromptView**

Create `platforms/apple/Apps/AutorotaApp/Views/SyncPromptView.swift`:

```swift
import SwiftUI

struct SyncPromptView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("iCloud Data Found")
                .font(.title2.bold())

            Text("Your Autorota data was found on iCloud. Would you like to download it to this device?")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button(action: onAccept) {
                    Text("Download from iCloud")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onDecline) {
                    Text("Start Fresh")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
        }
        .padding()
    }
}
```

- [ ] **Step 2: Verify Swift compilation**

Run: `make swift-build-check-ios`

Expected: Compiles cleanly.

- [ ] **Step 3: Commit**

```bash
git add platforms/apple/Apps/AutorotaApp/Views/SyncPromptView.swift
git commit -m "feat: add SyncPromptView for first-launch iCloud data prompt"
```

---

## Task 10: App Launch Flow Integration

**Files:**
- Modify: `platforms/apple/Apps/AutorotaApp/AutorotaApp/AutorotaAppApp.swift`
- Modify: `platforms/apple/Apps/AutorotaApp/Views/SettingsView.swift`

- [ ] **Step 1: Add sync engine to app entry point**

Modify `platforms/apple/Apps/AutorotaApp/AutorotaApp/AutorotaAppApp.swift`:

```swift
@main
struct AutorotaAppApp: App {

    init() {
        do {
            try autorotaInitDb()
        } catch {
            fatalError("Failed to initialise database: \(error)")
        }
    }

    @AppStorage("appAppearance") private var appearance: String = AppAppearance.system.rawValue
    @State private var exchangeRateService = ExchangeRateService()
    @State private var syncEngine = AutorotaSyncEngine()
    @State private var showSyncPrompt = false
    @State private var syncCheckComplete = false

    var body: some Scene {
        WindowGroup {
            Group {
                if syncCheckComplete {
                    ContentView()
                } else {
                    ProgressView("Loading...")
                }
            }
            .sheet(isPresented: $showSyncPrompt) {
                SyncPromptView(
                    onAccept: {
                        showSyncPrompt = false
                        Task { await syncEngine.start() }
                        do {
                            try setSyncMetadata(key: "sync_initialized", value: "true")
                        } catch {}
                    },
                    onDecline: {
                        showSyncPrompt = false
                        do {
                            try setSyncMetadata(key: "sync_disabled", value: "true")
                        } catch {}
                    }
                )
                .interactiveDismissDisabled()
            }
            .environment(exchangeRateService)
            .environment(syncEngine)
            .task {
                await exchangeRateService.fetchRates()
                await checkFirstLaunchSync()
            }
            .preferredColorScheme(selectedAppearance.colorScheme)
        }
    }

    private func checkFirstLaunchSync() async {
        do {
            let initialized = try getSyncMetadata(key: "sync_initialized")
            let disabled = try getSyncMetadata(key: "sync_disabled")

            if initialized != nil {
                // Already set up — start sync engine normally
                await syncEngine.start()
                syncCheckComplete = true
                return
            }

            if disabled != nil {
                // User previously declined — skip sync
                syncCheckComplete = true
                return
            }

            // First launch: check if cloud data exists
            let localCount = try countEmployees()
            let hasCloudData = await checkCloudZoneExists()

            if hasCloudData && localCount == 0 {
                // Cloud data exists, local is empty — prompt user
                syncCheckComplete = true
                showSyncPrompt = true
            } else {
                // No cloud data or local has data — start sync normally
                await syncEngine.start()
                try setSyncMetadata(key: "sync_initialized", value: "true")
                syncCheckComplete = true
            }
        } catch {
            // On error, just start without sync
            syncCheckComplete = true
        }
    }

    private func checkCloudZoneExists() async -> Bool {
        let container = CKContainer(identifier: "iCloud.com.toadmountain.autorota")
        let database = container.privateCloudDatabase
        do {
            let zoneID = SyncRecordMapper.zoneID
            _ = try await database.recordZone(for: zoneID)
            return true
        } catch {
            return false
        }
    }

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }
}
```

Note: You'll need to add `import CloudKit` at the top of this file.

- [ ] **Step 2: Add sync status section to SettingsView**

Add a new section to `platforms/apple/Apps/AutorotaApp/Views/SettingsView.swift`, inside the `Form`, after the existing sections:

```swift
@Environment(AutorotaSyncEngine.self) private var syncEngine

// Add this Section inside the Form:
Section("iCloud Sync") {
    HStack {
        Text("Status")
        Spacer()
        switch syncEngine.status {
        case .idle:
            Label("Synced", systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing...")
            }
            .foregroundStyle(.secondary)
        case .error(let message):
            Label("Error", systemImage: "exclamationmark.icloud")
                .foregroundStyle(.red)
                .help(message)
        }
    }
}
```

- [ ] **Step 3: Verify Swift compilation**

Run: `make swift-build-check-ios`

Expected: Compiles cleanly.

- [ ] **Step 4: Commit**

```bash
git add platforms/apple/Apps/AutorotaApp/AutorotaApp/AutorotaAppApp.swift platforms/apple/Apps/AutorotaApp/Views/SettingsView.swift
git commit -m "feat: integrate sync engine into app launch flow with first-launch prompt and settings status"
```

---

## Task 11: Wire Sync Push into Service Layer

**Files:**
- Modify: `platforms/apple/Apps/AutorotaApp/Services/LiveAutorotaService.swift`

After any local write operation, the sync engine needs to be notified to schedule a push. The cleanest way is to post a notification from `LiveAutorotaService` after mutating calls, and have `AutorotaSyncEngine` listen for it.

- [ ] **Step 1: Add a sync notification**

Add to `LiveAutorotaService.swift` (or a new small extension file):

```swift
import Foundation

extension Notification.Name {
    static let autorotaDataChanged = Notification.Name("autorotaDataChanged")
}
```

- [ ] **Step 2: Post notification after every mutating call in LiveAutorotaService**

For every method in `LiveAutorotaService` that creates, updates, or deletes data, add a notification post after the FFI call. Example pattern:

```swift
func createRole(name: String) async throws -> Int64 {
    let id = try await createRoleAsync(name: name)
    NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
    return id
}

func updateRole(id: Int64, name: String) async throws {
    try await updateRoleAsync(id: id, name: name)
    NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
}

func deleteRole(id: Int64) async throws {
    try await deleteRoleAsync(id: id)
    NotificationCenter.default.post(name: .autorotaDataChanged, object: nil)
}
```

Apply this pattern to ALL mutating methods: create/update/delete for employees, shift templates, rotas, assignments, shifts, overrides, and schedule operations (runSchedule, materialiseWeek, deleteWeek, finalizeRota).

Read-only methods (list*, get*) do NOT need this notification.

- [ ] **Step 3: Subscribe to the notification in AutorotaSyncEngine**

Add to `AutorotaSyncEngine.swift` in the `start()` method, after the engine is created:

```swift
NotificationCenter.default.addObserver(
    forName: .autorotaDataChanged,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.schedulePush()
}
```

- [ ] **Step 4: Verify Swift compilation**

Run: `make swift-build-check-ios`

Expected: Compiles cleanly.

- [ ] **Step 5: Commit**

```bash
git add platforms/apple/Apps/AutorotaApp/Services/LiveAutorotaService.swift platforms/apple/Apps/AutorotaApp/Services/AutorotaSyncEngine.swift
git commit -m "feat: wire data change notifications to trigger sync push"
```

---

## Task 12: Xcode Entitlements and CloudKit Container

**Files:**
- Create or modify: `platforms/apple/Apps/AutorotaApp/AutorotaApp/AutorotaApp.entitlements`

- [ ] **Step 1: Add CloudKit entitlements**

Create or update `platforms/apple/Apps/AutorotaApp/AutorotaApp/AutorotaApp.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.toadmountain.autorota</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.ubiquity-kvstore-identifier</key>
    <string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
    <key>UIBackgroundModes</key>
    <array>
        <string>fetch</string>
        <string>remote-notification</string>
    </array>
</dict>
</plist>
```

Note: This file may need to be added to the Xcode project manually via the Signing & Capabilities tab. The entitlements file must be referenced in the build settings under `CODE_SIGN_ENTITLEMENTS`.

- [ ] **Step 2: Verify the Xcode project recognizes the entitlements**

Run: `make swift-build-check-ios`

Expected: Compiles. If entitlements aren't picked up, they'll need to be configured in the Xcode project file — this may require manual Xcode UI interaction to add the CloudKit capability.

- [ ] **Step 3: Commit**

```bash
git add platforms/apple/Apps/AutorotaApp/AutorotaApp/AutorotaApp.entitlements
git commit -m "feat: add CloudKit entitlements for iCloud sync"
```

---

## Task 13: Update MockAutorotaService for New FFI Functions

**Files:**
- Modify: `platforms/apple/Apps/AutorotaApp/AutorotaAppTests/MockAutorotaService.swift`

The sync functions are NOT part of `AutorotaServiceProtocol` (they're called directly via FFI, not through the service protocol), so the mock doesn't need sync methods. However, if any compilation issues arise from the new `AutorotaSyncEngine` environment injection, verify the mock still compiles.

- [ ] **Step 1: Verify existing tests still compile and pass**

Run: `make swift-test-app-macos`

Expected: All existing ViewModel tests pass. The sync engine is injected via `@Environment`, which tests don't use.

- [ ] **Step 2: Commit (only if changes were needed)**

If mock needed updates:
```bash
git add platforms/apple/Apps/AutorotaApp/AutorotaAppTests/
git commit -m "fix: update mock service for sync engine compatibility"
```

---

## Task 14: Integration Test — Sync Metadata Roundtrip via FFI

**Files:**
- Modify: `platforms/apple/AutorotaKit/Tests/AutorotaKitTests/IntegrationTests.swift`

- [ ] **Step 1: Write integration test for sync metadata**

Add to `IntegrationTests.swift`:

```swift
func testSyncMetadataRoundtrip() async throws {
    // Initially nil
    let initial = try getSyncMetadata(key: "test_sync_key")
    XCTAssertNil(initial)

    // Set and get
    try setSyncMetadata(key: "test_sync_key", value: "test_value")
    let fetched = try getSyncMetadata(key: "test_sync_key")
    XCTAssertEqual(fetched, "test_value")

    // Overwrite
    try setSyncMetadata(key: "test_sync_key", value: "updated")
    let updated = try getSyncMetadata(key: "test_sync_key")
    XCTAssertEqual(updated, "updated")
}

func testPendingSyncRecordsAndMarkSynced() async throws {
    // Create a role (should be pending sync)
    let roleId = try createRole(name: "SyncTestRole_\(UUID().uuidString)")

    let pending = try getPendingSyncRecords(tableName: "roles")
    XCTAssertTrue(pending.contains(where: { $0.recordId == roleId }))

    // Mark as synced
    let snapshot = "{\"id\": \(roleId), \"name\": \"SyncTestRole\"}"
    try markRecordsSynced(tableName: "roles", recordIds: [roleId], baseSnapshots: [snapshot])

    // Should no longer be pending
    let afterSync = try getPendingSyncRecords(tableName: "roles")
    XCTAssertFalse(afterSync.contains(where: { $0.recordId == roleId }))

    // Base snapshot should be stored
    let snapshots = try getBaseSnapshots(tableName: "roles", recordIds: [roleId])
    XCTAssertEqual(snapshots.count, 1)

    // Clean up
    try deleteRole(id: roleId)
}

func testTombstoneLifecycle() async throws {
    let roleId = try createRole(name: "TombstoneTestRole_\(UUID().uuidString)")
    try deleteRole(id: roleId)

    // Should have a tombstone
    let tombstones = try getPendingTombstones()
    let match = tombstones.first(where: { $0.tableName == "roles" && $0.recordId == roleId })
    XCTAssertNotNil(match)

    // Clear it
    if let t = match {
        try clearTombstones(ids: [t.id])
    }

    let after = try getPendingTombstones()
    XCTAssertFalse(after.contains(where: { $0.tableName == "roles" && $0.recordId == roleId }))
}
```

- [ ] **Step 2: Run integration tests**

Run: `make swift-test-package`

Expected: All tests pass (requires XCFramework to be built first from Task 5).

- [ ] **Step 3: Commit**

```bash
git add platforms/apple/AutorotaKit/Tests/AutorotaKitTests/IntegrationTests.swift
git commit -m "test: add integration tests for sync metadata, pending records, and tombstones"
```

---

## Task 15: Full Build Verification

- [ ] **Step 1: Run the complete Rust test suite**

Run: `cargo test`

Expected: All tests pass.

- [ ] **Step 2: Rebuild XCFramework**

Run: `make swift-build-xcframework-debug`

Expected: Build succeeds with all new FFI functions.

- [ ] **Step 3: Run Swift build checks**

Run: `make swift-build-check`

Expected: Both iOS and macOS builds succeed.

- [ ] **Step 4: Run Swift ViewModel tests**

Run: `make swift-test-app-macos`

Expected: All existing tests pass.

- [ ] **Step 5: Run SPM integration tests**

Run: `make swift-test-package`

Expected: All tests pass, including new sync tests.

- [ ] **Step 6: Final commit (if any remaining changes)**

```bash
git add -A
git commit -m "chore: final build verification for iCloud sync feature"
```
