use serde::{Deserialize, Serialize};

/// A shift that has been staged for commit but not yet committed.
#[derive(Debug, Clone)]
pub struct StagedShift {
    pub id: i64,
    pub shift_id: i64,
    pub rota_id: i64,
    pub staged_at: String,
}

/// A committed snapshot of shift/assignment data at a point in time.
#[derive(Debug, Clone)]
pub struct Commit {
    pub id: i64,
    pub rota_id: i64,
    pub committed_at: String,
    pub summary: String,
    pub snapshot_json: String,
}

// ── Snapshot JSON structure ──────────────────────────────────────────────────

/// Top-level snapshot stored as JSON in the `commits.snapshot_json` column.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitSnapshot {
    pub week_start: String,
    pub committed_shift_ids: Vec<i64>,
    pub shifts: Vec<CommitShiftSnapshot>,
    pub total_hours: f32,
    pub total_shifts: usize,
    pub unique_employees: usize,
}

/// Snapshot of a single shift within a commit.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitShiftSnapshot {
    pub shift_id: i64,
    pub date: String,
    pub start_time: String,
    pub end_time: String,
    pub required_role: String,
    pub min_employees: u32,
    pub max_employees: u32,
    pub assignments: Vec<CommitAssignmentSnapshot>,
}

/// Snapshot of a single assignment within a committed shift.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitAssignmentSnapshot {
    pub assignment_id: i64,
    pub employee_id: i64,
    pub employee_name: String,
    pub status: String,
    pub hourly_wage: Option<f32>,
    pub wage_currency: Option<String>,
}
