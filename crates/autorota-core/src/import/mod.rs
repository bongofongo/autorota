//! Roster import: CSV / JSON / XLSX → preview with diff → apply in a single
//! transaction. Only the employee roster is supported; shifts, templates, and
//! assignments are out of scope (the user keeps those in-app).

pub mod roster;

use serde::{Deserialize, Serialize};

/// How to decide whether a parsed row matches an existing employee row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeStrategy {
    /// Match by `first_name + last_name + nickname`. Ambiguous matches warn
    /// and are treated as NEW (user must manually reconcile).
    Name,
    /// Never match existing rows; every parsed row becomes an INSERT. Useful
    /// for a brand-new database or a known-fresh supplier.
    InsertOnly,
}

impl std::str::FromStr for MergeStrategy {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "name" => Ok(Self::Name),
            "insert_only" => Ok(Self::InsertOnly),
            other => Err(format!("invalid merge strategy: {other}")),
        }
    }
}

/// One parsed row from the input file, annotated with diff state against the
/// current DB. The UI layer flips `include` per row before calling apply.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedEmployeeRow {
    pub first_name: String,
    pub last_name: String,
    pub nickname: Option<String>,
    pub phone: Option<String>,
    pub email: Option<String>,
    /// `"imessage"` | `"whatsapp"` | `"email"` | `None` (unspecified).
    pub preferred_contact: Option<String>,
    pub roles: Vec<String>,
    pub target_weekly_hours: Option<f32>,
    pub weekly_hours_deviation: Option<f32>,
    pub max_daily_hours: Option<f32>,
    pub hourly_wage: Option<f32>,
    pub wage_currency: Option<String>,
    pub notes: Option<String>,
    pub bank_details: Option<String>,
    /// Resolved from the merge strategy: `Some(id)` → UPDATE, `None` → INSERT.
    pub match_existing_id: Option<i64>,
    /// Human-readable single-line summary of the intended action ("NEW",
    /// "UPDATE: phone 555→777", "NO CHANGE", "AMBIGUOUS — manual review").
    pub diff_summary: String,
    /// Whether the UI has this row selected for application.
    pub include: bool,
}

/// The full parsed result, plus any warnings the parser emitted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedRoster {
    pub rows: Vec<ParsedEmployeeRow>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Copy)]
pub struct ImportSummary {
    pub inserted: u32,
    pub updated: u32,
    pub skipped: u32,
}
