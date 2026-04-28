mod error;
mod types;

use std::sync::OnceLock;

use autorota_core::db::{self, queries};
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::{Availability, AvailabilityState};
use autorota_core::models::employee::Employee;
use autorota_core::models::overrides::{
    DayAvailability, EmployeeAvailabilityOverride, OverrideSource, ShiftTemplateOverride,
};
use autorota_core::models::rota::Rota;
use autorota_core::models::shift::{Shift, ShiftTemplate};
use autorota_core::models::shift_history::EmployeeShiftRecord;
use chrono::{Datelike, Local, NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;
use tokio::runtime::Runtime;

pub use error::{ErrorCode, FfiError, localize_error};
pub use types::*;

uniffi::setup_scaffolding!();

// ── Globals ───────────────────────────────────────────────────────────────────

static POOL: OnceLock<SqlitePool> = OnceLock::new();
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn rt() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("tokio runtime"))
}

fn pool() -> Result<&'static SqlitePool, FfiError> {
    POOL.get().ok_or_else(|| FfiError::Db {
        code: ErrorCode::DbConnectionFailed,
        msg: "database not initialized — call initDb first".into(),
    })
}

// ── String ↔ chrono conversions ───────────────────────────────────────────────

fn parse_date(s: &str) -> Result<NaiveDate, FfiError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").map_err(|e| FfiError::InvalidArgument {
        code: ErrorCode::InvalidDate,
        msg: format!("invalid date '{s}': {e}"),
    })
}

fn parse_time(s: &str) -> Result<NaiveTime, FfiError> {
    NaiveTime::parse_from_str(s, "%H:%M")
        .or_else(|_| NaiveTime::parse_from_str(s, "%H:%M:%S"))
        .map_err(|e| FfiError::InvalidArgument {
            code: ErrorCode::InvalidDate,
            msg: format!("invalid time '{s}': {e}"),
        })
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
        other => Err(FfiError::InvalidArgument {
            code: ErrorCode::InvalidGeneric,
            msg: format!("invalid weekday: {other}"),
        }),
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
        let state =
            slot.state
                .parse::<AvailabilityState>()
                .map_err(|e| FfiError::InvalidArgument {
                    code: ErrorCode::InvalidGeneric,
                    msg: e,
                })?;
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
        phone: e.phone,
        email: e.email,
        preferred_contact: e.preferred_contact,
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
        phone: e.phone,
        email: e.email,
        preferred_contact: e.preferred_contact,
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
        weekdays: t
            .weekdays
            .iter()
            .map(|&wd| weekday_to_str(wd).to_string())
            .collect(),
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
            .map_err(|e| FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: e,
            })?,
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
    let pool = rt().block_on(db::connect(&url)).map_err(|e| FfiError::Db {
        code: ErrorCode::DbConnectionFailed,
        msg: e.to_string(),
    })?;
    POOL.set(pool).map_err(|_| FfiError::Db {
        code: ErrorCode::DbConnectionFailed,
        msg: "database already initialized".into(),
    })
}

// ── Perf corpus (debug / perf-helpers only) ──────────────────────────────────

