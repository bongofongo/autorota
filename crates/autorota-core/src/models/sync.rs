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
