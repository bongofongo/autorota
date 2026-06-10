/// FFI-safe mirror types for all autorota-core models.
///
/// Chrono types are flattened to `String`:
///   - NaiveDate  → "YYYY-MM-DD"
///   - NaiveTime  → "HH:MM"
///   - Weekday    → "Mon" | "Tue" | "Wed" | "Thu" | "Fri" | "Sat" | "Sun"
///
/// `Availability` (HashMap<(Weekday,u8), AvailabilityState>) becomes `Vec<AvailabilitySlot>`.

// ── Role ─────────────────────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiRole {
    pub id: i64,
    pub name: String,
}

// ── Availability ─────────────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct AvailabilitySlot {
    pub weekday: String,
    pub hour: u8,
    /// "Yes" | "Maybe" | "No"
    pub state: String,
}

// ── Employee ──────────────────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiEmployee {
    pub id: i64,
    pub first_name: String,
    pub last_name: String,
    pub nickname: Option<String>,
    /// Computed display name: nickname if set, otherwise "first_name last_name".
    /// This field is ignored when creating/updating employees; Rust recomputes it.
    pub display_name: String,
    pub roles: Vec<String>,
    pub start_date: String,
    pub target_weekly_hours: f32,
    pub weekly_hours_deviation: f32,
    pub max_daily_hours: f32,
    pub notes: Option<String>,
    pub bank_details: Option<String>,
    pub phone: Option<String>,
    pub email: Option<String>,
    /// `"imessage"` | `"whatsapp"` | `"email"` | `None` (unspecified).
    pub preferred_contact: Option<String>,
    pub hourly_wage: Option<f32>,
    /// Currency code for the wage (e.g. "usd", "gbp", "eur").
    pub wage_currency: Option<String>,
    pub default_availability: Vec<AvailabilitySlot>,
    pub availability: Vec<AvailabilitySlot>,
    pub deleted: bool,
}

// ── Role requirement (multi-role shifts) ──────────────────────────────────────

/// A per-role staffing minimum on a shift or template: at least `min_count`
/// assigned employees must hold `role`. One employee covers one unit of each
/// required role they hold.
#[derive(Clone, uniffi::Record)]
pub struct FfiRoleRequirement {
    pub role: String,
    pub min_count: u32,
}

// ── Shift Template ────────────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiShiftTemplate {
    pub id: i64,
    pub name: String,
    pub weekdays: Vec<String>,
    pub start_time: String,
    pub end_time: String,
    pub required_role: String,
    pub min_employees: u32,
    pub max_employees: u32,
    /// Per-role minimums. Empty ⇒ wildcard (any available staff).
    pub role_requirements: Vec<FfiRoleRequirement>,
    pub deleted: bool,
}

// ── Shift ─────────────────────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiShift {
    pub id: i64,
    pub template_id: Option<i64>,
    pub rota_id: i64,
    pub date: String,
    pub start_time: String,
    pub end_time: String,
    pub required_role: String,
    pub min_employees: u32,
    pub max_employees: u32,
    /// Per-role minimums. Empty ⇒ wildcard (any available staff).
    pub role_requirements: Vec<FfiRoleRequirement>,
}

// ── Assignment ────────────────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiAssignment {
    pub id: i64,
    pub rota_id: i64,
    pub shift_id: i64,
    pub employee_id: i64,
    /// "Proposed" | "Confirmed" | "Overridden"
    pub status: String,
    pub employee_name: Option<String>,
    /// Snapshot of the employee's hourly wage at assignment time.
    pub hourly_wage: Option<f32>,
}

// ── Rota ──────────────────────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiRota {
    pub id: i64,
    pub week_start: String,
    pub assignments: Vec<FfiAssignment>,
}

// ── WeekSchedule (denormalised view returned by get_week_schedule) ────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiScheduleEntry {
    pub assignment_id: i64,
    pub shift_id: i64,
    pub date: String,
    pub weekday: String,
    pub start_time: String,
    pub end_time: String,
    pub required_role: String,
    pub employee_id: i64,
    pub employee_name: String,
    pub status: String,
    pub max_employees: u32,
}

#[derive(Clone, uniffi::Record)]
pub struct FfiShiftInfo {
    pub id: i64,
    pub date: String,
    pub weekday: String,
    pub start_time: String,
    pub end_time: String,
    pub required_role: String,
    pub min_employees: u32,
    pub max_employees: u32,
    /// Per-role minimums. Empty ⇒ wildcard (any available staff).
    pub role_requirements: Vec<FfiRoleRequirement>,
}

#[derive(Clone, uniffi::Record)]
pub struct FfiWeekSchedule {
    pub rota_id: i64,
    pub week_start: String,
    /// Whether this rota has at least one save.
    pub has_saves: bool,
    pub entries: Vec<FfiScheduleEntry>,
    pub shifts: Vec<FfiShiftInfo>,
}

// ── Scheduler Result ──────────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiShortfallWarning {
    pub shift_id: i64,
    pub needed: u32,
    pub filled: u32,
    pub weekday: String,
    pub start_time: String,
    pub end_time: String,
    pub required_role: String,
    /// Which role fell short, or `None` for an overall headcount shortfall.
    pub role: Option<String>,
}