/// Populate the database with a deterministic synthetic corpus for performance
/// testing. Only linked when the `perf-helpers` feature is enabled — release
/// builds do not include this symbol so the corpus generator never ships.
///
/// Runs against the existing `POOL` — caller must have invoked `init_db`
/// against a fresh / ephemeral path first. Idempotency is the caller's
/// problem; running twice will create duplicates.
#[cfg(feature = "perf-helpers")]
#[uniffi::export]
pub fn seed_perf_corpus(employees: u32, seed: u64) -> Result<(), FfiError> {
    let pool = pool()?;
    let c = autorota_core::testutil::corpus::generate_corpus(employees as usize, 1, seed);
    rt().block_on(autorota_core::testutil::corpus::seed_corpus_into_pool(
        pool, &c,
    ))
    .map_err(|e| FfiError::Db {
        code: ErrorCode::DbConnectionFailed,
        msg: e.to_string(),
    })
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
    autorota_core::models::validation::validate_employee(&core)
        .map_err(|e| FfiError::invalid(error::ErrorCode::InvalidGeneric, e.to_string()))?;
    rt().block_on(queries::insert_employee(pool, &core))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn update_employee(employee: FfiEmployee) -> Result<(), FfiError> {
    let pool = pool()?;
    let core = ffi_to_employee(employee)?;
    autorota_core::models::validation::validate_employee(&core)
        .map_err(|e| FfiError::invalid(error::ErrorCode::InvalidGeneric, e.to_string()))?;
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
        .map(|r| FfiRole {
            id: r.id,
            name: r.name,
        })
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
    autorota_core::models::validation::validate_shift_template(&core)
        .map_err(|e| FfiError::invalid(error::ErrorCode::InvalidGeneric, e.to_string()))?;
    rt().block_on(queries::insert_shift_template(pool, &core))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn update_shift_template(template: FfiShiftTemplate) -> Result<(), FfiError> {
    let pool = pool()?;
    let core = ffi_to_shift_template(template)?;
    autorota_core::models::validation::validate_shift_template(&core)
        .map_err(|e| FfiError::invalid(error::ErrorCode::InvalidGeneric, e.to_string()))?;
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
        .map_err(|e| FfiError::InvalidArgument {
            code: ErrorCode::InvalidGeneric,
            msg: e,
        })?;
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
        let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM assignments WHERE shift_id = ?")
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
        let a =
            sqlx::query_as::<_, (i64, i64)>("SELECT id, shift_id FROM assignments WHERE id = ?")
                .bind(id_a)
                .fetch_optional(pool)
                .await?
                .ok_or_else(|| sqlx::Error::RowNotFound)?;

        let b =
            sqlx::query_as::<_, (i64, i64)>("SELECT id, shift_id FROM assignments WHERE id = ?")
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
    result.map_err(|e| FfiError::Db {
        code: ErrorCode::DbGeneric,
        msg: e.to_string(),
    })
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
    result.map_err(|e| FfiError::Db {
        code: ErrorCode::DbGeneric,
        msg: e.to_string(),
    })
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
    result.map_err(|e| FfiError::Db {
        code: ErrorCode::DbGeneric,
        msg: e.to_string(),
    })
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
            code: ErrorCode::InvalidGeneric,
            msg: "cannot generate schedule for current or past weeks".into(),
        });
    }

    // Step 1: prepare rota (create/reuse, re-materialise shifts)
    let rota_id: Result<i64, sqlx::Error> = rt().block_on(async move {
        match queries::get_rota_by_week(pool, date).await? {
            Some(existing) => {
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
    let rota_id = rota_id.map_err(|e| FfiError::Db {
        code: ErrorCode::DbGeneric,
        msg: e.to_string(),
    })?;

    // Step 2: run scheduler
    let result = rt()
        .block_on(autorota_core::scheduler::schedule(pool, rota_id))
        .map_err(|e| FfiError::Db {
            code: ErrorCode::DbGeneric,
            msg: e.to_string(),
        })?;

    Ok(FfiScheduleResult {
        assignments: result
            .assignments
            .into_iter()
            .map(assignment_to_ffi)
            .collect(),
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

        let has_saves = queries::rota_has_saves(pool, rota.id).await?;

        Ok(Some(FfiWeekSchedule {
            rota_id: rota.id,
            week_start: rota.week_start.to_string(),
            has_saves,
            entries,
            shifts: shift_infos,
        }))
    });
    result.map_err(|e| FfiError::Db {
        code: ErrorCode::DbGeneric,
        msg: e.to_string(),
    })
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

// ── Export ───────────────────────────────────────────────────────────────────

use autorota_core::export::config::{
    CellContentFlags, EmployeeExportConfig, ExportConfig, ExportFormat, ExportLayout,
    ExportProfile, PdfTemplate,
};

fn parse_export_config(config: FfiExportConfig) -> Result<ExportConfig, FfiError> {
    let layout: ExportLayout =
        config
            .layout
            .parse()
            .map_err(|e: String| FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: e,
            })?;
    let format: ExportFormat =
        config
            .format
            .parse()
            .map_err(|e: String| FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: e,
            })?;
    let profile: ExportProfile =
        config
            .profile
            .parse()
            .map_err(|e: String| FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: e,
            })?;
    let pdf_template: Option<PdfTemplate> = match config.pdf_template.as_deref() {
        None | Some("") => None,
        Some(s) => Some(s.parse().map_err(|e: String| FfiError::InvalidArgument {
            code: ErrorCode::InvalidGeneric,
            msg: e,
        })?),
    };

    Ok(ExportConfig {
        layout,
        format,
        profile,
        cell_content: CellContentFlags {
            show_shift_name: config.show_shift_name,
            show_times: config.show_times,
            show_role: config.show_role,
        },
        pdf_template,
    })
}

#[uniffi::export]
pub fn export_week_schedule(
    week_start: String,
    config: FfiExportConfig,
) -> Result<FfiExportResult, FfiError> {
    let pool = pool()?;
    let date = parse_date(&week_start)?;
    let core_config = parse_export_config(config)?;

    let result = rt()
        .block_on(autorota_core::export::export_week_schedule(
            pool,
            date,
            core_config,
        ))
        .map_err(|e| match e {
            autorota_core::export::ExportError::Db(db_err) => FfiError::Db {
                code: ErrorCode::DbGeneric,
                msg: db_err.to_string(),
            },
            autorota_core::export::ExportError::NoSchedule(msg) => FfiError::NotFound {
                code: ErrorCode::NotFoundSchedule,
                msg,
            },
            autorota_core::export::ExportError::EmployeeNotFound(id) => FfiError::NotFound {
                code: ErrorCode::NotFoundEmployee,
                msg: format!("employee {id} not found"),
            },
            autorota_core::export::ExportError::Pdf(msg) => FfiError::InvalidArgument {
                code: ErrorCode::InvalidPdf,
                msg,
            },
        })?;

    Ok(FfiExportResult {
        data: result.data,
        filename: result.filename,
        mime_type: result.mime_type,
    })
}

#[uniffi::export]
pub fn export_employee_schedule(
    config: FfiEmployeeExportConfig,
) -> Result<FfiExportResult, FfiError> {
    let pool = pool()?;
    let start_date = parse_date(&config.start_date)?;
    let end_date = parse_date(&config.end_date)?;
    let format: ExportFormat =
        config
            .format
            .parse()
            .map_err(|e: String| FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: e,
            })?;
    let profile: ExportProfile =
        config
            .profile
            .parse()
            .map_err(|e: String| FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: e,
            })?;

    let core_config = EmployeeExportConfig {
        employee_id: config.employee_id,
        format,
        profile,
        cell_content: CellContentFlags {
            show_shift_name: config.show_shift_name,
            show_times: config.show_times,
            show_role: config.show_role,
        },
        timezone_id: config.timezone_id.clone(),
    };

    let result = rt()
        .block_on(autorota_core::export::export_employee_schedule(
            pool,
            config.employee_id,
            start_date,
            end_date,
            core_config,
        ))
        .map_err(|e| match e {
            autorota_core::export::ExportError::Db(db_err) => FfiError::Db {
                code: ErrorCode::DbGeneric,
                msg: db_err.to_string(),
            },
            autorota_core::export::ExportError::NoSchedule(msg) => FfiError::NotFound {
                code: ErrorCode::NotFoundSchedule,
                msg,
            },
            autorota_core::export::ExportError::EmployeeNotFound(id) => FfiError::NotFound {
                code: ErrorCode::NotFoundEmployee,
                msg: format!("employee {id} not found"),
            },
            autorota_core::export::ExportError::Pdf(msg) => FfiError::InvalidArgument {
                code: ErrorCode::InvalidPdf,
                msg,
            },
        })?;

    Ok(FfiExportResult {
        data: result.data,
        filename: result.filename,
        mime_type: result.mime_type,
    })
}

