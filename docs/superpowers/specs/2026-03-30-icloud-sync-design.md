# iCloud Sync Design

**Date:** 2026-03-30
**Approach:** CKSyncEngine (iOS 17+ / macOS 14+)
**Scope:** Single-user, multi-device sync via CloudKit private database

## Goals

- Sync all domain data (employees, shifts, rotas, assignments, roles, overrides) across a user's Apple devices via iCloud
- Fully offline-first: local SQLite is always the source of truth, sync happens opportunistically in the background
- Per-field conflict resolution using base snapshots and timestamps
- Prompt user on new device before downloading cloud data
- Settings (UserDefaults/AppStorage) stay per-device

## Non-Goals

- Multi-user/shared database sync (future consideration)
- Syncing UserDefaults settings (appearance, currency, tab layout, export prefs)
- Android/Tauri sync (this is Apple-platform only)

---

## 1. Change Tracking in SQLite

### New columns on all 8 syncable tables

| Column | Type | Default | Purpose |
|--------|------|---------|---------|
| `last_modified` | TEXT (ISO 8601) | current timestamp | Updated on every INSERT/UPDATE |
| `sync_status` | INTEGER | 0 | 0 = pending sync, 1 = synced |
| `sync_base_snapshot` | TEXT (JSON) | NULL | Row field values at last successful sync, used for per-field conflict diffing |

**Affected tables:** employees, shift_templates, rotas, shifts, assignments, roles, employee_availability_overrides, shift_template_overrides.

### New tables

**`sync_metadata`** — stores sync engine state:

| Column | Type | Purpose |
|--------|------|---------|
| `key` | TEXT PRIMARY KEY | e.g. `"server_change_token"`, `"device_id"` |
| `value` | TEXT | Serialized value |

**`sync_tombstones`** — tracks hard-deleted rows for sync:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | INTEGER PRIMARY KEY | Auto-increment |
| `table_name` | TEXT | Source table name |
| `record_id` | INTEGER | SQLite row ID of deleted record |
| `deleted_at` | TEXT (ISO 8601) | When the deletion occurred |

Tombstones are cleaned up after successful sync push. Soft-deleted records (employees, shift_templates with `deleted` flag) don't need tombstones — they sync normally with `deleted = 1`.

### Write behavior

- Every Rust INSERT/UPDATE sets `last_modified = now()` and `sync_status = 0`
- After successful CloudKit push, Swift calls FFI to set `sync_status = 1` and save the `sync_base_snapshot`
- Hard deletes insert a row into `sync_tombstones` before removing the row

---

## 2. CloudKit Data Model

**Container:** `iCloud.com.toadmountain.autorota`

**Zone:** Single custom `CKRecordZone` named `"AutorotaZone"` in the private database. Required by CKSyncEngine for incremental change token fetching.

### Record types

| CKRecord Type | Source Table |
|---|---|
| `Employee` | employees |
| `ShiftTemplate` | shift_templates |
| `Rota` | rotas |
| `Shift` | shifts |
| `Assignment` | assignments |
| `Role` | roles |
| `EmployeeAvailabilityOverride` | employee_availability_overrides |
| `ShiftTemplateOverride` | shift_template_overrides |

**Field mapping:** All columns except `sync_status` and `sync_base_snapshot` are synced. JSON columns (`roles`, `availability`) are stored as CKRecord string fields. `last_modified` is synced so other devices can use it for conflict resolution.

**Record ID strategy:** `"{table_name}_{sqlite_id}"` — e.g. `"employee_42"`. Stable, globally unique, maps directly back to local rows.

**Relationships:** Foreign keys stored as plain integer fields (not CKRecord.Reference). Single-user sync doesn't need CloudKit's reference cascade behavior, and plain fields are simpler.

---

## 3. CKSyncEngine Integration

### AutorotaSyncEngine

New file: `platforms/apple/Apps/AutorotaApp/Services/AutorotaSyncEngine.swift`

- Conforms to `CKSyncEngineDelegate`
- Owns the `CKSyncEngine` instance
- Initialized at app launch after DB init

### Delegate event handling

| Event | Action |
|-------|--------|
| `.stateUpdate` | Persist engine state (change tokens) to `sync_metadata` via FFI |
| `.fetchedRecordZoneChanges` | Apply remote changes locally using merge logic (Section 4) |
| `.sentRecordZoneChanges` | Mark pushed rows as `sync_status = 1`, save base snapshots |

