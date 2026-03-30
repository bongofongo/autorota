mod error;
mod types;

use std::sync::OnceLock;

use autorota_core::db::{self, queries};
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::{Availability, AvailabilityState};
use autorota_core::models::employee::Employee;
use autorota_core::models::overrides::{DayAvailability, EmployeeAvailabilityOverride, ShiftTemplateOverride};
use autorota_core::models::rota::Rota;
use autorota_core::models::shift::{Shift, ShiftTemplate};
use autorota_core::models::shift_history::EmployeeShiftRecord;
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
        display_name: e.display_name(),
        first_name: e.first_name,
        last_name: e.last_name,
        nickname: e.nickname,
        roles: e.roles,
        start_date: e.start_date.to_string(),
        target_weekly_hours: e.target_weekly_hours,
        weekly_hours_deviation: e.weekly_hours_deviation,
        max_daily_hours: e.max_daily_hours,
        notes: e.notes,
        bank_details: e.bank_details,
        hourly_wage: e.hourly_wage,
        wage_currency: e.wage_currency,
        default_availability: availability_to_slots(&e.default_availability),
        availability: availability_to_slots(&e.availability),
        deleted: e.deleted,
    }
}

fn ffi_to_employee(e: FfiEmployee) -> Result<Employee, FfiError> {
    Ok(Employee {
        id: e.id,
        first_name: e.first_name,
        last_name: e.last_name,
        nickname: e.nickname,
        roles: e.roles,
        start_date: parse_date(&e.start_date)?,
        target_weekly_hours: e.target_weekly_hours,
        weekly_hours_deviation: e.weekly_hours_deviation,
        max_daily_hours: e.max_daily_hours,
        notes: e.notes,
        bank_details: e.bank_details,
        hourly_wage: e.hourly_wage,
        wage_currency: e.wage_currency,
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
        hourly_wage: a.hourly_wage,
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
        hourly_wage: a.hourly_wage,
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

// ── Roles ─────────────────────────────────────────────────────────────────────

#[uniffi::export]
pub fn list_roles() -> Result<Vec<FfiRole>, FfiError> {
    let pool = pool()?;
    let rows = rt()
        .block_on(queries::list_roles(pool))
        .map_err(FfiError::from)?;
    Ok(rows
        .into_iter()
        .map(|r| FfiRole { id: r.id, name: r.name })
        .collect())
}

#[uniffi::export]
pub fn create_role(name: String) -> Result<i64, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::insert_role(pool, &name))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn update_role(id: i64, name: String) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::update_role(pool, id, &name))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn delete_role(id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::delete_role(pool, id))
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
    // Snapshot employee name and wage if missing
    if assignment.employee_name.is_none() || assignment.hourly_wage.is_none() {
        if let Some(emp) = rt()
            .block_on(queries::get_employee(pool, assignment.employee_id))
            .map_err(FfiError::from)?
        {
            if assignment.employee_name.is_none() {
                assignment.employee_name = Some(emp.display_name());
            }
            if assignment.hourly_wage.is_none() {
                assignment.hourly_wage = emp.hourly_wage;
            }
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
        let row = sqlx::query_as::<_, (i64, i64, i64, i64, String, Option<String>, Option<f64>)>(
            "SELECT id, rota_id, shift_id, employee_id, status, employee_name, hourly_wage \
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

/// Create an empty rota record for the given week with no shifts and no assignments.
/// Returns the rota id. Safe to call multiple times (returns existing id if one already exists).
#[uniffi::export]
pub fn create_empty_week(week_start: String) -> Result<i64, FfiError> {
    let pool = pool()?;
    let date = parse_date(&week_start)?;
    let result: Result<i64, sqlx::Error> = rt().block_on(async move {
        match queries::get_rota_by_week(pool, date).await? {
            Some(existing) => Ok(existing.id),
            None => queries::insert_rota(pool, date).await,
        }
    });
    result.map_err(|e| FfiError::Db { msg: e.to_string() })
}

/// Delete the rota for the given week along with all its shifts and assignments.
/// No-ops silently if no rota exists for that week.
#[uniffi::export]
pub fn delete_week(week_start: String) -> Result<(), FfiError> {
    let pool = pool()?;
    let date = parse_date(&week_start)?;
    let result: Result<(), sqlx::Error> = rt().block_on(async move {
        if let Some(rota) = queries::get_rota_by_week(pool, date).await? {
            queries::delete_rota(pool, rota.id).await?;
        }
        Ok(())
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
                    .map(|e| e.display_name())
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

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── parse_date ──

    #[test]
    fn parse_date_valid() {
        let d = parse_date("2026-03-23").unwrap();
        assert_eq!(d, NaiveDate::from_ymd_opt(2026, 3, 23).unwrap());
    }

    #[test]
    fn parse_date_invalid() {
        assert!(parse_date("not-a-date").is_err());
        assert!(parse_date("2026/03/23").is_err());
        assert!(parse_date("").is_err());
    }

    // ── parse_time ──

    #[test]
    fn parse_time_hhmm() {
        let t = parse_time("07:00").unwrap();
        assert_eq!(t, NaiveTime::from_hms_opt(7, 0, 0).unwrap());
    }

    #[test]
    fn parse_time_hhmmss() {
        let t = parse_time("07:00:00").unwrap();
        assert_eq!(t, NaiveTime::from_hms_opt(7, 0, 0).unwrap());
    }

    #[test]
    fn parse_time_invalid() {
        assert!(parse_time("25:00").is_err());
        assert!(parse_time("abc").is_err());
        assert!(parse_time("").is_err());
    }

    // ── weekday conversions ──

    #[test]
    fn weekday_roundtrip_all_days() {
        let days = [
            Weekday::Mon,
            Weekday::Tue,
            Weekday::Wed,
            Weekday::Thu,
            Weekday::Fri,
            Weekday::Sat,
            Weekday::Sun,
        ];
        for day in days {
            let s = weekday_to_str(day);
            let parsed = weekday_from_str(s).unwrap();
            assert_eq!(parsed, day);
        }
    }

    #[test]
    fn weekday_from_str_invalid() {
        assert!(weekday_from_str("Monday").is_err());
        assert!(weekday_from_str("").is_err());
    }

    // ── availability slot conversion ──

    #[test]
    fn availability_slots_roundtrip() {
        let mut avail = Availability::default();
        avail.set(Weekday::Mon, 8, AvailabilityState::Yes);
        avail.set(Weekday::Wed, 14, AvailabilityState::No);
        avail.set(Weekday::Fri, 20, AvailabilityState::Maybe);

        let slots = availability_to_slots(&avail);
        assert_eq!(slots.len(), 3);

        let restored = slots_to_availability(slots).unwrap();
        assert_eq!(restored.get(Weekday::Mon, 8), AvailabilityState::Yes);
        assert_eq!(restored.get(Weekday::Wed, 14), AvailabilityState::No);
        assert_eq!(restored.get(Weekday::Fri, 20), AvailabilityState::Maybe);
    }

    #[test]
    fn slots_to_availability_invalid_weekday() {
        let slots = vec![AvailabilitySlot {
            weekday: "Blurb".into(),
            hour: 8,
            state: "Yes".into(),
        }];
        assert!(slots_to_availability(slots).is_err());
    }

    #[test]
    fn slots_to_availability_invalid_state() {
        let slots = vec![AvailabilitySlot {
            weekday: "Mon".into(),
            hour: 8,
            state: "Always".into(),
        }];
        assert!(slots_to_availability(slots).is_err());
    }

    // ── employee conversion ──

    #[test]
    fn employee_roundtrip() {
        let emp = Employee {
            id: 42,
            first_name: "Alice".into(),
            last_name: "Smith".into(),
            nickname: Some("Ally".into()),
            roles: vec!["Barista".into()],
            start_date: NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
            target_weekly_hours: 30.0,
            weekly_hours_deviation: 5.0,
            max_daily_hours: 8.0,
            notes: Some("Prefers mornings".into()),
            bank_details: None,
            hourly_wage: None,
            wage_currency: None,
            default_availability: Availability::default(),
            availability: Availability::default(),
            deleted: false,
        };

        let ffi = employee_to_ffi(emp.clone());
        assert_eq!(ffi.display_name, "Ally");
        assert_eq!(ffi.start_date, "2026-01-15");

        let back = ffi_to_employee(ffi).unwrap();
        assert_eq!(back.first_name, "Alice");
        assert_eq!(back.last_name, "Smith");
        assert_eq!(back.nickname, Some("Ally".into()));
        assert_eq!(back.roles, vec!["Barista"]);
        assert_eq!(back.start_date, emp.start_date);
        assert_eq!(back.target_weekly_hours, 30.0);
    }

    // ── shift template conversion ──

    #[test]
    fn shift_template_roundtrip() {
        let tmpl = ShiftTemplate {
            id: 10,
            name: "Morning".into(),
            weekdays: vec![Weekday::Mon, Weekday::Wed, Weekday::Fri],
            start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
            required_role: "Barista".into(),
            min_employees: 1,
            max_employees: 2,
            deleted: false,
        };

        let ffi = shift_template_to_ffi(tmpl.clone());
        assert_eq!(ffi.weekdays, vec!["Mon", "Wed", "Fri"]);
        assert_eq!(ffi.start_time, "07:00");
        assert_eq!(ffi.end_time, "12:00");

        let back = ffi_to_shift_template(ffi).unwrap();
        assert_eq!(back.weekdays, vec![Weekday::Mon, Weekday::Wed, Weekday::Fri]);
        assert_eq!(back.start_time, tmpl.start_time);
        assert_eq!(back.end_time, tmpl.end_time);
    }

    // ── assignment conversion ──

    #[test]
    fn assignment_roundtrip() {
        let a = Assignment {
            id: 5,
            rota_id: 1,
            shift_id: 3,
            employee_id: 7,
            status: AssignmentStatus::Confirmed,
            employee_name: Some("Bob".into()),
            hourly_wage: None,
        };

        let ffi = assignment_to_ffi(a);
        assert_eq!(ffi.status, "Confirmed");

        let back = ffi_to_assignment(ffi).unwrap();
        assert_eq!(back.status, AssignmentStatus::Confirmed);
        assert_eq!(back.employee_name, Some("Bob".into()));
    }

    #[test]
    fn assignment_invalid_status() {
        let ffi = FfiAssignment {
            id: 1,
            rota_id: 1,
            shift_id: 1,
            employee_id: 1,
            status: "InvalidStatus".into(),
            employee_name: None,
            hourly_wage: None,
        };
        assert!(ffi_to_assignment(ffi).is_err());
    }

    // ── Full lifecycle test ──
    // Uses a single test because OnceLock means init_db can only be called once per process.

    #[test]
    fn full_ffi_lifecycle() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("test_ffi.db");
        init_db(db_path.to_string_lossy().to_string()).unwrap();

        // Double-init should fail
        assert!(init_db(db_path.to_string_lossy().to_string()).is_err());

        // ── Roles ──
        let role_id = create_role("Barista".into()).unwrap();
        assert!(role_id > 0);

        let roles = list_roles().unwrap();
        assert_eq!(roles.len(), 1);
        assert_eq!(roles[0].name, "Barista");

        update_role(role_id, "Coffee Maker".into()).unwrap();
        let roles = list_roles().unwrap();
        assert_eq!(roles[0].name, "Coffee Maker");
        update_role(role_id, "Barista".into()).unwrap();

        // ── Employees ──
        let avail_slots: Vec<AvailabilitySlot> = (7..12)
            .map(|h| AvailabilitySlot {
                weekday: "Mon".into(),
                hour: h,
                state: "Yes".into(),
            })
            .collect();

        let emp = FfiEmployee {
            id: 0,
            first_name: "Alice".into(),
            last_name: "Smith".into(),
            nickname: Some("Ally".into()),
            display_name: String::new(),
            roles: vec!["Barista".into()],
            start_date: "2026-01-01".into(),
            target_weekly_hours: 40.0,
            weekly_hours_deviation: 6.0,
            max_daily_hours: 8.0,
            notes: None,
            bank_details: None,
            hourly_wage: None,
            wage_currency: None,
            default_availability: avail_slots.clone(),
            availability: avail_slots,
            deleted: false,
        };

        let emp_id = create_employee(emp).unwrap();
        let employees = list_employees().unwrap();
        assert_eq!(employees.len(), 1);
        assert_eq!(employees[0].display_name, "Ally");

        let fetched = get_employee(emp_id).unwrap().unwrap();
        assert_eq!(fetched.roles, vec!["Barista"]);
        assert_eq!(fetched.default_availability.len(), 5);

        // ── Shift Templates ──
        let tmpl = FfiShiftTemplate {
            id: 0,
            name: "Morning".into(),
            weekdays: vec!["Mon".into()],
            start_time: "07:00".into(),
            end_time: "12:00".into(),
            required_role: "Barista".into(),
            min_employees: 1,
            max_employees: 1,
            deleted: false,
        };

        let tmpl_id = create_shift_template(tmpl).unwrap();
        assert!(tmpl_id > 0);

        let templates = list_shift_templates().unwrap();
        assert_eq!(templates.len(), 1);
        assert_eq!(templates[0].weekdays, vec!["Mon"]);

        // ── Materialise Week ──
        let week_start = "2027-06-07"; // far future Monday
        let rota_id = materialise_week(week_start.into()).unwrap();
        assert!(rota_id > 0);

        let shifts = list_shifts_for_rota(rota_id).unwrap();
        assert_eq!(shifts.len(), 1);
        assert_eq!(shifts[0].date, "2027-06-07");

        // Idempotent
        let rota_id2 = materialise_week(week_start.into()).unwrap();
        assert_eq!(rota_id, rota_id2);

        // ── Get Week Schedule (empty) ──
        let schedule = get_week_schedule(week_start.into()).unwrap().unwrap();
        assert_eq!(schedule.rota_id, rota_id);
        assert!(!schedule.finalized);
        assert_eq!(schedule.shifts.len(), 1);
        assert!(schedule.entries.is_empty());

        // ── Ad-hoc shift + update + delete ──
        let adhoc_id = create_ad_hoc_shift(
            rota_id,
            "2027-06-08".into(),
            "14:00".into(),
            "18:00".into(),
            "Barista".into(),
        )
        .unwrap();

        update_shift_times(adhoc_id, "15:00".into(), "19:00".into()).unwrap();
        let updated = list_shifts_for_rota(rota_id).unwrap();
        let adhoc = updated.iter().find(|s| s.id == adhoc_id).unwrap();
        assert_eq!(adhoc.start_time, "15:00");

        delete_shift(adhoc_id).unwrap();
        assert_eq!(list_shifts_for_rota(rota_id).unwrap().len(), 1);

        // ── Manual assignment ──
        let assign = FfiAssignment {
            id: 0,
            rota_id,
            shift_id: shifts[0].id,
            employee_id: emp_id,
            status: "Proposed".into(),
            employee_name: None,
            hourly_wage: None,
        };
        let assign_id = create_assignment(assign).unwrap();
        update_assignment_status(assign_id, "Confirmed".into()).unwrap();

        let schedule = get_week_schedule(week_start.into()).unwrap().unwrap();
        assert_eq!(schedule.entries.len(), 1);
        assert_eq!(schedule.entries[0].employee_name, "Ally");
        assert_eq!(schedule.entries[0].status, "Confirmed");

        // ── Finalize ──
        finalize_rota(rota_id).unwrap();
        let final_schedule = get_week_schedule(week_start.into()).unwrap().unwrap();
        assert!(final_schedule.finalized);

        // ── Soft delete employee ──
        delete_employee(emp_id).unwrap();
        assert!(list_employees().unwrap().is_empty());

        // Assignment snapshot survives
        let schedule = get_week_schedule(week_start.into()).unwrap().unwrap();
        assert_eq!(schedule.entries[0].employee_name, "Ally");

        drop(dir);
    }
}

// ── Override conversions ──────────────────────────────────────────────────────

fn day_availability_to_slots(avail: &DayAvailability) -> Vec<DayAvailabilitySlot> {
    avail
        .0
        .iter()
        .map(|(&hour, &state)| DayAvailabilitySlot {
            hour,
            state: state.to_string(),
        })
        .collect()
}

fn slots_to_day_availability(slots: Vec<DayAvailabilitySlot>) -> Result<DayAvailability, FfiError> {
    let mut avail = DayAvailability::default();
    for s in slots {
        let state = s
            .state
            .parse::<AvailabilityState>()
            .map_err(|e| FfiError::InvalidArgument { msg: e })?;
        avail.set(s.hour, state);
    }
    Ok(avail)
}

fn employee_avail_override_to_ffi(o: EmployeeAvailabilityOverride) -> FfiEmployeeAvailabilityOverride {
    FfiEmployeeAvailabilityOverride {
        id: o.id,
        employee_id: o.employee_id,
        date: o.date.to_string(),
        availability: day_availability_to_slots(&o.availability),
        notes: o.notes,
    }
}

fn ffi_to_employee_avail_override(
    o: FfiEmployeeAvailabilityOverride,
) -> Result<EmployeeAvailabilityOverride, FfiError> {
    Ok(EmployeeAvailabilityOverride {
        id: o.id,
        employee_id: o.employee_id,
        date: parse_date(&o.date)?,
        availability: slots_to_day_availability(o.availability)?,
        notes: o.notes,
    })
}

fn shift_template_override_to_ffi(o: ShiftTemplateOverride) -> FfiShiftTemplateOverride {
    FfiShiftTemplateOverride {
        id: o.id,
        template_id: o.template_id,
        date: o.date.to_string(),
        cancelled: o.cancelled,
        start_time: o.start_time.map(|t| t.format("%H:%M").to_string()),
        end_time: o.end_time.map(|t| t.format("%H:%M").to_string()),
        min_employees: o.min_employees,
        max_employees: o.max_employees,
        notes: o.notes,
    }
}

fn ffi_to_shift_template_override(
    o: FfiShiftTemplateOverride,
) -> Result<ShiftTemplateOverride, FfiError> {
    Ok(ShiftTemplateOverride {
        id: o.id,
        template_id: o.template_id,
        date: parse_date(&o.date)?,
        cancelled: o.cancelled,
        start_time: o.start_time.as_deref().map(parse_time).transpose()?,
        end_time: o.end_time.as_deref().map(parse_time).transpose()?,
        min_employees: o.min_employees,
        max_employees: o.max_employees,
        notes: o.notes,
    })
}

// ── Employee Availability Override exports ────────────────────────────────────

#[uniffi::export]
pub fn upsert_employee_availability_override(
    override_: FfiEmployeeAvailabilityOverride,
) -> Result<i64, FfiError> {
    let pool = pool()?;
    let ovr = ffi_to_employee_avail_override(override_)?;
    rt().block_on(queries::upsert_employee_availability_override(pool, &ovr))
        .map_err(Into::into)
}

#[uniffi::export]
pub fn get_employee_availability_override(
    employee_id: i64,
    date: String,
) -> Result<Option<FfiEmployeeAvailabilityOverride>, FfiError> {
    let pool = pool()?;
    let d = parse_date(&date)?;
    rt().block_on(queries::get_employee_availability_override(pool, employee_id, d))
        .map(|opt| opt.map(employee_avail_override_to_ffi))
        .map_err(Into::into)
}

#[uniffi::export]
pub fn list_employee_availability_overrides(
    employee_id: i64,
) -> Result<Vec<FfiEmployeeAvailabilityOverride>, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::list_employee_availability_overrides_for_employee(pool, employee_id))
        .map(|v| v.into_iter().map(employee_avail_override_to_ffi).collect())
        .map_err(Into::into)
}

#[uniffi::export]
pub fn list_all_employee_availability_overrides() -> Result<Vec<FfiEmployeeAvailabilityOverride>, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::list_all_employee_availability_overrides(pool))
        .map(|v| v.into_iter().map(employee_avail_override_to_ffi).collect())
        .map_err(Into::into)
}

#[uniffi::export]
pub fn delete_employee_availability_override(id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::delete_employee_availability_override(pool, id))
        .map_err(Into::into)
}