/// Generate a full-rota preview PDF/CSV/etc. using synthetic fixture data.
/// Bypasses the database; `week_start` is ignored by the renderer.
#[uniffi::export]
pub fn export_preview_full(config: FfiExportConfig) -> Result<FfiExportResult, FfiError> {
    let core_config = parse_export_config(config)?;
    let result = autorota_core::export::preview::generate_preview_full(core_config).map_err(
        |e| match e {
            autorota_core::export::ExportError::Pdf(msg) => FfiError::InvalidArgument {
                code: ErrorCode::InvalidPdf,
                msg,
            },
            other => FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: other.to_string(),
            },
        },
    )?;
    Ok(FfiExportResult {
        data: result.data,
        filename: result.filename,
        mime_type: result.mime_type,
    })
}

/// Generate a single-employee preview using synthetic fixture data. The
/// `employee_id`, `start_date`, and `end_date` fields on `config` are ignored.
#[uniffi::export]
pub fn export_preview_employee(
    config: FfiEmployeeExportConfig,
) -> Result<FfiExportResult, FfiError> {
    let format: ExportFormat =
        config
            .format
            .parse()
            .map_err(|e: String| FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: e,
            })?;
    let profile: ExportProfile =
        config
            .profile
            .parse()
            .map_err(|e: String| FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: e,
            })?;

    let core_config = EmployeeExportConfig {
        employee_id: config.employee_id,
        format,
        profile,
        cell_content: CellContentFlags {
            show_shift_name: config.show_shift_name,
            show_times: config.show_times,
            show_role: config.show_role,
        },
        timezone_id: config.timezone_id.clone(),
    };

    let result = autorota_core::export::preview::generate_preview_employee(core_config).map_err(
        |e| match e {
            autorota_core::export::ExportError::Pdf(msg) => FfiError::InvalidArgument {
                code: ErrorCode::InvalidPdf,
                msg,
            },
            other => FfiError::InvalidArgument {
                code: ErrorCode::InvalidGeneric,
                msg: other.to_string(),
            },
        },
    )?;
    Ok(FfiExportResult {
        data: result.data,
        filename: result.filename,
        mime_type: result.mime_type,
    })
}

