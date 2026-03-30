use chrono::{NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;

use crate::models::assignment::{Assignment, AssignmentStatus};
use crate::models::availability::Availability;
use crate::models::employee::Employee;
use crate::models::overrides::{DayAvailability, EmployeeAvailabilityOverride, ShiftTemplateOverride};
use crate::models::role::Role;
use crate::models::rota::Rota;
use crate::models::shift::{Shift, ShiftTemplate};
use crate::models::shift_history::EmployeeShiftRecord;
use crate::models::sync::{BaseSnapshot, SyncRecord, Tombstone};

type ShiftTemplateRow = (i64, String, String, String, String, String, u32, u32, bool);
type ShiftRow = (i64, Option<i64>, i64, String, String, String, String, u32, u32);

// ─── Employees ───────────────────────────────────────────────

pub async fn insert_employee(pool: &SqlitePool, emp: &Employee) -> Result<i64, sqlx::Error> {
    let roles_json = serde_json::to_string(&emp.roles).unwrap_or_default();
    let default_avail = emp.default_availability.to_json().unwrap_or_default();
    let avail = emp.availability.to_json().unwrap_or_default();
    let now = chrono::Utc::now().to_rfc3339();

    let id = sqlx::query_scalar(
        "INSERT INTO employees (first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, hourly_wage, wage_currency, default_availability, availability, last_modified, sync_status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) RETURNING id",
    )
    .bind(&emp.first_name)
    .bind(&emp.last_name)
    .bind(&emp.nickname)
    .bind(&roles_json)
    .bind(emp.start_date.to_string())
    .bind(emp.target_weekly_hours)
    .bind(emp.weekly_hours_deviation)
    .bind(emp.max_daily_hours)
    .bind(&emp.notes)
    .bind(&emp.bank_details)
    .bind(emp.hourly_wage)
    .bind(&emp.wage_currency)
    .bind(&default_avail)
    .bind(&avail)
    .bind(&now)
    .fetch_one(pool)
    .await?;

    Ok(id)
}

pub async fn get_employee(pool: &SqlitePool, id: i64) -> Result<Option<Employee>, sqlx::Error> {
    let row: Option<(i64, String, String, Option<String>, String, String, f64, f64, f64, Option<String>, Option<String>, Option<f64>, Option<String>, String, String, bool)> = sqlx::query_as(
        "SELECT id, first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, hourly_wage, wage_currency, default_availability, availability, deleted
         FROM employees WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(employee_from_row))
}

pub async fn list_employees(pool: &SqlitePool) -> Result<Vec<Employee>, sqlx::Error> {
    let rows: Vec<(i64, String, String, Option<String>, String, String, f64, f64, f64, Option<String>, Option<String>, Option<f64>, Option<String>, String, String, bool)> = sqlx::query_as(
        "SELECT id, first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, hourly_wage, wage_currency, default_availability, availability, deleted
         FROM employees WHERE deleted = 0 ORDER BY start_date",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(employee_from_row).collect())
}

/// List all employees including soft-deleted ones (for historical schedule display).
pub async fn list_all_employees(pool: &SqlitePool) -> Result<Vec<Employee>, sqlx::Error> {
    let rows: Vec<(i64, String, String, Option<String>, String, String, f64, f64, f64, Option<String>, Option<String>, Option<f64>, Option<String>, String, String, bool)> = sqlx::query_as(
        "SELECT id, first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, hourly_wage, wage_currency, default_availability, availability, deleted
         FROM employees ORDER BY start_date",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(employee_from_row).collect())
}

pub async fn update_employee(pool: &SqlitePool, emp: &Employee) -> Result<(), sqlx::Error> {
    let roles_json = serde_json::to_string(&emp.roles).unwrap_or_default();
    let default_avail = emp.default_availability.to_json().unwrap_or_default();
    let avail = emp.availability.to_json().unwrap_or_default();
    let now = chrono::Utc::now().to_rfc3339();

    sqlx::query(
        "UPDATE employees SET first_name = ?, last_name = ?, nickname = ?, roles = ?, start_date = ?, target_weekly_hours = ?, weekly_hours_deviation = ?, max_daily_hours = ?,
         notes = ?, bank_details = ?, hourly_wage = ?, wage_currency = ?, default_availability = ?, availability = ?, last_modified = ?, sync_status = 0 WHERE id = ?",
    )
    .bind(&emp.first_name)
    .bind(&emp.last_name)
    .bind(&emp.nickname)
    .bind(&roles_json)
    .bind(emp.start_date.to_string())
    .bind(emp.target_weekly_hours)
    .bind(emp.weekly_hours_deviation)
    .bind(emp.max_daily_hours)
    .bind(&emp.notes)
    .bind(&emp.bank_details)
    .bind(emp.hourly_wage)
    .bind(&emp.wage_currency)
    .bind(&default_avail)
    .bind(&avail)
    .bind(&now)
    .bind(emp.id)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn delete_employee(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query("UPDATE employees SET deleted = 1, last_modified = ?, sync_status = 0 WHERE id = ?")
        .bind(&now)
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

fn employee_from_row(
    row: (
        i64,
        String,
        String,
        Option<String>,
        String,
        String,
        f64,
        f64,
        f64,
        Option<String>,
        Option<String>,
        Option<f64>,
        Option<String>,
        String,
        String,
        bool,
    ),
) -> Employee {
    let (
        id,
        first_name,
        last_name,
        nickname,
        roles_json,
        start_date_str,
        target_weekly,
        deviation,
        max_daily,
        notes,
        bank_details,
        hourly_wage,
        wage_currency,
        default_avail_json,
        avail_json,
        deleted,
    ) = row;
    Employee {
        id,
        first_name,
        last_name,
        nickname,
        roles: serde_json::from_str(&roles_json).unwrap_or_default(),
        start_date: NaiveDate::parse_from_str(&start_date_str, "%Y-%m-%d")
            .unwrap_or_else(|_| NaiveDate::default()),
        target_weekly_hours: target_weekly as f32,
        weekly_hours_deviation: deviation as f32,
        max_daily_hours: max_daily as f32,
        notes,
        bank_details,
        hourly_wage: hourly_wage.map(|v| v as f32),
        wage_currency,
        default_availability: Availability::from_json(&default_avail_json).unwrap_or_default(),
        availability: Availability::from_json(&avail_json).unwrap_or_default(),
        deleted,
    }
}

// ─── Shift Templates ─────────────────────────────────────────

pub async fn insert_shift_template(
    pool: &SqlitePool,
    tmpl: &ShiftTemplate,
) -> Result<i64, sqlx::Error> {
    let weekdays_str = weekdays_to_string(&tmpl.weekdays);
    let start = tmpl.start_time.to_string();
    let end = tmpl.end_time.to_string();

    let now = chrono::Utc::now().to_rfc3339();
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO shift_templates (name, weekdays, start_time, end_time, required_role, min_employees, max_employees, last_modified, sync_status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0) RETURNING id",
    )
    .bind(&tmpl.name)
    .bind(&weekdays_str)
    .bind(&start)
    .bind(&end)
    .bind(&tmpl.required_role)
    .bind(tmpl.min_employees)
    .bind(tmpl.max_employees)
    .bind(&now)
    .fetch_one(pool)
    .await?;

    Ok(id)
}

pub async fn list_shift_templates(pool: &SqlitePool) -> Result<Vec<ShiftTemplate>, sqlx::Error> {
    let rows: Vec<ShiftTemplateRow> = sqlx::query_as(
        "SELECT id, name, weekdays, start_time, end_time, required_role, min_employees, max_employees, deleted
         FROM shift_templates WHERE deleted = 0 ORDER BY start_time",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .filter_map(shift_template_from_row)
        .collect())
}

/// Like `list_shift_templates` but includes soft-deleted templates (for historical lookups).
pub async fn list_all_shift_templates(
    pool: &SqlitePool,
) -> Result<Vec<ShiftTemplate>, sqlx::Error> {
    let rows: Vec<ShiftTemplateRow> = sqlx::query_as(
        "SELECT id, name, weekdays, start_time, end_time, required_role, min_employees, max_employees, deleted
         FROM shift_templates ORDER BY start_time",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .filter_map(shift_template_from_row)
        .collect())
}

pub async fn update_shift_template(
    pool: &SqlitePool,
    tmpl: &ShiftTemplate,
) -> Result<(), sqlx::Error> {
    let weekdays_str = weekdays_to_string(&tmpl.weekdays);
    let start = tmpl.start_time.to_string();
    let end = tmpl.end_time.to_string();

    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query(
        "UPDATE shift_templates SET name = ?, weekdays = ?, start_time = ?, end_time = ?, required_role = ?, min_employees = ?, max_employees = ?, last_modified = ?, sync_status = 0 WHERE id = ?",
    )
    .bind(&tmpl.name)
    .bind(&weekdays_str)
    .bind(&start)
    .bind(&end)
    .bind(&tmpl.required_role)
    .bind(tmpl.min_employees)
    .bind(tmpl.max_employees)
    .bind(&now)
    .bind(tmpl.id)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn delete_shift_template(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query("UPDATE shift_templates SET deleted = 1, last_modified = ?, sync_status = 0 WHERE id = ?")
        .bind(&now)
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

fn weekdays_to_string(weekdays: &[Weekday]) -> String {
    weekdays
        .iter()
        .map(|w| w.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

fn string_to_weekdays(s: &str) -> Vec<Weekday> {
    s.split(',')
        .filter(|p| !p.is_empty())
        .filter_map(|p| p.trim().parse().ok())
        .collect()
}

fn shift_template_from_row(row: ShiftTemplateRow) -> Option<ShiftTemplate> {
    let (id, name, weekdays_str, start_str, end_str, required_role, min_emp, max_emp, deleted) = row;
    Some(ShiftTemplate {
        id,
        name,
        weekdays: string_to_weekdays(&weekdays_str),
        start_time: NaiveTime::parse_from_str(&start_str, "%H:%M:%S").ok()?,
        end_time: NaiveTime::parse_from_str(&end_str, "%H:%M:%S").ok()?,
        required_role,
        min_employees: min_emp,
        max_employees: max_emp,
        deleted,
    })
}

/// Materialise concrete Shift rows from all templates for a given rota/week.
/// For each template and each of its weekdays, compute the date within the week
/// starting at `week_start` (which must be a Monday).
///
/// Respects `ShiftTemplateOverride` records: if an override for a template+date has
/// `cancelled = true`, that shift is skipped; otherwise any non-None override fields
/// replace the corresponding template values.
pub async fn materialise_shifts(
    pool: &SqlitePool,
    rota_id: i64,
    week_start: NaiveDate,
) -> Result<Vec<crate::models::shift::Shift>, sqlx::Error> {
    let templates = list_shift_templates(pool).await?;
    let mut shifts = Vec::new();

    for tmpl in &templates {
        for &weekday in &tmpl.weekdays {
            let days_offset = weekday.num_days_from_monday();
            let shift_date = week_start + chrono::Duration::days(days_offset as i64);

            // Check for a date-specific override on this template+date.
            if let Some(ovr) = get_shift_template_override(pool, tmpl.id, shift_date).await? {
                if ovr.cancelled {
                    continue;
                }
                let start_time = ovr.start_time.unwrap_or(tmpl.start_time);
                let end_time = ovr.end_time.unwrap_or(tmpl.end_time);
                let min_employees = ovr.min_employees.unwrap_or(tmpl.min_employees);
                let max_employees = ovr.max_employees.unwrap_or(tmpl.max_employees);
                let shift = crate::models::shift::Shift {
                    id: 0,
                    template_id: Some(tmpl.id),
                    rota_id,
                    date: shift_date,
                    start_time,
                    end_time,
                    required_role: tmpl.required_role.clone(),
                    min_employees,
                    max_employees,
                };
                let id = insert_shift(pool, &shift).await?;
                shifts.push(crate::models::shift::Shift { id, ..shift });
                continue;
            }

            let shift = crate::models::shift::Shift {
                id: 0,
                template_id: Some(tmpl.id),
                rota_id,
                date: shift_date,
                start_time: tmpl.start_time,
                end_time: tmpl.end_time,
                required_role: tmpl.required_role.clone(),
                min_employees: tmpl.min_employees,
                max_employees: tmpl.max_employees,
            };

            let id = insert_shift(pool, &shift).await?;
            shifts.push(crate::models::shift::Shift { id, ..shift });
        }
    }

    Ok(shifts)
}

// ─── Rotas ───────────────────────────────────────────────────

pub async fn insert_rota(pool: &SqlitePool, week_start: NaiveDate) -> Result<i64, sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    let id: i64 =
        sqlx::query_scalar("INSERT INTO rotas (week_start, finalized, last_modified, sync_status) VALUES (?, 0, ?, 0) RETURNING id")
            .bind(week_start.to_string())
            .bind(&now)
            .fetch_one(pool)
            .await?;

    Ok(id)
}

pub async fn get_rota(pool: &SqlitePool, id: i64) -> Result<Option<Rota>, sqlx::Error> {
    let row: Option<(i64, String, bool)> =
        sqlx::query_as("SELECT id, week_start, finalized FROM rotas WHERE id = ?")
            .bind(id)
            .fetch_optional(pool)
            .await?;

    let Some((rota_id, week_start_str, finalized)) = row else {
        return Ok(None);
    };

    let week_start = NaiveDate::parse_from_str(&week_start_str, "%Y-%m-%d")
        .unwrap_or_else(|_| NaiveDate::default());

    let assignments = list_assignments_for_rota(pool, rota_id).await?;

    Ok(Some(Rota {
        id: rota_id,
        week_start,
        assignments,
        finalized,
    }))
}

pub async fn get_rota_by_week(
    pool: &SqlitePool,
    week_start: NaiveDate,
) -> Result<Option<Rota>, sqlx::Error> {
    let row: Option<(i64,)> = sqlx::query_as("SELECT id FROM rotas WHERE week_start = ?")
        .bind(week_start.to_string())
        .fetch_optional(pool)
        .await?;

    match row {
        Some((id,)) => get_rota(pool, id).await,
        None => Ok(None),
    }
}

/// Delete a rota and all its data. Deletes all shifts first (which cascades
/// to assignments via the ON DELETE CASCADE FK), then removes the rota row.
pub async fn delete_rota(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    // Insert tombstones for assignments belonging to shifts in this rota.
    let assignment_ids: Vec<(i64,)> = sqlx::query_as(
        "SELECT a.id FROM assignments a JOIN shifts s ON s.id = a.shift_id WHERE s.rota_id = ?",
    )
    .bind(id)
    .fetch_all(pool)
    .await?;
    for (aid,) in &assignment_ids {
        insert_tombstone(pool, "assignments", *aid).await?;
    }

    // Insert tombstones for shifts in this rota.
    let shift_ids: Vec<(i64,)> =
        sqlx::query_as("SELECT id FROM shifts WHERE rota_id = ?")
            .bind(id)
            .fetch_all(pool)
            .await?;
    for (sid,) in &shift_ids {
        insert_tombstone(pool, "shifts", *sid).await?;
    }

    sqlx::query("DELETE FROM shifts WHERE rota_id = ?")
        .bind(id)
        .execute(pool)
        .await?;

    // Insert tombstone for the rota itself.
    insert_tombstone(pool, "rotas", id).await?;
    sqlx::query("DELETE FROM rotas WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn finalize_rota(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query("UPDATE rotas SET finalized = 1, last_modified = ?, sync_status = 0 WHERE id = ?")
        .bind(&now)
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

// ─── Shifts ──────────────────────────────────────────────────

pub async fn insert_shift(pool: &SqlitePool, shift: &Shift) -> Result<i64, sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO shifts (template_id, rota_id, date, start_time, end_time, required_role, min_employees, max_employees, last_modified, sync_status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0) RETURNING id",
    )
    .bind(shift.template_id)
    .bind(shift.rota_id)
    .bind(shift.date.to_string())
    .bind(shift.start_time.to_string())
    .bind(shift.end_time.to_string())
    .bind(&shift.required_role)
    .bind(shift.min_employees)
    .bind(shift.max_employees)
    .bind(&now)
    .fetch_one(pool)
    .await?;

    Ok(id)
}

pub async fn list_shifts_for_rota(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<Vec<Shift>, sqlx::Error> {
    let rows: Vec<ShiftRow> = sqlx::query_as(
        "SELECT id, template_id, rota_id, date, start_time, end_time, required_role, min_employees, max_employees
         FROM shifts WHERE rota_id = ? ORDER BY date, start_time",
    )
    .bind(rota_id)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().filter_map(shift_from_row).collect())
}

fn shift_from_row(row: ShiftRow) -> Option<Shift> {
    let (id, template_id, rota_id, date_str, start_str, end_str, required_role, min_emp, max_emp) =
        row;
    Some(Shift {
        id,
        template_id,
        rota_id,
        date: NaiveDate::parse_from_str(&date_str, "%Y-%m-%d").ok()?,
        start_time: NaiveTime::parse_from_str(&start_str, "%H:%M:%S").ok()?,
        end_time: NaiveTime::parse_from_str(&end_str, "%H:%M:%S").ok()?,
        required_role,
        min_employees: min_emp,
        max_employees: max_emp,
    })
}

// ─── Assignments ─────────────────────────────────────────────

pub async fn insert_assignment(
    pool: &SqlitePool,
    assignment: &Assignment,
) -> Result<i64, sqlx::Error> {
    let status_str = assignment.status.to_string();

    let now = chrono::Utc::now().to_rfc3339();
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO assignments (rota_id, shift_id, employee_id, status, employee_name, hourly_wage, last_modified, sync_status)
         VALUES (?, ?, ?, ?, ?, ?, ?, 0) RETURNING id",
    )
    .bind(assignment.rota_id)
    .bind(assignment.shift_id)
    .bind(assignment.employee_id)
    .bind(&status_str)
    .bind(&assignment.employee_name)
    .bind(assignment.hourly_wage)
    .bind(&now)
    .fetch_one(pool)
    .await?;

    Ok(id)
}

pub async fn list_assignments_for_rota(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<Vec<Assignment>, sqlx::Error> {
    let rows: Vec<(i64, i64, i64, i64, String, Option<String>, Option<f64>)> = sqlx::query_as(
        "SELECT id, rota_id, shift_id, employee_id, status, employee_name, hourly_wage
         FROM assignments WHERE rota_id = ? ORDER BY id",
    )
    .bind(rota_id)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().filter_map(assignment_from_row).collect())
}

pub async fn delete_shifts_for_rota(pool: &SqlitePool, rota_id: i64) -> Result<(), sqlx::Error> {
    // Only delete template-based shifts; preserve ad-hoc shifts (template_id IS NULL).
    // Insert tombstones for all affected shifts first.
    let ids: Vec<(i64,)> =
        sqlx::query_as("SELECT id FROM shifts WHERE rota_id = ? AND template_id IS NOT NULL")
            .bind(rota_id)
            .fetch_all(pool)
            .await?;
    for (sid,) in &ids {
        insert_tombstone(pool, "shifts", *sid).await?;
    }
    sqlx::query("DELETE FROM shifts WHERE rota_id = ? AND template_id IS NOT NULL")
        .bind(rota_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn delete_shift(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    insert_tombstone(pool, "shifts", id).await?;
    sqlx::query("DELETE FROM shifts WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn update_shift_times(
    pool: &SqlitePool,
    id: i64,
    start_time: NaiveTime,
    end_time: NaiveTime,
) -> Result<(), sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query("UPDATE shifts SET start_time = ?, end_time = ?, last_modified = ?, sync_status = 0 WHERE id = ?")
        .bind(start_time.to_string())
        .bind(end_time.to_string())
        .bind(&now)
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn delete_proposed_assignments(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<(), sqlx::Error> {
    // Insert tombstones for all affected assignments first.
    let ids: Vec<(i64,)> =
        sqlx::query_as("SELECT id FROM assignments WHERE rota_id = ? AND status = 'Proposed'")
            .bind(rota_id)
            .fetch_all(pool)
            .await?;
    for (aid,) in &ids {
        insert_tombstone(pool, "assignments", *aid).await?;
    }
    sqlx::query("DELETE FROM assignments WHERE rota_id = ? AND status = 'Proposed'")
        .bind(rota_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn update_assignment_status(
    pool: &SqlitePool,
    id: i64,
    status: AssignmentStatus,
) -> Result<(), sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query("UPDATE assignments SET status = ?, last_modified = ?, sync_status = 0 WHERE id = ?")
        .bind(status.to_string())
        .bind(&now)
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn update_assignment_shift(
    pool: &SqlitePool,
    id: i64,
    new_shift_id: i64,
) -> Result<(), sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query("UPDATE assignments SET shift_id = ?, last_modified = ?, sync_status = 0 WHERE id = ?")
        .bind(new_shift_id)
        .bind(&now)
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn swap_assignment_shifts(
    pool: &SqlitePool,
    id_a: i64,
    shift_a: i64,
    id_b: i64,
    shift_b: i64,
) -> Result<(), sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    // Swap: A gets B's shift, B gets A's shift
    sqlx::query("UPDATE assignments SET shift_id = ?, last_modified = ?, sync_status = 0 WHERE id = ?")
        .bind(shift_b)
        .bind(&now)
        .bind(id_a)
        .execute(pool)
        .await?;
    sqlx::query("UPDATE assignments SET shift_id = ?, last_modified = ?, sync_status = 0 WHERE id = ?")
        .bind(shift_a)
        .bind(&now)
        .bind(id_b)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn delete_assignment(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    insert_tombstone(pool, "assignments", id).await?;
    sqlx::query("DELETE FROM assignments WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

fn assignment_from_row(row: (i64, i64, i64, i64, String, Option<String>, Option<f64>)) -> Option<Assignment> {
    let (id, rota_id, shift_id, employee_id, status_str, employee_name, hourly_wage) = row;
    Some(Assignment {
        id,
        rota_id,
        shift_id,
        employee_id,
        status: status_str.parse().ok()?,
        employee_name,
        hourly_wage: hourly_wage.map(|v| v as f32),
    })
}

// ─── Roles ──────────────────────────────────────────────────

pub async fn list_roles(pool: &SqlitePool) -> Result<Vec<Role>, sqlx::Error> {
    let rows: Vec<(i64, String)> =
        sqlx::query_as("SELECT id, name FROM roles ORDER BY name")
            .fetch_all(pool)
            .await?;

    Ok(rows
        .into_iter()
        .map(|(id, name)| Role { id, name })
        .collect())
}

pub async fn insert_role(pool: &SqlitePool, name: &str) -> Result<i64, sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    let id: i64 =
        sqlx::query_scalar("INSERT INTO roles (name, last_modified, sync_status) VALUES (?, ?, 0) RETURNING id")
            .bind(name)
            .bind(&now)
            .fetch_one(pool)
            .await?;

    Ok(id)
}

pub async fn update_role(pool: &SqlitePool, id: i64, new_name: &str) -> Result<(), sqlx::Error> {
    // Get the old name first.
    let old_name: String =
        sqlx::query_scalar("SELECT name FROM roles WHERE id = ?")
            .bind(id)
            .fetch_one(pool)
            .await?;

    if old_name == new_name {
        return Ok(());
    }

    let now = chrono::Utc::now().to_rfc3339();

    // Update the role name.
    sqlx::query("UPDATE roles SET name = ?, last_modified = ?, sync_status = 0 WHERE id = ?")
        .bind(new_name)
        .bind(&now)
        .bind(id)
        .execute(pool)
        .await?;

    // Cascade: update shift_templates.required_role
    sqlx::query("UPDATE shift_templates SET required_role = ?, last_modified = ?, sync_status = 0 WHERE required_role = ?")
        .bind(new_name)
        .bind(&now)
        .bind(&old_name)
        .execute(pool)
        .await?;

    // Cascade: update shifts.required_role
    sqlx::query("UPDATE shifts SET required_role = ?, last_modified = ?, sync_status = 0 WHERE required_role = ?")
        .bind(new_name)
        .bind(&now)
        .bind(&old_name)
        .execute(pool)
        .await?;

    // Cascade: update employees.roles JSON arrays.
    // Load all employees whose roles JSON contains the old name, update in Rust, write back.
    let rows: Vec<(i64, String)> = sqlx::query_as(
        "SELECT id, roles FROM employees WHERE roles LIKE '%' || ? || '%'",
    )
    .bind(&old_name)
    .fetch_all(pool)
    .await?;

    for (emp_id, roles_json) in rows {
        let mut roles: Vec<String> = serde_json::from_str(&roles_json).unwrap_or_default();
        for r in &mut roles {
            if r == &old_name {
                *r = new_name.to_string();
            }
        }
        let updated_json = serde_json::to_string(&roles).unwrap_or_default();
        sqlx::query("UPDATE employees SET roles = ?, last_modified = ?, sync_status = 0 WHERE id = ?")
            .bind(&updated_json)
            .bind(&now)
            .bind(emp_id)
            .execute(pool)
            .await?;
    }

    Ok(())
}

pub async fn delete_role(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    // Check if any shift templates reference this role.
    let role_name: String =
        sqlx::query_scalar("SELECT name FROM roles WHERE id = ?")
            .bind(id)
            .fetch_one(pool)
            .await?;

    let tmpl_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM shift_templates WHERE required_role = ? AND deleted = 0",
    )
    .bind(&role_name)
    .fetch_one(pool)
    .await?;

    if tmpl_count > 0 {
        return Err(sqlx::Error::Protocol(format!(
            "Cannot delete role '{}': still used by {} shift template(s)",
            role_name, tmpl_count
        )));
    }

    // Check if any employees reference this role.
    let emp_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM employees WHERE roles LIKE '%' || ? || '%' AND deleted = 0",
    )
    .bind(&role_name)
    .fetch_one(pool)
    .await?;

    if emp_count > 0 {
        return Err(sqlx::Error::Protocol(format!(
            "Cannot delete role '{}': still assigned to {} employee(s)",
            role_name, emp_count
        )));
    }

    insert_tombstone(pool, "roles", id).await?;
    sqlx::query("DELETE FROM roles WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;

    Ok(())
}

// ─── Employee Availability Overrides ─────────────────────────

/// Insert or replace an employee availability override (one per employee+date).
pub async fn upsert_employee_availability_override(
    pool: &SqlitePool,
    ovr: &EmployeeAvailabilityOverride,
) -> Result<i64, sqlx::Error> {
    let avail_json = ovr.availability.to_json().unwrap_or_default();
    let now = chrono::Utc::now().to_rfc3339();
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO employee_availability_overrides (employee_id, date, availability, notes, last_modified, sync_status)
         VALUES (?, ?, ?, ?, ?, 0)
         ON CONFLICT(employee_id, date) DO UPDATE SET availability = excluded.availability, notes = excluded.notes, last_modified = excluded.last_modified, sync_status = 0
         RETURNING id",
    )
    .bind(ovr.employee_id)
    .bind(ovr.date.to_string())
    .bind(&avail_json)
    .bind(&ovr.notes)
    .bind(&now)
    .fetch_one(pool)
    .await?;
    Ok(id)
}

pub async fn get_employee_availability_override(
    pool: &SqlitePool,
    employee_id: i64,
    date: NaiveDate,
) -> Result<Option<EmployeeAvailabilityOverride>, sqlx::Error> {
    let row: Option<(i64, i64, String, String, Option<String>)> = sqlx::query_as(
        "SELECT id, employee_id, date, availability, notes
         FROM employee_availability_overrides WHERE employee_id = ? AND date = ?",
    )
    .bind(employee_id)
    .bind(date.to_string())
    .fetch_optional(pool)
    .await?;
    Ok(row.and_then(employee_avail_override_from_row))
}

pub async fn list_employee_availability_overrides_for_employee(
    pool: &SqlitePool,
    employee_id: i64,
) -> Result<Vec<EmployeeAvailabilityOverride>, sqlx::Error> {
    let rows: Vec<(i64, i64, String, String, Option<String>)> = sqlx::query_as(
        "SELECT id, employee_id, date, availability, notes
         FROM employee_availability_overrides WHERE employee_id = ? ORDER BY date",
    )
    .bind(employee_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().filter_map(employee_avail_override_from_row).collect())
}

pub async fn list_all_employee_availability_overrides(
    pool: &SqlitePool,
) -> Result<Vec<EmployeeAvailabilityOverride>, sqlx::Error> {
    let rows: Vec<(i64, i64, String, String, Option<String>)> = sqlx::query_as(
        "SELECT id, employee_id, date, availability, notes
         FROM employee_availability_overrides ORDER BY date, employee_id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().filter_map(employee_avail_override_from_row).collect())
}

pub async fn delete_employee_availability_override(
    pool: &SqlitePool,
    id: i64,
) -> Result<(), sqlx::Error> {
    insert_tombstone(pool, "employee_availability_overrides", id).await?;
    sqlx::query("DELETE FROM employee_availability_overrides WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

fn employee_avail_override_from_row(
    row: (i64, i64, String, String, Option<String>),
) -> Option<EmployeeAvailabilityOverride> {
    let (id, employee_id, date_str, avail_json, notes) = row;
    Some(EmployeeAvailabilityOverride {
        id,
        employee_id,
        date: NaiveDate::parse_from_str(&date_str, "%Y-%m-%d").ok()?,
        availability: DayAvailability::from_json(&avail_json).unwrap_or_default(),
        notes,
    })
}

// ─── Shift Template Overrides ─────────────────────────────────

/// Insert or replace a shift template override (one per template+date).
pub async fn upsert_shift_template_override(
    pool: &SqlitePool,
    ovr: &ShiftTemplateOverride,
) -> Result<i64, sqlx::Error> {
    let start_str = ovr.start_time.map(|t| t.format("%H:%M:%S").to_string());
    let end_str = ovr.end_time.map(|t| t.format("%H:%M:%S").to_string());
    let now = chrono::Utc::now().to_rfc3339();
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO shift_template_overrides (template_id, date, cancelled, start_time, end_time, min_employees, max_employees, notes, last_modified, sync_status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
         ON CONFLICT(template_id, date) DO UPDATE SET
           cancelled = excluded.cancelled,
           start_time = excluded.start_time,
           end_time = excluded.end_time,
           min_employees = excluded.min_employees,
           max_employees = excluded.max_employees,
           notes = excluded.notes,
           last_modified = excluded.last_modified,
           sync_status = 0
         RETURNING id",
    )
    .bind(ovr.template_id)
    .bind(ovr.date.to_string())
    .bind(ovr.cancelled as i64)
    .bind(&start_str)
    .bind(&end_str)
    .bind(ovr.min_employees.map(|v| v as i64))
    .bind(ovr.max_employees.map(|v| v as i64))
    .bind(&ovr.notes)
    .bind(&now)
    .fetch_one(pool)
    .await?;
    Ok(id)
}

pub async fn get_shift_template_override(
    pool: &SqlitePool,
    template_id: i64,
    date: NaiveDate,
) -> Result<Option<ShiftTemplateOverride>, sqlx::Error> {
    let row: Option<(i64, i64, String, i64, Option<String>, Option<String>, Option<i64>, Option<i64>, Option<String>)> = sqlx::query_as(
        "SELECT id, template_id, date, cancelled, start_time, end_time, min_employees, max_employees, notes
         FROM shift_template_overrides WHERE template_id = ? AND date = ?",
    )
    .bind(template_id)
    .bind(date.to_string())
    .fetch_optional(pool)
    .await?;
    Ok(row.and_then(shift_template_override_from_row))
}

pub async fn list_shift_template_overrides_for_template(
    pool: &SqlitePool,
    template_id: i64,
) -> Result<Vec<ShiftTemplateOverride>, sqlx::Error> {
    let rows: Vec<(i64, i64, String, i64, Option<String>, Option<String>, Option<i64>, Option<i64>, Option<String>)> = sqlx::query_as(
        "SELECT id, template_id, date, cancelled, start_time, end_time, min_employees, max_employees, notes
         FROM shift_template_overrides WHERE template_id = ? ORDER BY date",
    )
    .bind(template_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().filter_map(shift_template_override_from_row).collect())
}

pub async fn list_all_shift_template_overrides(
    pool: &SqlitePool,
) -> Result<Vec<ShiftTemplateOverride>, sqlx::Error> {
    let rows: Vec<(i64, i64, String, i64, Option<String>, Option<String>, Option<i64>, Option<i64>, Option<String>)> = sqlx::query_as(
        "SELECT id, template_id, date, cancelled, start_time, end_time, min_employees, max_employees, notes
         FROM shift_template_overrides ORDER BY date, template_id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().filter_map(shift_template_override_from_row).collect())
}

pub async fn delete_shift_template_override(
    pool: &SqlitePool,
    id: i64,
) -> Result<(), sqlx::Error> {
    insert_tombstone(pool, "shift_template_overrides", id).await?;
    sqlx::query("DELETE FROM shift_template_overrides WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

fn shift_template_override_from_row(
    row: (i64, i64, String, i64, Option<String>, Option<String>, Option<i64>, Option<i64>, Option<String>),
) -> Option<ShiftTemplateOverride> {
    let (id, template_id, date_str, cancelled, start_str, end_str, min_emp, max_emp, notes) = row;
    Some(ShiftTemplateOverride {
        id,
        template_id,
        date: NaiveDate::parse_from_str(&date_str, "%Y-%m-%d").ok()?,
        cancelled: cancelled != 0,
        start_time: start_str.as_deref().and_then(|s| NaiveTime::parse_from_str(s, "%H:%M:%S").ok()),
        end_time: end_str.as_deref().and_then(|s| NaiveTime::parse_from_str(s, "%H:%M:%S").ok()),
        min_employees: min_emp.map(|v| v as u32),
        max_employees: max_emp.map(|v| v as u32),
        notes,
    })
}

// ─── Shift History ───────────────────────────────────────────

type ShiftHistoryRow = (
    i64, i64, i64, i64, String, Option<String>, Option<f64>,
    String, String, String, String,
    String, bool,
);

fn shift_record_from_row(row: ShiftHistoryRow) -> Option<EmployeeShiftRecord> {
    let (
        assignment_id, rota_id, shift_id, employee_id, status_str, employee_name, hourly_wage,
        date_str, start_str, end_str, required_role,
        week_start_str, finalized,
    ) = row;
    Some(EmployeeShiftRecord {
        assignment_id,
        rota_id,
        shift_id,
        employee_id,
        status: status_str.parse::<AssignmentStatus>().ok()?,
        employee_name,
        hourly_wage: hourly_wage.map(|v| v as f32),
        date: NaiveDate::parse_from_str(&date_str, "%Y-%m-%d").ok()?,
        start_time: NaiveTime::parse_from_str(&start_str, "%H:%M:%S").ok()?,
        end_time: NaiveTime::parse_from_str(&end_str, "%H:%M:%S").ok()?,
        required_role,
        week_start: NaiveDate::parse_from_str(&week_start_str, "%Y-%m-%d").ok()?,
        finalized,
    })
}

pub async fn list_employee_shift_history(
    pool: &SqlitePool,
    employee_id: i64,
) -> Result<Vec<EmployeeShiftRecord>, sqlx::Error> {
    let rows: Vec<ShiftHistoryRow> = sqlx::query_as(
        "SELECT a.id, a.rota_id, a.shift_id, a.employee_id, a.status, a.employee_name, a.hourly_wage,
                s.date, s.start_time, s.end_time, s.required_role,
                r.week_start, r.finalized
         FROM assignments a
         JOIN shifts s ON s.id = a.shift_id
         JOIN rotas r ON r.id = a.rota_id
         WHERE a.employee_id = ?
         ORDER BY s.date, s.start_time",
    )
    .bind(employee_id)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().filter_map(shift_record_from_row).collect())
}

// ─── Sync ───────────────────────────────────────────────────

pub async fn get_sync_metadata(pool: &SqlitePool, key: &str) -> Result<Option<String>, sqlx::Error> {
    sqlx::query_scalar("SELECT value FROM sync_metadata WHERE key = ?")
        .bind(key)
        .fetch_optional(pool)
        .await
}

pub async fn set_sync_metadata(pool: &SqlitePool, key: &str, value: &str) -> Result<(), sqlx::Error> {
    sqlx::query("INSERT INTO sync_metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        .bind(key)
        .bind(value)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn insert_tombstone(pool: &SqlitePool, table_name: &str, record_id: i64) -> Result<i64, sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    let result = sqlx::query("INSERT INTO sync_tombstones (table_name, record_id, deleted_at) VALUES (?, ?, ?)")
        .bind(table_name)
        .bind(record_id)
        .bind(&now)
        .execute(pool)
        .await?;
    Ok(result.last_insert_rowid())
}

pub async fn get_pending_tombstones(pool: &SqlitePool) -> Result<Vec<Tombstone>, sqlx::Error> {
    let rows: Vec<(i64, String, i64, String)> = sqlx::query_as(
        "SELECT id, table_name, record_id, deleted_at FROM sync_tombstones ORDER BY id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(id, table_name, record_id, deleted_at)| Tombstone {
            id,
            table_name,
            record_id,
            deleted_at,
        })
        .collect())
}

pub async fn clear_tombstones(pool: &SqlitePool, ids: &[i64]) -> Result<(), sqlx::Error> {
    if ids.is_empty() {
        return Ok(());
    }
    let placeholders: String = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!(
        "DELETE FROM sync_tombstones WHERE id IN ({})",
        placeholders
    );
    let mut query = sqlx::query(&sql);
    for id in ids {
        query = query.bind(id);
    }
    query.execute(pool).await?;
    Ok(())
}

pub async fn get_pending_sync_records(
    pool: &SqlitePool,
    table_name: &str,
) -> Result<Vec<SyncRecord>, sqlx::Error> {
    let columns = syncable_columns(table_name);
    let json_pairs: String = columns
        .iter()
        .map(|c| format!("'{}', {}", c, c))
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "SELECT id, json_object({}) AS fields, last_modified FROM {} WHERE sync_status = 0",
        json_pairs, table_name
    );
    let rows: Vec<(i64, String, String)> = sqlx::query_as(&sql).fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .map(|(record_id, fields, last_modified)| SyncRecord {
            table_name: table_name.to_string(),
            record_id,
            fields,
            last_modified,
        })
        .collect())
}

pub fn syncable_columns(table_name: &str) -> Vec<&'static str> {
    match table_name {
        "employees" => vec![
            "id", "first_name", "last_name", "nickname", "roles", "start_date",
            "target_weekly_hours", "weekly_hours_deviation", "max_daily_hours", "notes",
            "bank_details", "hourly_wage", "wage_currency", "default_availability",
            "availability", "deleted", "last_modified",
        ],
        "shift_templates" => vec![
            "id", "name", "weekdays", "start_time", "end_time", "required_role",
            "min_employees", "max_employees", "deleted", "last_modified",
        ],
        "rotas" => vec!["id", "week_start", "finalized", "last_modified"],
        "shifts" => vec![
            "id", "template_id", "rota_id", "date", "start_time", "end_time",
            "required_role", "min_employees", "max_employees", "last_modified",
        ],
        "assignments" => vec![
            "id", "rota_id", "shift_id", "employee_id", "status", "employee_name",
            "hourly_wage", "last_modified",
        ],
        "roles" => vec!["id", "name", "last_modified"],
        "employee_availability_overrides" => vec![
            "id", "employee_id", "date", "availability", "notes", "last_modified",
        ],
        "shift_template_overrides" => vec![
            "id", "template_id", "date", "cancelled", "start_time", "end_time",
            "min_employees", "max_employees", "notes", "last_modified",
        ],
        _ => vec![],
    }
}

pub async fn mark_records_synced(
    pool: &SqlitePool,
    table_name: &str,
    record_ids: &[i64],
    base_snapshots: &[String],
) -> Result<(), sqlx::Error> {
    for (id, snapshot) in record_ids.iter().zip(base_snapshots.iter()) {
        let sql = format!(
            "UPDATE {} SET sync_status = 1, sync_base_snapshot = ? WHERE id = ?",
            table_name
        );
        sqlx::query(&sql)
            .bind(snapshot)
            .bind(id)
            .execute(pool)
            .await?;
    }
    Ok(())
}

pub async fn get_base_snapshots(
    pool: &SqlitePool,
    table_name: &str,
    record_ids: &[i64],
) -> Result<Vec<BaseSnapshot>, sqlx::Error> {
    if record_ids.is_empty() {
        return Ok(vec![]);
    }
    let placeholders: String = record_ids
        .iter()
        .map(|_| "?")
        .collect::<Vec<_>>()
        .join(",");
    let sql = format!(
        "SELECT id, sync_base_snapshot FROM {} WHERE id IN ({}) AND sync_base_snapshot IS NOT NULL",
        table_name, placeholders
    );
    let mut query = sqlx::query_as::<_, (i64, String)>(&sql);
    for id in record_ids {
        query = query.bind(id);
    }
    let rows = query.fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .map(|(record_id, snapshot)| BaseSnapshot {
            record_id,
            snapshot,
        })
        .collect())
}

pub async fn apply_remote_record(
    pool: &SqlitePool,
    record: &SyncRecord,
) -> Result<(), sqlx::Error> {
    let columns = syncable_columns(&record.table_name);
    let _fields: serde_json::Value = serde_json::from_str(&record.fields)
        .map_err(|e| sqlx::Error::Protocol(e.to_string()))?;

    let exists: bool = sqlx::query_scalar(&format!(
        "SELECT COUNT(*) > 0 FROM {} WHERE id = ?",
        record.table_name
    ))
    .bind(record.record_id)
    .fetch_one(pool)
    .await?;

    if exists {
        let set_clauses: Vec<String> = columns
            .iter()
            .filter(|c| **c != "id")
            .map(|c| format!("{} = json_extract(?, '$.{}')", c, c))
            .collect();
        let sql = format!(
            "UPDATE {} SET {}, sync_status = 1, sync_base_snapshot = ? WHERE id = ?",
            record.table_name,
            set_clauses.join(", ")
        );
        let mut query = sqlx::query(&sql);
        for _ in columns.iter().filter(|c| **c != "id") {
            query = query.bind(&record.fields);
        }
        query = query.bind(&record.fields).bind(record.record_id);
        query.execute(pool).await?;
    } else {
        let col_list = columns.join(", ");
        let value_exprs: Vec<String> = columns
            .iter()
            .map(|c| format!("json_extract(?, '$.{}')", c))
            .collect();
        let sql = format!(
            "INSERT INTO {} ({}, sync_status, sync_base_snapshot) VALUES ({}, 1, ?)",
            record.table_name,
            col_list,
            value_exprs.join(", ")
        );
        let mut query = sqlx::query(&sql);
        for _ in &columns {
            query = query.bind(&record.fields);
        }
        query = query.bind(&record.fields);
        query.execute(pool).await?;
    }
    Ok(())
}