### `nextRecordZoneChangeBatch()`

Query all rows where `sync_status = 0` across all tables via FFI, convert to `CKRecord`s, return the batch. Also include pending tombstones as `CKSyncEngine.RecordZoneChangeBatch.DeletedRecord` entries.

### Triggering sync

After any local write, the service layer calls `syncEngine.schedulePush()`. CKSyncEngine batches and sends on its own schedule, respecting battery and network conditions.

---

## 4. Per-Field Conflict Resolution

### Three-way merge using base snapshots

When CKSyncEngine reports a conflict (push rejected because server record was modified), we have:

- **Base** — `sync_base_snapshot` JSON stored locally (the state at last successful sync)
- **Local** — current SQLite row
- **Server** — CKRecord returned by CloudKit

### Merge algorithm

For each field in the record:

1. Compare base vs local: did this device change the field?
2. Compare base vs server: did the other device change the field?
3. If only one side changed it → take that change
4. If both sides changed the same field → the side with the later `last_modified` wins
5. If timestamps are identical → server wins as tiebreaker

### Deletion conflicts

If one device deletes a record while another edits it, the delete wins. This prevents "zombie" records from reappearing and matches standard CloudKit behavior.

---

## 5. FFI Surface Changes

### New FFI functions

```
// Query pending changes
fn get_pending_sync_records(table_name: String) -> Vec<FfiSyncRecord>

// Mark rows as synced + save base snapshot
fn mark_records_synced(table_name: String, record_ids: Vec<i64>, base_snapshots: Vec<String>)

// Apply remote changes (upsert with merge)
fn apply_remote_records(table_name: String, records: Vec<FfiSyncRecord>) -> Vec<FfiMergeConflict>

// Get/set sync metadata
fn get_sync_metadata(key: String) -> Option<String>
fn set_sync_metadata(key: String, value: String)

// Get base snapshots for conflict resolution
fn get_base_snapshots(table_name: String, record_ids: Vec<i64>) -> Vec<FfiBaseSnapshot>

// Tombstone management
fn get_pending_tombstones() -> Vec<FfiTombstone>
fn clear_tombstones(ids: Vec<i64>)
```

### New FFI types

- **FfiSyncRecord** — `table_name: String`, `record_id: i64`, `fields: String` (JSON), `last_modified: String`
- **FfiMergeConflict** — `record_id: i64`, `resolved_fields: String` (JSON after merge)
- **FfiBaseSnapshot** — `record_id: i64`, `snapshot: String` (JSON)
- **FfiTombstone** — `id: i64`, `table_name: String`, `record_id: i64`, `deleted_at: String`

JSON strings for field data keep the FFI generic — one set of functions for all tables rather than per-table FFI functions.

---

## 6. App Integration & UX

### Entitlements & capabilities

- CloudKit capability with container `iCloud.com.toadmountain.autorota`
- Background modes: "Background fetch" and "Remote notifications" (CloudKit silent pushes)

### App launch flow (updated)

1. `autorotaInitDb()` — unchanged
2. Check `sync_metadata` for a `"sync_initialized"` key. If absent, this is first sync setup.
3. Perform a lightweight `CKFetchRecordZonesOperation` to check if `"AutorotaZone"` exists in the private database.
4. If zone exists (cloud data present) + local DB has no employees → prompt: "Your Autorota data was found on iCloud. Download it to this device?"
   - Accept → initialize `AutorotaSyncEngine`, perform full pull, set `"sync_initialized" = "true"` in `sync_metadata`
   - Decline → set `"sync_disabled" = "true"` in `sync_metadata`, operate locally only (reversible in Settings)
5. If zone doesn't exist or local DB has data → initialize `AutorotaSyncEngine` normally, set `"sync_initialized" = "true"`

### Sync status indicator

Small icon in Settings tab or navigation bar:
- Checkmark: synced
- Spinner: syncing
- Exclamation: error (tappable for details)

### Error handling

| Scenario | Behavior |
|----------|----------|
| Network unavailable | Changes queue locally, sync resumes automatically |
| CloudKit quota exceeded | One-time alert, continue locally |
| iCloud account not signed in | Full offline operation, sync activates when account available |
| Partial push failure | CKSyncEngine retries automatically |

### What's NOT synced

- UserDefaults / AppStorage (appearance, currency, tab layout, export prefs)
- Exchange rate cache
- Local UI state
