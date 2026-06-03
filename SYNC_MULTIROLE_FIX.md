# Fix: iCloud sync for multi-role shift requirements

## Problem

The multi-role shifts feature (see `ROTA_REDESIGN_PLAN.md` Feature 2) stores per-role
minimums in two child tables — `shift_role_requirements` and
`template_role_requirements` (migration `024_shift_role_requirements.sql`). These
tables were added **without** the sync columns (`last_modified`, `sync_status`,
`sync_base_snapshot`) that every synced domain table carries (migration
`011_sync_support.sql`), and they are **not** listed in
`queries::syncable_columns`. Consequently:

- Role requirements never push to CloudKit and never pull from it.
- On a second device, a multi-role shift/template arrives with an **empty**
  requirement list → it is treated as a **wildcard** (any staff), silently
  changing scheduling behaviour and staffing intent.

The parent `required_role` column *is* synced (it's a denormalised "primary
role"), so the shift still shows a single role after sync, but the real
multi-role constraints are lost.

## Chosen approach — serialise the list into one synced JSON column

Rather than make the two child tables first-class sync entities (which needs
sync columns, tombstones, a `SyncRecordMapper` record type, and parent→child
ordering for each), store the requirement list as a **single denormalised JSON
column on the parent row** and let it ride the existing per-field pipeline.

Why this is the minimal, low-risk path:

- `queries::apply_remote_record` (`db/queries.rs:2505`) is **generic**: it
  `UPDATE`/`INSERT`s every column from `syncable_columns(table)` via
  `json_extract(?, '$.col')`. Adding a column to that list makes it sync
  automatically.
- `queries::get_pending_sync_records` builds `json_object(...)` from the same
  `syncable_columns`, so push is automatic too.
- The Swift layer (`SyncRecordMapper`, `AutorotaSyncEngine`,
  `SyncConflictResolver`) is **field-agnostic** — it round-trips an opaque
  `fields` JSON dict to/from `CKRecord`. **No Swift changes required.**

The child tables remain the source of truth for scheduling/queries; the JSON
column is a sync-only mirror, kept consistent at the two write points and
re-materialised on apply.

## Implementation

### 1. Migration `025_role_requirements_sync.sql`

```sql
-- Sync-only mirror of the role-requirement child tables. Rides the existing
-- per-field sync pipeline (see syncable_columns / apply_remote_record).
ALTER TABLE shifts          ADD COLUMN role_requirements_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE shift_templates ADD COLUMN role_requirements_json TEXT NOT NULL DEFAULT '[]';

-- Backfill from the child tables created in migration 024. SQLite >= 3.38 has
-- json_group_array / json_object (bundled with the app's SQLite).
UPDATE shifts
SET role_requirements_json = COALESCE((
    SELECT json_group_array(json_object('role', role, 'min_count', min_count))
    FROM shift_role_requirements WHERE shift_id = shifts.id
), '[]');

UPDATE shift_templates
SET role_requirements_json = COALESCE((
    SELECT json_group_array(json_object('role', role, 'min_count', min_count))
    FROM template_role_requirements WHERE template_id = shift_templates.id
), '[]');
```

Register it in the hand-rolled migrator `db/mod.rs::run_migrations` following the
existing guard pattern (mirror the migration-024 block):

```rust
// Migration 025: sync mirror column for role requirements.
let has_rr_json: bool = sqlx::query_scalar(
    "SELECT COUNT(*) > 0 FROM pragma_table_info('shifts') WHERE name = 'role_requirements_json'",
)
.fetch_one(pool)
.await?;
if !has_rr_json {
    let m25 = include_str!("../../migrations/025_role_requirements_sync.sql");
    run_migration_tx(pool, m25).await?;
}
```

### 2. Serialize helper (`db/queries.rs`)

```rust
fn role_requirements_to_json(reqs: &[RoleRequirement]) -> String {
    serde_json::to_string(reqs).unwrap_or_else(|_| "[]".to_string())
}

fn role_requirements_from_json(s: &str) -> Vec<RoleRequirement> {
    serde_json::from_str(s).unwrap_or_default()
}
```

`RoleRequirement` already derives `Serialize`/`Deserialize` with fields
`role` + `min_count`, matching the JSON shape above.

### 3. Write the mirror column wherever requirements change

Both setters already rewrite the parent's `required_role` and bump
`sync_status = 0`. Extend them to also write `role_requirements_json`
(`db/queries.rs`, `set_shift_role_requirements` / `set_template_role_requirements`):

```rust
sqlx::query("UPDATE shifts SET required_role = ?, role_requirements_json = ?, sync_status = 0, last_modified = ? WHERE id = ?")
    .bind(primary_role(reqs))
    .bind(role_requirements_to_json(reqs))
    .bind(chrono::Utc::now().to_rfc3339())
    .bind(shift_id)
    .execute(pool).await?;
```

(Analogously for `shift_templates`/`template_id`. Note: bump `last_modified` so
push ordering / LWW fallback works — the current setters only set
`sync_status`.)

### 4. Add the column to the sync field set

In `queries::syncable_columns` (`db/queries.rs`), append `"role_requirements_json"`
to the `"shifts"` and `"shift_templates"` arms. Push + apply now carry it
automatically.

### 5. Re-materialise child rows after apply

`apply_remote_record` writes the column generically but knows nothing about the
child tables. Add a table-specific post-step at the end of `apply_remote_record`
(after the UPDATE/INSERT, before `Ok(())`), guarded so it does **not** reset
`sync_status` (apply intentionally set it to `1`):

```rust
// Re-materialise role-requirement child rows from the synced JSON mirror so
// scheduling queries (which read the child tables) stay correct. Writes the
// child tables directly — must NOT go through set_*_role_requirements, which
// would bump sync_status back to 0 and re-push.
match record.table_name.as_str() {
    "shifts" => {
        let json: Option<String> = sqlx::query_scalar(
            "SELECT role_requirements_json FROM shifts WHERE id = ?",
        ).bind(record.record_id).fetch_optional(pool).await?.flatten();
        if let Some(j) = json {
            let reqs = role_requirements_from_json(&j);
            replace_role_requirements(pool, "shift_role_requirements", "shift_id", record.record_id, &reqs).await?;
        }
    }
    "shift_templates" => {
        let json: Option<String> = sqlx::query_scalar(
            "SELECT role_requirements_json FROM shift_templates WHERE id = ?",
        ).bind(record.record_id).fetch_optional(pool).await?.flatten();
        if let Some(j) = json {
            let reqs = role_requirements_from_json(&j);
            replace_role_requirements(pool, "template_role_requirements", "template_id", record.record_id, &reqs).await?;
        }
    }
    _ => {}
}
```

`replace_role_requirements` already exists (the private delete-then-insert
helper). Use it directly — **not** the public `set_*` wrappers — to avoid
flipping `sync_status` back to `0`.

### 6. Conflict-merge behaviour (document, no code)

`SyncConflictResolver.merge` does three-way per-field merge. The requirement
list is **one opaque string field**, so it resolves as a unit:

- base == local, server changed → take server (and vice-versa).
- both changed differently → server wins for that field (per the resolver's
  existing per-field policy), i.e. the whole list is last-writer-wins.

This is acceptable: requirement lists are small and edited rarely. Per-element
merge (e.g. device A adds "opening", device B bumps "barista" to 2) is **not**
supported and is a deliberate non-goal. Note it in the resolver doc comment.

## What needs NO change

- Swift: `SyncRecordMapper`, `AutorotaSyncEngine`, `SyncConflictResolver`,
  `SyncRecordMapper.recordType` — all field-agnostic.
- FFI: `apply_remote_record` / `get_pending_sync_records` are already exported and
  generic over `syncable_columns`.
- CloudKit schema: the dev environment auto-creates the new string field on
  first push; for production, add `role_requirements_json` (String) to the
  `Shift` and `ShiftTemplate` record types before shipping.

## Test plan

Rust (`tests/db_integration.rs`, mirror existing sync tests):

1. **Push:** insert a shift with two requirements → assert
   `get_pending_sync_records("shifts")` includes `role_requirements_json` with
   both entries; assert `required_role` == primary role.
2. **Apply round-trip:** take a `SyncRecord` whose `fields` JSON sets
   `role_requirements_json` to `[{"role":"barista","min_count":2}]`, call
   `apply_remote_record`, then `list_shifts_for_rota` → assert the child rows
   were re-materialised and `sync_status == 1` (not re-pushed).
3. **Apply clears to wildcard:** apply a record with `role_requirements_json ==
   "[]"` → assert child rows removed and the shift behaves as wildcard.
4. **Migration backfill:** seed a pre-025 DB (child rows present, no JSON
   column) through `run_migrations` → assert `role_requirements_json` matches the
   child rows.

Swift: existing `SyncConflictResolverTests` / `SyncRecordMapper` tests need no
additions (opaque field), but add one resolver case asserting a changed
`role_requirements_json` server value wins over an unchanged base.

## File checklist

- `crates/autorota-core/migrations/025_role_requirements_sync.sql` *(new)*
- `crates/autorota-core/src/db/mod.rs` — register migration 025
- `crates/autorota-core/src/db/queries.rs` — `role_requirements_to_json` /
  `_from_json`, write mirror in `set_shift_role_requirements` /
  `set_template_role_requirements`, add column to `syncable_columns`, re-materialise
  in `apply_remote_record`
- `platforms/apple/Apps/AutorotaApp/Services/SyncConflictResolver.swift` — doc
  comment on whole-list LWW (optional)
- Tests: `crates/autorota-core/tests/db_integration.rs`
- CloudKit dashboard: add `role_requirements_json` String field to `Shift` and
  `ShiftTemplate` record types before production release.
```