/// Emit the four-format personal bundle (PDF, ICS, Markdown, XLSX) for one
/// employee's schedule over a date range. The caller-supplied `format` field
/// on `config` is ignored — each output uses its own format.
#[uniffi::export]
pub fn export_employee_bundle(
    config: FfiEmployeeExportConfig,
) -> Result<Vec<FfiExportResult>, FfiError> {
    let formats = ["pdf", "ics", "markdown", "xlsx"];
    let mut out = Vec::with_capacity(formats.len());
    for fmt in formats {
        let mut cfg = config.clone();
        cfg.format = fmt.to_string();
        out.push(export_employee_schedule(cfg)?);
    }
    Ok(out)
}

// ── Roster Import ────────────────────────────────────────────────────────────

use autorota_core::import::{self, MergeStrategy, ParsedEmployeeRow, ParsedRoster};

fn row_to_ffi(r: ParsedEmployeeRow) -> FfiParsedEmployeeRow {
    FfiParsedEmployeeRow {
        first_name: r.first_name,
        last_name: r.last_name,
        nickname: r.nickname,
        phone: r.phone,
        email: r.email,
        preferred_contact: r.preferred_contact,
        roles: r.roles,
        target_weekly_hours: r.target_weekly_hours,
        weekly_hours_deviation: r.weekly_hours_deviation,
        max_daily_hours: r.max_daily_hours,
        hourly_wage: r.hourly_wage,
        wage_currency: r.wage_currency,
        notes: r.notes,
        bank_details: r.bank_details,
        match_existing_id: r.match_existing_id,
        diff_summary: r.diff_summary,
        include: r.include,
    }
}

fn ffi_to_row(r: FfiParsedEmployeeRow) -> ParsedEmployeeRow {
    ParsedEmployeeRow {
        first_name: r.first_name,
        last_name: r.last_name,
        nickname: r.nickname,
        phone: r.phone,
        email: r.email,
        preferred_contact: r.preferred_contact,
        roles: r.roles,
        target_weekly_hours: r.target_weekly_hours,
        weekly_hours_deviation: r.weekly_hours_deviation,
        max_daily_hours: r.max_daily_hours,
        hourly_wage: r.hourly_wage,
        wage_currency: r.wage_currency,
        notes: r.notes,
        bank_details: r.bank_details,
        match_existing_id: r.match_existing_id,
        diff_summary: r.diff_summary,
        include: r.include,
    }
}

#[uniffi::export]
pub fn parse_roster_file(
    bytes: Vec<u8>,
    format_hint: String,
    strategy: String,
) -> Result<FfiParsedRoster, FfiError> {
    let pool = pool()?;
    let strat: MergeStrategy = strategy
        .parse()
        .map_err(|e: String| FfiError::InvalidArgument {
            code: ErrorCode::InvalidGeneric,
            msg: e,
        })?;

    let parsed: ParsedRoster = rt()
        .block_on(import::roster::parse_roster(
            pool,
            &bytes,
            &format_hint,
            strat,
        ))
        .map_err(|e| match e {
            import::roster::ImportError::Db(db) => FfiError::Db {
                code: ErrorCode::DbGeneric,
                msg: db.to_string(),
            },
            import::roster::ImportError::Parse(m)
            | import::roster::ImportError::UnsupportedFormat(m) => FfiError::InvalidArgument {
                code: ErrorCode::InvalidImport,
                msg: m,
            },
        })?;

    Ok(FfiParsedRoster {
        rows: parsed.rows.into_iter().map(row_to_ffi).collect(),
        warnings: parsed.warnings,
    })
}

