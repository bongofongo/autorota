mod error;
mod types;

use std::sync::OnceLock;

use autorota_core::db::{self, queries};
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::{Availability, AvailabilityState};
use autorota_core::models::employee::Employee;
use autorota_core::models::rota::Rota;
use autorota_core::models::shift::{Shift, ShiftTemplate};
use chrono::{Datelike, Local, NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;
use tokio::runtime::Runtime;

pub use error::FfiError;
pub use types::*;

uniffi::setup_scaffolding!();

// ── Globals ───────────────────────────────────────────────────────────────────

static POOL: OnceLock<SqlitePool> = OnceLock::new();
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn rt() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("tokio runtime"))
}

fn pool() -> Result<&'static SqlitePool, FfiError> {
    POOL.get()
        .ok_or_else(|| FfiError::Db { msg: "database not initialized — call initDb first".into() })
}

// ── String ↔ chrono conversions ───────────────────────────────────────────────

fn parse_date(s: &str) -> Result<NaiveDate, FfiError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .map_err(|e| FfiError::InvalidArgument { msg: format!("invalid date '{s}': {e}") })
}

fn parse_time(s: &str) -> Result<NaiveTime, FfiError> {
    NaiveTime::parse_from_str(s, "%H:%M")
        .or_else(|_| NaiveTime::parse_from_str(s, "%H:%M:%S"))
        .map_err(|e| FfiError::InvalidArgument { msg: format!("invalid time '{s}': {e}") })
}

fn weekday_to_str(wd: Weekday) -> &'static str {
    match wd {
        Weekday::Mon => "Mon",
        Weekday::Tue => "Tue",
        Weekday::Wed => "Wed",
        Weekday::Thu => "Thu",
        Weekday::Fri => "Fri",
        Weekday::Sat => "Sat",
        Weekday::Sun => "Sun",
    }
}

fn weekday_from_str(s: &str) -> Result<Weekday, FfiError> {
    match s {
        "Mon" => Ok(Weekday::Mon),
        "Tue" => Ok(Weekday::Tue),
        "Wed" => Ok(Weekday::Wed),
        "Thu" => Ok(Weekday::Thu),
        "Fri" => Ok(Weekday::Fri),
        "Sat" => Ok(Weekday::Sat),
        "Sun" => Ok(Weekday::Sun),
        other => Err(FfiError::InvalidArgument { msg: format!("invalid weekday: {other}") }),
    }
}

// ── Availability conversion ───────────────────────────────────────────────────

fn availability_to_slots(avail: &Availability) -> Vec<AvailabilitySlot> {
    avail
        .0
        .iter()
        .map(|(&(wd, hour), &state)| AvailabilitySlot {
            weekday: weekday_to_str(wd).to_string(),
            hour,
            state: state.to_string(),
        })
        .collect()
}

fn slots_to_availability(slots: Vec<AvailabilitySlot>) -> Result<Availability, FfiError> {
    let mut avail = Availability::default();
    for slot in slots {
        let wd = weekday_from_str(&slot.weekday)?;
        let state = slot
            .state
            .parse::<AvailabilityState>()
            .map_err(|e| FfiError::InvalidArgument { msg: e })?;
        avail.set(wd, slot.hour, state);
    }
    Ok(avail)
}

// ── Employee conversions ──────────────────────────────────────────────────────

fn employee_to_ffi(e: Employee) -> FfiEmployee {
    FfiEmployee {
        id: e.id,
        name: e.name,
        roles: e.roles,
        start_date: e.start_date.to_string(),
        target_weekly_hours: e.target_weekly_hours,
        weekly_hours_deviation: e.weekly_hours_deviation,
        max_daily_hours: e.max_daily_hours,
        notes: e.notes,
        bank_details: e.bank_details,
        default_availability: availability_to_slots(&e.default_availability),
        availability: availability_to_slots(&e.availability),
        deleted: e.deleted,
    }
}

fn ffi_to_employee(e: FfiEmployee) -> Result<Employee, FfiError> {
    Ok(Employee {
        id: e.id,
        name: e.name,
        roles: e.roles,
        start_date: parse_date(&e.start_date)?,
        target_weekly_hours: e.target_weekly_hours,
        weekly_hours_deviation: e.weekly_hours_deviation,
        max_daily_hours: e.max_daily_hours,
        notes: e.notes,
        bank_details: e.bank_details,
        default_availability: slots_to_availability(e.default_availability)?,
        availability: slots_to_availability(e.availability)?,
        deleted: e.deleted,
    })
}