// ── Shift Template Override exports ───────────────────────────────────────────

#[uniffi::export]
pub fn upsert_shift_template_override(
    override_: FfiShiftTemplateOverride,
) -> Result<i64, FfiError> {
    let pool = pool()?;
    let ovr = ffi_to_shift_template_override(override_)?;
    rt().block_on(queries::upsert_shift_template_override(pool, &ovr))
        .map_err(Into::into)
}

#[uniffi::export]
pub fn get_shift_template_override(
    template_id: i64,
    date: String,
) -> Result<Option<FfiShiftTemplateOverride>, FfiError> {
    let pool = pool()?;
    let d = parse_date(&date)?;
    rt().block_on(queries::get_shift_template_override(pool, template_id, d))
        .map(|opt| opt.map(shift_template_override_to_ffi))
        .map_err(Into::into)
}

#[uniffi::export]
pub fn list_shift_template_overrides_for_template(
    template_id: i64,
) -> Result<Vec<FfiShiftTemplateOverride>, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::list_shift_template_overrides_for_template(pool, template_id))
        .map(|v| v.into_iter().map(shift_template_override_to_ffi).collect())
        .map_err(Into::into)
}

#[uniffi::export]
pub fn list_all_shift_template_overrides() -> Result<Vec<FfiShiftTemplateOverride>, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::list_all_shift_template_overrides(pool))
        .map(|v| v.into_iter().map(shift_template_override_to_ffi).collect())
        .map_err(Into::into)
}