#[uniffi::export]
pub fn apply_roster_import(rows: Vec<FfiParsedEmployeeRow>) -> Result<FfiImportSummary, FfiError> {
    let pool = pool()?;
    let core_rows: Vec<ParsedEmployeeRow> = rows.into_iter().map(ffi_to_row).collect();
    let summary = rt()
        .block_on(import::roster::apply_import(pool, &core_rows))
        .map_err(|e| match e {
            import::roster::ImportError::Db(db) => FfiError::Db {
                code: ErrorCode::DbGeneric,
                msg: db.to_string(),
            },
            import::roster::ImportError::Parse(m)
            | import::roster::ImportError::UnsupportedFormat(m) => FfiError::InvalidArgument {
                code: ErrorCode::InvalidImport,
                msg: m,
            },
        })?;
    Ok(FfiImportSummary {
        inserted: summary.inserted,
        updated: summary.updated,
        skipped: summary.skipped,
    })
}

// ── Sync ─────────────────────────────────────────────────────────────────────

use autorota_core::models::sync::SyncRecord;

#[uniffi::export]
pub fn get_pending_sync_records(table_name: String) -> Result<Vec<FfiSyncRecord>, FfiError> {
    let pool = pool()?;
    let records = rt()
        .block_on(queries::get_pending_sync_records(pool, &table_name))
        .map_err(FfiError::from)?;
    Ok(records
        .into_iter()
        .map(|r| FfiSyncRecord {
            table_name: r.table_name,
            record_id: r.record_id,
            fields: r.fields,
            last_modified: r.last_modified,
        })
        .collect())
}

#[uniffi::export]
pub fn mark_records_synced(
    table_name: String,
    record_ids: Vec<i64>,
    base_snapshots: Vec<String>,
) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::mark_records_synced(
        pool,
        &table_name,
        &record_ids,
        &base_snapshots,
    ))
    .map_err(FfiError::from)?;
    Ok(())
}

#[uniffi::export]
pub fn apply_remote_record(record: FfiSyncRecord) -> Result<(), FfiError> {
    let pool = pool()?;
    let core_record = SyncRecord {
        table_name: record.table_name,
        record_id: record.record_id,
        fields: record.fields,
        last_modified: record.last_modified,
    };
    rt().block_on(queries::apply_remote_record(pool, &core_record))
        .map_err(FfiError::from)?;
    Ok(())
}

#[uniffi::export]
pub fn apply_remote_deletion(table_name: String, record_id: i64) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::apply_remote_deletion(pool, &table_name, record_id))
        .map_err(FfiError::from)?;
    Ok(())
}

#[uniffi::export]
pub fn get_sync_metadata(key: String) -> Result<Option<String>, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::get_sync_metadata(pool, &key))
        .map_err(FfiError::from)
}

#[uniffi::export]
pub fn set_sync_metadata(key: String, value: String) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::set_sync_metadata(pool, &key, &value))
        .map_err(FfiError::from)?;
    Ok(())
}

#[uniffi::export]
pub fn get_base_snapshots(
    table_name: String,
    record_ids: Vec<i64>,
) -> Result<Vec<FfiBaseSnapshot>, FfiError> {
    let pool = pool()?;
    let snapshots = rt()
        .block_on(queries::get_base_snapshots(pool, &table_name, &record_ids))
        .map_err(FfiError::from)?;
    Ok(snapshots
        .into_iter()
        .map(|s| FfiBaseSnapshot {
            record_id: s.record_id,
            snapshot: s.snapshot,
        })
        .collect())
}

#[uniffi::export]
pub fn get_pending_tombstones() -> Result<Vec<FfiTombstone>, FfiError> {
    let pool = pool()?;
    let tombstones = rt()
        .block_on(queries::get_pending_tombstones(pool))
        .map_err(FfiError::from)?;
    Ok(tombstones
        .into_iter()
        .map(|t| FfiTombstone {
            id: t.id,
            table_name: t.table_name,
            record_id: t.record_id,
            deleted_at: t.deleted_at,
        })
        .collect())
}

#[uniffi::export]
pub fn clear_tombstones(ids: Vec<i64>) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::clear_tombstones(pool, &ids))
        .map_err(FfiError::from)?;
    Ok(())
}