// ── ShiftTemplate conversions ─────────────────────────────────────────────────

fn shift_template_to_ffi(t: ShiftTemplate) -> FfiShiftTemplate {
    FfiShiftTemplate {
        id: t.id,
        name: t.name,
        weekdays: t.weekdays.iter().map(|&wd| weekday_to_str(wd).to_string()).collect(),
        start_time: t.start_time.format("%H:%M").to_string(),
        end_time: t.end_time.format("%H:%M").to_string(),
        required_role: t.required_role,
        min_employees: t.min_employees,
        max_employees: t.max_employees,
        deleted: t.deleted,
    }
}

fn ffi_to_shift_template(t: FfiShiftTemplate) -> Result<ShiftTemplate, FfiError> {
    let weekdays = t
        .weekdays
        .iter()
        .map(|s| weekday_from_str(s))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ShiftTemplate {
        id: t.id,
        name: t.name,
        weekdays,
        start_time: parse_time(&t.start_time)?,
        end_time: parse_time(&t.end_time)?,
        required_role: t.required_role,
        min_employees: t.min_employees,
        max_employees: t.max_employees,
        deleted: t.deleted,
    })
}

// ── Shift conversion ──────────────────────────────────────────────────────────

fn shift_to_ffi(s: Shift) -> FfiShift {
    FfiShift {
        id: s.id,
        template_id: s.template_id,
        rota_id: s.rota_id,
        date: s.date.to_string(),
        start_time: s.start_time.format("%H:%M").to_string(),
        end_time: s.end_time.format("%H:%M").to_string(),
        required_role: s.required_role,
        min_employees: s.min_employees,
        max_employees: s.max_employees,
    }
}

// ── Assignment conversions ────────────────────────────────────────────────────

fn assignment_to_ffi(a: Assignment) -> FfiAssignment {
    FfiAssignment {
        id: a.id,
        rota_id: a.rota_id,
        shift_id: a.shift_id,
        employee_id: a.employee_id,
        status: a.status.to_string(),
        employee_name: a.employee_name,
    }
}

fn ffi_to_assignment(a: FfiAssignment) -> Result<Assignment, FfiError> {
    Ok(Assignment {
        id: a.id,
        rota_id: a.rota_id,
        shift_id: a.shift_id,
        employee_id: a.employee_id,
        status: a
            .status
            .parse::<AssignmentStatus>()
            .map_err(|e| FfiError::InvalidArgument { msg: e })?,
        employee_name: a.employee_name,
    })
}

// ── Rota conversion ───────────────────────────────────────────────────────────