#[derive(Clone, uniffi::Record)]
pub struct FfiScheduleResult {
    pub assignments: Vec<FfiAssignment>,
    pub warnings: Vec<FfiShortfallWarning>,
}

// ── Employee Shift History ────────────────────────────────────────────────────

/// A denormalised record for one of an employee's assigned shifts,
/// used to build the shift-history view.
#[derive(Clone, uniffi::Record)]
pub struct FfiEmployeeShiftRecord {
    pub assignment_id: i64,
    pub rota_id: i64,
    pub shift_id: i64,
    pub employee_id: i64,
    /// "Proposed" | "Confirmed" | "Overridden"
    pub status: String,
    pub employee_name: Option<String>,
    /// Snapshot of the employee's hourly wage at assignment time.
    pub hourly_wage: Option<f32>,
    /// Pre-computed shift cost (hourly_wage × duration_hours), None if no wage set.
    pub shift_cost: Option<f32>,
    /// "YYYY-MM-DD"
    pub date: String,
    /// "Mon" | "Tue" | … | "Sun"
    pub weekday: String,
    /// "HH:MM"
    pub start_time: String,
    /// "HH:MM"
    pub end_time: String,
    pub required_role: String,
    /// Pre-computed shift duration in hours (handles overnight shifts).
    pub duration_hours: f32,
    /// "YYYY-MM-DD" — Monday of the rota week this shift belongs to.
    pub week_start: String,
}

// ── Saves ──────────────────────────────────────────────────────────────────────

/// Result of comparing a live shift against the latest save snapshot.
#[derive(Clone, uniffi::Record)]
pub struct FfiShiftDiff {
    pub shift_id: i64,
    /// Shift exists in live schedule but not in any save.
    pub is_new: bool,
    /// Shift exists in both but differs (times, role, capacity, or assignments).
    pub is_changed: bool,
}

/// A save record (for list views — excludes the full snapshot JSON).
#[derive(Clone, uniffi::Record)]
pub struct FfiSave {
    pub id: i64,
    pub rota_id: i64,
    pub saved_at: String,
    pub summary: String,
    /// User-assigned tags for this save, ordered by insertion.
    pub tags: Vec<String>,
    /// Denormalized from the rota for display convenience.
    pub week_start: String,
    /// RFC3339 timestamp set when the user restored to this save. Drives the
    /// red "Restored" badge and promotes the entry to the top of its week.
    pub restored_at: Option<String>,
}

/// A save record with the full snapshot JSON (for detail views).
#[derive(Clone, uniffi::Record)]
pub struct FfiSaveDetail {
    pub id: i64,
    pub rota_id: i64,
    pub saved_at: String,
    pub summary: String,
    pub tags: Vec<String>,
    pub week_start: String,
    pub snapshot_json: String,
    pub restored_at: Option<String>,
}

/// One detailed change attached to a shift on a specific date.
///
/// Flattened shape so uniffi records cross the FFI cleanly across all
/// languages. The `kind` string selects which other fields are meaningful.
/// See `autorota_core::models::save::ChangeKind` for the full list.
///
/// Kind values:
/// - `"shift_added"` — new_* fields populated
/// - `"shift_removed"` — old_* fields populated
/// - `"shift_time_changed"` — old_start_time, new_start_time, old_end_time, new_end_time
/// - `"shift_capacity_changed"` — old_min_employees, new_min_employees, old/new_max_employees
/// - `"shift_role_changed"` — old_required_role, new_required_role
/// - `"assignment_added"` — employee_id, employee_name
/// - `"assignment_removed"` — employee_id, employee_name
/// - `"assignment_status_changed"` — employee_id, employee_name, old_status, new_status
/// - `"employee_moved"` — employee_id, employee_name, from_shift_id, from_start_time, from_end_time
#[derive(Clone, uniffi::Record)]
pub struct FfiChangeDetail {
    pub kind: String,
    pub shift_id: i64,
    /// `"YYYY-MM-DD"` — date of the shift this change is attached to.
    pub date: String,

    // Shift fields
    pub old_start_time: Option<String>,
    pub new_start_time: Option<String>,
    pub old_end_time: Option<String>,
    pub new_end_time: Option<String>,
    pub old_required_role: Option<String>,
    pub new_required_role: Option<String>,
    pub old_min_employees: Option<u32>,
    pub new_min_employees: Option<u32>,
    pub old_max_employees: Option<u32>,
    pub new_max_employees: Option<u32>,

    // Assignment fields
    pub employee_id: Option<i64>,
    pub employee_name: Option<String>,
    pub old_status: Option<String>,
    pub new_status: Option<String>,

    // Move fields (destination shift_id is on the top-level `shift_id`)
    pub from_shift_id: Option<i64>,
    pub from_start_time: Option<String>,
    pub from_end_time: Option<String>,
}

/// Summary returned by `restore_to_save`.
#[derive(Clone, uniffi::Record)]
pub struct FfiRestoreResult {
    pub rota_id: i64,
    pub shifts_restored: u32,
    pub assignments_restored: u32,
    /// Assignments in the snapshot that were skipped because the referenced
    /// employee no longer exists (has been deleted since the save).
    pub assignments_skipped: u32,
}