/// Returns the count of employees in the database (used for first-launch detection).
#[uniffi::export]
pub fn count_employees() -> Result<i64, FfiError> {
    let pool = pool()?;
    let count: i64 = rt()
        .block_on(sqlx::query_scalar("SELECT COUNT(*) FROM employees").fetch_one(pool))
        .map_err(FfiError::from)?;
    Ok(count)
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
            phone: None,
            email: None,
            preferred_contact: None,
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
        assert_eq!(
            back.weekdays,
            vec![Weekday::Mon, Weekday::Wed, Weekday::Fri]
        );
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
            phone: None,
            email: None,
            preferred_contact: None,
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
        let state =
            s.state
                .parse::<AvailabilityState>()
                .map_err(|e| FfiError::InvalidArgument {
                    code: ErrorCode::InvalidGeneric,
                    msg: e,
                })?;
        avail.set(s.hour, state);
    }
    Ok(avail)
}

fn employee_avail_override_to_ffi(
    o: EmployeeAvailabilityOverride,
) -> FfiEmployeeAvailabilityOverride {
    FfiEmployeeAvailabilityOverride {
        id: o.id,
        employee_id: o.employee_id,
        date: o.date.to_string(),
        availability: day_availability_to_slots(&o.availability),
        notes: o.notes,
        source: o.source.as_str().to_string(),
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
        source: OverrideSource::parse(&o.source),
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
    rt().block_on(queries::get_employee_availability_override(
        pool,
        employee_id,
        d,
    ))
    .map(|opt| opt.map(employee_avail_override_to_ffi))
    .map_err(Into::into)
}

#[uniffi::export]
pub fn list_employee_availability_overrides(
    employee_id: i64,
) -> Result<Vec<FfiEmployeeAvailabilityOverride>, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::list_employee_availability_overrides_for_employee(
        pool,
        employee_id,
    ))
    .map(|v| v.into_iter().map(employee_avail_override_to_ffi).collect())
    .map_err(Into::into)
}

#[uniffi::export]
pub fn list_all_employee_availability_overrides()
-> Result<Vec<FfiEmployeeAvailabilityOverride>, FfiError> {
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
    rt().block_on(queries::list_shift_template_overrides_for_template(
        pool,
        template_id,
    ))
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

#[uniffi::export]
pub fn list_all_shift_history(
    start_date: Option<String>,
    end_date: Option<String>,
) -> Result<Vec<FfiEmployeeShiftRecord>, FfiError> {
    let pool = pool()?;
    let sd = start_date.as_deref().map(parse_date).transpose()?;
    let ed = end_date.as_deref().map(parse_date).transpose()?;
    rt().block_on(queries::list_all_shift_history(pool, sd, ed))
        .map(|records| records.into_iter().map(shift_record_to_ffi).collect())
        .map_err(Into::into)
}

// ── Saves ──────────────────────────────────────────────────────────────────────

#[uniffi::export]
pub fn create_save(rota_id: i64) -> Result<i64, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::create_save(pool, rota_id))
        .map_err(Into::into)
}

#[uniffi::export]
pub fn diff_rota(rota_id: i64) -> Result<Vec<FfiShiftDiff>, FfiError> {
    let pool = pool()?;
    let result: Result<Vec<FfiShiftDiff>, sqlx::Error> = rt().block_on(async move {
        let diffs = queries::diff_rota_vs_latest_save(pool, rota_id).await?;
        Ok(diffs
            .into_iter()
            .map(|d| FfiShiftDiff {
                shift_id: d.shift_id,
                is_new: d.is_new,
                is_changed: d.is_changed,
            })
            .collect())
    });
    result.map_err(Into::into)
}

#[uniffi::export]
pub fn list_saves(rota_id: Option<i64>) -> Result<Vec<FfiSave>, FfiError> {
    let pool = pool()?;
    let result: Result<Vec<FfiSave>, sqlx::Error> = rt().block_on(async move {
        let saves = queries::list_saves(pool, rota_id).await?;
        let mut ffi_saves = Vec::new();
        for s in saves {
            let week_start: Option<String> =
                sqlx::query_scalar("SELECT week_start FROM rotas WHERE id = ?")
                    .bind(s.rota_id)
                    .fetch_optional(pool)
                    .await?;
            // Skip saves whose rota has been deleted (orphaned records).
            let Some(week_start) = week_start else {
                continue;
            };
            ffi_saves.push(FfiSave {
                id: s.id,
                rota_id: s.rota_id,
                saved_at: s.saved_at,
                summary: s.summary,
                tags: s.tags,
                week_start,
                restored_at: s.restored_at,
            });
        }
        Ok(ffi_saves)
    });
    result.map_err(Into::into)
}