fn rota_to_ffi(r: Rota) -> FfiRota {
    FfiRota {
        id: r.id,
        week_start: r.week_start.to_string(),
        assignments: r.assignments.into_iter().map(assignment_to_ffi).collect(),
        finalized: r.finalized,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exported API
// ─────────────────────────────────────────────────────────────────────────────

// ── Init ──────────────────────────────────────────────────────────────────────

/// Initialise the SQLite connection pool.
/// `db_path` is the filesystem path to the .db file (not a URL).
/// Must be called once before any other function.
#[uniffi::export]
pub fn init_db(db_path: String) -> Result<(), FfiError> {
    let url = format!("sqlite:{db_path}");
    let pool = rt()
        .block_on(db::connect(&url))
        .map_err(|e| FfiError::Db { msg: e.to_string() })?;
    POOL.set(pool)
        .map_err(|_| FfiError::Db { msg: "database already initialized".into() })
}

// ── Employees ─────────────────────────────────────────────────────────────────

#[uniffi::export]
pub fn list_employees() -> Result<Vec<FfiEmployee>, FfiError> {
    let pool = pool()?;
    let rows = rt()
        .block_on(queries::list_employees(pool))
        .map_err(FfiError::from)?;
    Ok(rows.into_iter().map(employee_to_ffi).collect())
}

#[uniffi::export]
pub fn get_employee(id: i64) -> Result<Option<FfiEmployee>, FfiError> {
    let pool = pool()?;
    let row = rt()
        .block_on(queries::get_employee(pool, id))
        .map_err(FfiError::from)?;
    Ok(row.map(employee_to_ffi))
}

#[uniffi::export]
pub fn create_employee(employee: FfiEmployee) -> Result<i64, FfiError> {
    let pool = pool()?;
    let core = ffi_to_employee(employee)?;
    rt().block_on(queries::insert_employee(pool, &core))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn update_employee(employee: FfiEmployee) -> Result<(), FfiError> {
    let pool = pool()?;
    let core = ffi_to_employee(employee)?;
    rt().block_on(queries::update_employee(pool, &core))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn delete_employee(id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::delete_employee(pool, id))
        .map_err(FfiError::from)
}

// ── Shift Templates ───────────────────────────────────────────────────────────

#[uniffi::export]
pub fn list_shift_templates() -> Result<Vec<FfiShiftTemplate>, FfiError> {
    let pool = pool()?;
    let rows = rt()
        .block_on(queries::list_shift_templates(pool))
        .map_err(FfiError::from)?;
    Ok(rows.into_iter().map(shift_template_to_ffi).collect())
}

#[uniffi::export]
pub fn create_shift_template(template: FfiShiftTemplate) -> Result<i64, FfiError> {
    let pool = pool()?;
    let core = ffi_to_shift_template(template)?;
    rt().block_on(queries::insert_shift_template(pool, &core))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn update_shift_template(template: FfiShiftTemplate) -> Result<(), FfiError> {
    let pool = pool()?;
    let core = ffi_to_shift_template(template)?;
    rt().block_on(queries::update_shift_template(pool, &core))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn delete_shift_template(id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::delete_shift_template(pool, id))
        .map_err(FfiError::from)
}

// ── Rotas ─────────────────────────────────────────────────────────────────────

#[uniffi::export]
pub fn get_rota(id: i64) -> Result<Option<FfiRota>, FfiError> {
    let pool = pool()?;
    let row = rt()
        .block_on(queries::get_rota(pool, id))
        .map_err(FfiError::from)?;
    Ok(row.map(rota_to_ffi))
}

#[uniffi::export]
pub fn get_rota_by_week(week_start: String) -> Result<Option<FfiRota>, FfiError> {
    let pool = pool()?;
    let date = parse_date(&week_start)?;
    let row = rt()
        .block_on(queries::get_rota_by_week(pool, date))
        .map_err(FfiError::from)?;
    Ok(row.map(rota_to_ffi))
}

#[uniffi::export]
pub fn create_rota(week_start: String) -> Result<i64, FfiError> {
    let pool = pool()?;
    let date = parse_date(&week_start)?;
    rt().block_on(queries::insert_rota(pool, date))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn finalize_rota(id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::finalize_rota(pool, id))
        .map_err(FfiError::from)
}

// ── Assignments ───────────────────────────────────────────────────────────────

#[uniffi::export]
pub fn create_assignment(mut assignment: FfiAssignment) -> Result<i64, FfiError> {
    let pool = pool()?;
    // Snapshot employee name if missing
    if assignment.employee_name.is_none() {
        if let Some(emp) = rt()
            .block_on(queries::get_employee(pool, assignment.employee_id))
            .map_err(FfiError::from)?
        {
            assignment.employee_name = Some(emp.name);
        }
    }
    let core = ffi_to_assignment(assignment)?;
    rt().block_on(queries::insert_assignment(pool, &core))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn update_assignment_status(id: i64, status: String) -> Result<(), FfiError> {
    let pool = pool()?;
    let s = status
        .parse::<AssignmentStatus>()
        .map_err(|e| FfiError::InvalidArgument { msg: e })?;
    rt().block_on(queries::update_assignment_status(pool, id, s))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn move_assignment(id: i64, new_shift_id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(async {
        // Fetch the assignment to get its rota_id
        let row = sqlx::query_as::<_, (i64, i64, i64, i64, String, Option<String>)>(
            "SELECT id, rota_id, shift_id, employee_id, status, employee_name \
             FROM assignments WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| sqlx::Error::RowNotFound)?;

        let rota_id = row.1;

        // Validate target shift belongs to the same rota
        let target = sqlx::query_as::<_, (i64, i64, u32)>(
            "SELECT id, rota_id, max_employees FROM shifts WHERE id = ?",
        )
        .bind(new_shift_id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| sqlx::Error::RowNotFound)?;

        if target.1 != rota_id {
            return Err(sqlx::Error::Protocol(
                "target shift belongs to a different rota".into(),
            ));
        }

        // Check capacity
        let count: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM assignments WHERE shift_id = ?")
                .bind(new_shift_id)
                .fetch_one(pool)
                .await?;

        if count.0 >= target.2 as i64 {
            return Err(sqlx::Error::Protocol("target shift is at capacity".into()));
        }

        queries::update_assignment_shift(pool, id, new_shift_id).await
    })
    .map_err(FfiError::from)
}

#[uniffi::export]
pub fn swap_assignments(id_a: i64, id_b: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(async {
        let a = sqlx::query_as::<_, (i64, i64)>(
            "SELECT id, shift_id FROM assignments WHERE id = ?",
        )
        .bind(id_a)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| sqlx::Error::RowNotFound)?;

        let b = sqlx::query_as::<_, (i64, i64)>(
            "SELECT id, shift_id FROM assignments WHERE id = ?",
        )
        .bind(id_b)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| sqlx::Error::RowNotFound)?;

        queries::swap_assignment_shifts(pool, a.0, a.1, b.0, b.1).await
    })
    .map_err(FfiError::from)
}

#[uniffi::export]
pub fn delete_assignment(id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::delete_assignment(pool, id))
        .map_err(FfiError::from)
}

// ── Shifts ────────────────────────────────────────────────────────────────────

#[uniffi::export]
pub fn delete_shift(id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::delete_shift(pool, id))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn update_shift_times(id: i64, start_time: String, end_time: String) -> Result<(), FfiError> {
    let pool = pool()?;
    let start = parse_time(&start_time)?;
    let end = parse_time(&end_time)?;
    rt().block_on(queries::update_shift_times(pool, id, start, end))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn create_ad_hoc_shift(
    rota_id: i64,
    date: String,
    start_time: String,
    end_time: String,
    required_role: String,
) -> Result<i64, FfiError> {
    let pool = pool()?;
    let shift = Shift {
        id: 0,
        template_id: None,
        rota_id,
        date: parse_date(&date)?,
        start_time: parse_time(&start_time)?,
        end_time: parse_time(&end_time)?,
        required_role,
        min_employees: 1,
        max_employees: 1,
    };
    rt().block_on(queries::insert_shift(pool, &shift))
        .map_err(FfiError::from)
}

// ── Week workflow ─────────────────────────────────────────────────────────────

/// Ensure a rota exists for the given week and materialise shifts from templates.
/// Returns the rota id. Safe to call multiple times.
#[uniffi::export]
pub fn materialise_week(week_start: String) -> Result<i64, FfiError> {
    let pool = pool()?;
    let date = parse_date(&week_start)?;
    let result: Result<i64, sqlx::Error> = rt().block_on(async move {
        match queries::get_rota_by_week(pool, date).await? {
            Some(existing) => Ok(existing.id),
            None => {
                let id = queries::insert_rota(pool, date).await?;
                queries::materialise_shifts(pool, id, date).await?;
                Ok(id)
            }
        }
    });
    result.map_err(|e| FfiError::Db { msg: e.to_string() })
}

/// Create/update a rota for the given week, re-materialise shifts, run the
/// scheduler, persist proposed assignments, and return the result.
#[uniffi::export]
pub fn run_schedule(week_start: String) -> Result<FfiScheduleResult, FfiError> {
    let pool = pool()?;
    let date = parse_date(&week_start)?;

    // Guard: only allow scheduling for future weeks (same logic as Tauri layer)
    let today = Local::now().date_naive();
    let current_monday =
        today - chrono::Duration::days(today.weekday().num_days_from_monday() as i64);
    if date <= current_monday {
        return Err(FfiError::InvalidArgument {
            msg: "cannot generate schedule for current or past weeks".into(),
        });
    }

    // Step 1: prepare rota (create/reuse, re-materialise shifts)
    let rota_id: Result<i64, sqlx::Error> = rt().block_on(async move {
        match queries::get_rota_by_week(pool, date).await? {
            Some(existing) => {
                if existing.finalized {
                    return Err(sqlx::Error::Protocol(
                        "this week's rota is already finalized".into(),
                    ));
                }
                queries::delete_proposed_assignments(pool, existing.id).await?;
                queries::delete_shifts_for_rota(pool, existing.id).await?;
                queries::materialise_shifts(pool, existing.id, date).await?;
                Ok(existing.id)
            }
            None => {
                let id = queries::insert_rota(pool, date).await?;
                queries::materialise_shifts(pool, id, date).await?;
                Ok(id)
            }
        }
    });
    let rota_id = rota_id.map_err(|e| FfiError::Db { msg: e.to_string() })?;

    // Step 2: run scheduler
    let result = rt()
        .block_on(autorota_core::scheduler::schedule(pool, rota_id))
        .map_err(|e| match e {
            autorota_core::scheduler::SchedulerError::AlreadyFinalized(_) => {
                FfiError::AlreadyFinalized
            }
            other => FfiError::Db { msg: other.to_string() },
        })?;

    Ok(FfiScheduleResult {
        assignments: result.assignments.into_iter().map(assignment_to_ffi).collect(),
        warnings: result
            .warnings
            .into_iter()
            .map(|w| FfiShortfallWarning {
                shift_id: w.shift_id,
                needed: w.needed,
                filled: w.filled,
                weekday: w.weekday,
                start_time: w.start_time,
                end_time: w.end_time,
                required_role: w.required_role,
            })
            .collect(),
    })
}

/// Return the full denormalised schedule for a week (shifts + assignments +
/// employee names). Returns `None` if no rota exists for that week yet.
#[uniffi::export]
pub fn get_week_schedule(week_start: String) -> Result<Option<FfiWeekSchedule>, FfiError> {
    let pool = pool()?;
    let date = parse_date(&week_start)?;

    let result: Result<Option<FfiWeekSchedule>, sqlx::Error> = rt().block_on(async move {
        let rota = match queries::get_rota_by_week(pool, date).await? {
            Some(r) => r,
            None => return Ok(None),
        };

        let shifts = queries::list_shifts_for_rota(pool, rota.id).await?;
        let employees = queries::list_all_employees(pool).await?;

        let emp_map: std::collections::HashMap<i64, &Employee> =
            employees.iter().map(|e| (e.id, e)).collect();

        let entries = rota
            .assignments
            .iter()
            .filter_map(|a| {
                let shift = shifts.iter().find(|s| s.id == a.shift_id)?;
                let employee_name = emp_map
                    .get(&a.employee_id)
                    .map(|e| e.name.clone())
                    .or_else(|| a.employee_name.clone())
                    .unwrap_or_else(|| format!("Employee #{}", a.employee_id));
                Some(FfiScheduleEntry {
                    assignment_id: a.id,
                    shift_id: shift.id,
                    date: shift.date.to_string(),
                    weekday: weekday_to_str(shift.date.weekday()).to_string(),
                    start_time: shift.start_time.format("%H:%M").to_string(),
                    end_time: shift.end_time.format("%H:%M").to_string(),
                    required_role: shift.required_role.clone(),
                    employee_id: a.employee_id,
                    employee_name,
                    status: a.status.to_string(),
                    max_employees: shift.max_employees,
                })
            })
            .collect();

        let shift_infos = shifts
            .iter()
            .map(|s| FfiShiftInfo {
                id: s.id,
                date: s.date.to_string(),
                weekday: weekday_to_str(s.date.weekday()).to_string(),
                start_time: s.start_time.format("%H:%M").to_string(),
                end_time: s.end_time.format("%H:%M").to_string(),
                required_role: s.required_role.clone(),
                min_employees: s.min_employees,
                max_employees: s.max_employees,
            })
            .collect();

        Ok(Some(FfiWeekSchedule {
            rota_id: rota.id,
            week_start: rota.week_start.to_string(),
            finalized: rota.finalized,
            entries,
            shifts: shift_infos,
        }))
    });
    result.map_err(|e| FfiError::Db { msg: e.to_string() })
}

// ── Shift listing (useful for ad-hoc shift management) ────────────────────────

#[uniffi::export]
pub fn list_shifts_for_rota(rota_id: i64) -> Result<Vec<FfiShift>, FfiError> {
    let pool = pool()?;
    let rows = rt()
        .block_on(queries::list_shifts_for_rota(pool, rota_id))
        .map_err(FfiError::from)?;
    Ok(rows.into_iter().map(shift_to_ffi).collect())
}
