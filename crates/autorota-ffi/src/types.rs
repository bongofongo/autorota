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
    pub default_availability: Vec<AvailabilitySlot>,
    pub availability: Vec<AvailabilitySlot>,
    pub deleted: bool,
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
}

// ── Rota ──────────────────────────────────────────────────────────────────────

#[derive(Clone, uniffi::Record)]
pub struct FfiRota {
    pub id: i64,
    pub week_start: String,
    pub assignments: Vec<FfiAssignment>,
    pub finalized: bool,
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
}

#[derive(Clone, uniffi::Record)]
pub struct FfiWeekSchedule {
    pub rota_id: i64,
    pub week_start: String,
    pub finalized: bool,
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
}

#[derive(Clone, uniffi::Record)]
pub struct FfiScheduleResult {
    pub assignments: Vec<FfiAssignment>,
    pub warnings: Vec<FfiShortfallWarning>,
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