#[uniffi::export]
pub fn get_save_detail(save_id: i64) -> Result<Option<FfiSaveDetail>, FfiError> {
    let pool = pool()?;
    let result: Result<Option<FfiSaveDetail>, sqlx::Error> = rt().block_on(async move {
        let save = match queries::get_save(pool, save_id).await? {
            Some(s) => s,
            None => return Ok(None),
        };
        let week_start: Option<String> =
            sqlx::query_scalar("SELECT week_start FROM rotas WHERE id = ?")
                .bind(save.rota_id)
                .fetch_optional(pool)
                .await?;
        // Return None if the rota has been deleted (orphaned save).
        let Some(week_start) = week_start else {
            return Ok(None);
        };
        Ok(Some(FfiSaveDetail {
            id: save.id,
            rota_id: save.rota_id,
            saved_at: save.saved_at,
            summary: save.summary,
            tags: save.tags,
            week_start,
            snapshot_json: save.snapshot_json,
            restored_at: save.restored_at,
        }))
    });
    result.map_err(Into::into)
}

#[uniffi::export]
pub fn rota_has_saves(rota_id: i64) -> Result<bool, FfiError> {
    let pool = pool()?;
    rt().block_on(queries::rota_has_saves(pool, rota_id))
        .map_err(Into::into)
}

/// Restore the live state of a rota to the snapshot captured by a save.
/// Existing shifts and assignments for the rota are replaced. Assignments
/// for employees that no longer exist are skipped; the count is returned.
#[uniffi::export]
pub fn restore_to_save(save_id: i64) -> Result<FfiRestoreResult, FfiError> {
    let pool = pool()?;
    let result = rt().block_on(queries::restore_from_save(pool, save_id))?;
    Ok(FfiRestoreResult {
        rota_id: result.rota_id,
        shifts_restored: result.shifts_restored as u32,
        assignments_restored: result.assignments_restored as u32,
        assignments_skipped: result.assignments_skipped as u32,
    })
}

/// Add a tag to a save. Enforces max tags per save, rejects duplicates
/// (case-insensitive), and validates the tag string (non-empty, ≤15 chars,
/// no `;`). Errors surface as `FfiError::InvalidArgument` with the
/// `ErrorCode::InvalidSaveTag` code so the UI can show a specific inline hint.
#[uniffi::export]
pub fn add_save_tag(save_id: i64, tag: String) -> Result<(), FfiError> {
    use autorota_core::db::queries::SaveTagError;

    let pool = pool()?;
    match rt().block_on(queries::add_save_tag(pool, save_id, &tag)) {
        Ok(()) => Ok(()),
        Err(SaveTagError::Validation(e)) => Err(FfiError::InvalidArgument {
            code: ErrorCode::InvalidSaveTag,
            msg: e.as_code().to_string(),
        }),
        Err(SaveTagError::Db(e)) => Err(e.into()),
    }
}

/// Remove a tag from a save by case-insensitive match. No-op if absent.
#[uniffi::export]
pub fn remove_save_tag(save_id: i64, tag: String) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::remove_save_tag(pool, save_id, &tag))
        .map_err(Into::into)
}

/// Detailed diff between the live state of a rota and its latest save.
/// Returns an empty vec if nothing has changed since the last save.
/// If the rota has no saves yet, every live shift appears as `shift_added`.
#[uniffi::export]
pub fn diff_rota_detailed(rota_id: i64) -> Result<Vec<FfiChangeDetail>, FfiError> {
    let pool = pool()?;
    let details = rt().block_on(queries::diff_rota_vs_latest_save_detailed(pool, rota_id))?;
    Ok(details.into_iter().map(change_detail_to_ffi).collect())
}

/// Detailed diff between two persisted saves.
#[uniffi::export]
pub fn diff_saves_detailed(
    old_save_id: i64,
    new_save_id: i64,
) -> Result<Vec<FfiChangeDetail>, FfiError> {
    let pool = pool()?;
    let details = rt().block_on(queries::diff_saves(pool, old_save_id, new_save_id))?;
    Ok(details.into_iter().map(change_detail_to_ffi).collect())
}

/// Detailed diff between a save and the save that immediately preceded
/// it for the same rota. If this is the first save, every shift is new.
#[uniffi::export]
pub fn diff_save_vs_previous(save_id: i64) -> Result<Vec<FfiChangeDetail>, FfiError> {
    let pool = pool()?;
    let details = rt().block_on(queries::diff_save_vs_previous(pool, save_id))?;
    Ok(details.into_iter().map(change_detail_to_ffi).collect())
}