// ── Overrides ─────────────────────────────────────────────────────────────────

/// A single hour slot in a `DayAvailability` override (no weekday — the date carries that).
#[derive(Clone, uniffi::Record)]
pub struct DayAvailabilitySlot {
    pub hour: u8,
    /// "Yes" | "Maybe" | "No"
    pub state: String,
}

/// Date-specific availability override for one employee on one calendar date.
#[derive(Clone, uniffi::Record)]
pub struct FfiEmployeeAvailabilityOverride {
    pub id: i64,
    pub employee_id: i64,
    /// "YYYY-MM-DD"
    pub date: String,
    pub availability: Vec<DayAvailabilitySlot>,
    pub notes: Option<String>,
    /// "manual" | "exception". Exception rows appear in the Exceptions
    /// UI; manual rows are per-date edits via the availability grid and
    /// do not.
    pub source: String,
}

// ── Export ────────────────────────────────────────────────────────────────────

/// Configuration for exporting a week schedule.
#[derive(Clone, uniffi::Record)]
pub struct FfiExportConfig {
    /// "employee_by_weekday" | "shift_by_weekday"
    pub layout: String,
    /// "csv" | "json" | "pdf"
    pub format: String,
    /// "staff_schedule" | "manager_report"
    pub profile: String,
    pub show_shift_name: bool,
    pub show_times: bool,
    pub show_role: bool,
    /// "weekly_grid" | "per_employee" | "by_role".
    /// Only consulted when `format == "pdf"`. `None` → `weekly_grid`.
    pub pdf_template: Option<String>,
    /// Ordered role names; when non-empty the export is split into one
    /// stacked table/sheet per role (custom layouts). `None`/empty = single
    /// table.
    pub role_sections: Option<Vec<String>>,
    /// Row-header content for "shift_by_weekday" custom layouts. `None`
    /// keeps the legacy row label.
    pub row_content: Option<FfiRowContent>,
}

/// Which fields a custom layout shows in the row-header column.
#[derive(Clone, uniffi::Record)]
pub struct FfiRowContent {
    pub show_shift_name: bool,
    pub show_times: bool,
    pub show_role: bool,
}

/// Configuration for exporting a single employee's schedule.
#[derive(Clone, uniffi::Record)]
pub struct FfiEmployeeExportConfig {
    pub employee_id: i64,
    /// "YYYY-MM-DD"
    pub start_date: String,
    /// "YYYY-MM-DD"
    pub end_date: String,
    /// "csv" | "json" | "pdf" | "xlsx" | "markdown" | "ics"
    pub format: String,
    /// "staff_schedule" | "manager_report"
    pub profile: String,
    pub show_shift_name: bool,
    pub show_times: bool,
    pub show_role: bool,
    /// IANA timezone identifier (e.g. "Europe/London"). Only consulted when
    /// `format == "ics"`; `None` = floating local times.
    pub timezone_id: Option<String>,
}

/// Result of an export operation.
#[derive(Clone, uniffi::Record)]
pub struct FfiExportResult {
    pub data: String,
    pub filename: String,
    pub mime_type: String,
}

// ── Sync ──────────────────────────────────────────────────────────────────────

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

// ── Availability Progress ────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiAvailabilityProgress {
    pub employee_id: i64,
    pub done: bool,
}

/// Date-specific modification to a recurring shift template on one calendar date.
#[derive(Clone, uniffi::Record)]
pub struct FfiShiftTemplateOverride {
    pub id: i64,
    pub template_id: i64,
    /// "YYYY-MM-DD"
    pub date: String,
    pub cancelled: bool,
    /// "HH:MM" or None (use template value)
    pub start_time: Option<String>,
    /// "HH:MM" or None (use template value)
    pub end_time: Option<String>,
    pub min_employees: Option<u32>,
    pub max_employees: Option<u32>,
    pub notes: Option<String>,
}

// ── Roster Import ────────────────────────────────────────────────────────────

/// One row from a parsed roster file, annotated with diff state.
#[derive(Clone, uniffi::Record)]
pub struct FfiParsedEmployeeRow {
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
    /// `Some(id)` → UPDATE, `None` → INSERT.
    pub match_existing_id: Option<i64>,
    /// Human-readable summary: "NEW", "UPDATE: phone 555→777", "NO CHANGE",
    /// "AMBIGUOUS — requires manual review".
    pub diff_summary: String,
    /// Set by the Rust layer to a sensible default (true for NEW/UPDATE,
    /// false for NO CHANGE / AMBIGUOUS). UI toggles per row before applying.
    pub include: bool,
}

#[derive(Clone, uniffi::Record)]
pub struct FfiParsedRoster {
    pub rows: Vec<FfiParsedEmployeeRow>,
    pub warnings: Vec<String>,
}

#[derive(Clone, uniffi::Record)]
pub struct FfiImportSummary {
    pub inserted: u32,
    pub updated: u32,
    pub skipped: u32,
}
