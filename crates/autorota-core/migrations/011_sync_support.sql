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