#[uniffi::export]
pub fn delete_shift_template_override(id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::delete_shift_template_override(pool, id))
        .map_err(Into::into)
}

// ── Employee Shift History ───────────────────────────────────────────────────

fn shift_record_to_ffi(r: EmployeeShiftRecord) -> FfiEmployeeShiftRecord {
    let duration = r.duration_hours();
    let shift_cost = r.hourly_wage.map(|w| w * duration);
    FfiEmployeeShiftRecord {
        assignment_id: r.assignment_id,
        rota_id: r.rota_id,
        shift_id: r.shift_id,
        employee_id: r.employee_id,
        status: r.status.to_string(),
        employee_name: r.employee_name,
        hourly_wage: r.hourly_wage,
        shift_cost,
        date: r.date.to_string(),
        weekday: weekday_to_str(r.date.weekday()).to_string(),
        start_time: r.start_time.format("%H:%M").to_string(),
        end_time: r.end_time.format("%H:%M").to_string(),
        required_role: r.required_role,
        duration_hours: duration,
        week_start: r.week_start.to_string(),
        finalized: r.finalized,
    }
}

#[uniffi::export]
pub fn list_employee_shift_history(
    employee_id: i64,
) -> Result<Vec<FfiEmployeeShiftRecord>, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::list_employee_shift_history(pool, employee_id))
        .map(|records| records.into_iter().map(shift_record_to_ffi).collect())
        .map_err(Into::into)
}