fn change_detail_to_ffi(d: autorota_core::models::save::ChangeDetail) -> FfiChangeDetail {
    use autorota_core::models::save::ChangeKind as K;
    let mut out = FfiChangeDetail {
        kind: String::new(),
        shift_id: d.shift_id,
        date: d.date,
        old_start_time: None,
        new_start_time: None,
        old_end_time: None,
        new_end_time: None,
        old_required_role: None,
        new_required_role: None,
        old_min_employees: None,
        new_min_employees: None,
        old_max_employees: None,
        new_max_employees: None,
        employee_id: None,
        employee_name: None,
        old_status: None,
        new_status: None,
        from_shift_id: None,
        from_start_time: None,
        from_end_time: None,
    };
    match d.kind {
        K::ShiftAdded {
            start_time,
            end_time,
            required_role,
            min_employees,
            max_employees,
        } => {
            out.kind = "shift_added".into();
            out.new_start_time = Some(start_time);
            out.new_end_time = Some(end_time);
            out.new_required_role = Some(required_role);
            out.new_min_employees = Some(min_employees);
            out.new_max_employees = Some(max_employees);
        }
        K::ShiftRemoved {
            start_time,
            end_time,
            required_role,
        } => {
            out.kind = "shift_removed".into();
            out.old_start_time = Some(start_time);
            out.old_end_time = Some(end_time);
            out.old_required_role = Some(required_role);
        }
        K::ShiftTimeChanged {
            old_start,
            new_start,
            old_end,
            new_end,
        } => {
            out.kind = "shift_time_changed".into();
            out.old_start_time = Some(old_start);
            out.new_start_time = Some(new_start);
            out.old_end_time = Some(old_end);
            out.new_end_time = Some(new_end);
        }
        K::ShiftCapacityChanged {
            old_min,
            new_min,
            old_max,
            new_max,
        } => {
            out.kind = "shift_capacity_changed".into();
            out.old_min_employees = Some(old_min);
            out.new_min_employees = Some(new_min);
            out.old_max_employees = Some(old_max);
            out.new_max_employees = Some(new_max);
        }
        K::ShiftRoleChanged { old_role, new_role } => {
            out.kind = "shift_role_changed".into();
            out.old_required_role = Some(old_role);
            out.new_required_role = Some(new_role);
        }
        K::AssignmentAdded {
            employee_id,
            employee_name,
        } => {
            out.kind = "assignment_added".into();
            out.employee_id = Some(employee_id);
            out.employee_name = Some(employee_name);
        }
        K::AssignmentRemoved {
            employee_id,
            employee_name,
        } => {
            out.kind = "assignment_removed".into();
            out.employee_id = Some(employee_id);
            out.employee_name = Some(employee_name);
        }
        K::AssignmentStatusChanged {
            employee_id,
            employee_name,
            old_status,
            new_status,
        } => {
            out.kind = "assignment_status_changed".into();
            out.employee_id = Some(employee_id);
            out.employee_name = Some(employee_name);
            out.old_status = Some(old_status);
            out.new_status = Some(new_status);
        }
        K::EmployeeMoved {
            employee_id,
            employee_name,
            from_shift_id,
            from_start_time,
            from_end_time,
        } => {
            out.kind = "employee_moved".into();
            out.employee_id = Some(employee_id);
            out.employee_name = Some(employee_name);
            out.from_shift_id = Some(from_shift_id);
            out.from_start_time = Some(from_start_time);
            out.from_end_time = Some(from_end_time);
        }
    }
    out
}

// ── Availability Progress ────────────────────────────────────────────────────

#[uniffi::export]
pub fn list_availability_progress(
    week_start: String,
) -> Result<Vec<FfiAvailabilityProgress>, FfiError> {
    let pool = pool()?;
    let rows = rt()
        .block_on(queries::list_availability_progress(pool, &week_start))
        .map_err(FfiError::from)?;
    Ok(rows
        .into_iter()
        .map(|(employee_id, done)| FfiAvailabilityProgress { employee_id, done })
        .collect())
}

#[uniffi::export]
pub fn set_availability_progress(
    employee_id: i64,
    week_start: String,
    done: bool,
) -> Result<(), FfiError> {
    let pool = pool()?;
    rt().block_on(queries::set_availability_progress(
        pool,
        employee_id,
        &week_start,
        done,
    ))
    .map_err(Into::into)
}
