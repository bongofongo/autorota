use chrono::{NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;

use crate::models::assignment::{Assignment, AssignmentStatus};
use crate::models::availability::Availability;
use crate::models::employee::Employee;
use crate::models::overrides::{
    DayAvailability, EmployeeAvailabilityOverride, OverrideSource, ShiftTemplateOverride,
};
use crate::models::role::Role;
use crate::models::rota::Rota;
use crate::models::save::{
    ChangeDetail, RestoreResult, Save, SaveAssignmentSnapshot,
    SaveEmployeeAvailabilityOverrideSnapshot, SaveShiftSnapshot, SaveSnapshot, ShiftDiff,
    diff_snapshots,
};
use crate::models::shift::{Shift, ShiftTemplate};
use crate::models::shift_history::EmployeeShiftRecord;
use crate::models::sync::{BaseSnapshot, SyncRecord, Tombstone};
use std::collections::{HashMap, HashSet};

type ShiftTemplateRow = (i64, String, String, String, String, String, u32, u32, bool);
type ShiftRow = (
    i64,
    Option<i64>,
    i64,
    String,
    String,
    String,
    String,
    u32,
    u32,
);

// ─── Employees ───────────────────────────────────────────────

pub async fn insert_employee(pool: &SqlitePool, emp: &Employee) -> Result<i64, sqlx::Error> {
    let roles_json = serde_json::to_string(&emp.roles).unwrap_or_default();
    let default_avail = emp.default_availability.to_json().unwrap_or_default();
    let avail = emp.availability.to_json().unwrap_or_default();
    let now = chrono::Utc::now().to_rfc3339();

    let id = sqlx::query_scalar(
        "INSERT INTO employees (first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, phone, email, preferred_contact, hourly_wage, wage_currency, default_availability, availability, last_modified, sync_status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) RETURNING id",
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
    .bind(&emp.phone)
    .bind(&emp.email)
    .bind(&emp.preferred_contact)
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
    let row: Option<EmployeeRow> = sqlx::query_as(
        "SELECT id, first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, phone, email, preferred_contact, hourly_wage, wage_currency, default_availability, availability, deleted
         FROM employees WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(employee_from_row))
}

pub async fn list_employees(pool: &SqlitePool) -> Result<Vec<Employee>, sqlx::Error> {
    let rows: Vec<EmployeeRow> = sqlx::query_as(
        "SELECT id, first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, phone, email, preferred_contact, hourly_wage, wage_currency, default_availability, availability, deleted
         FROM employees WHERE deleted = 0 ORDER BY start_date",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(employee_from_row).collect())
}

/// List all employees including soft-deleted ones (for historical schedule display).
pub async fn list_all_employees(pool: &SqlitePool) -> Result<Vec<Employee>, sqlx::Error> {
    let rows: Vec<EmployeeRow> = sqlx::query_as(
        "SELECT id, first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, phone, email, preferred_contact, hourly_wage, wage_currency, default_availability, availability, deleted
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
         notes = ?, bank_details = ?, phone = ?, email = ?, preferred_contact = ?, hourly_wage = ?, wage_currency = ?, default_availability = ?, availability = ?, last_modified = ?, sync_status = 0 WHERE id = ?",
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
    .bind(&emp.phone)
    .bind(&emp.email)
    .bind(&emp.preferred_contact)
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
    sqlx::query(
        "UPDATE employees SET deleted = 1, last_modified = ?, sync_status = 0 WHERE id = ?",
    )
    .bind(&now)
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

#[derive(sqlx::FromRow)]
struct EmployeeRow {
    id: i64,
    first_name: String,
    last_name: String,
    nickname: Option<String>,
    roles: String,
    start_date: String,
    target_weekly_hours: f64,
    weekly_hours_deviation: f64,
    max_daily_hours: f64,
    notes: Option<String>,
    bank_details: Option<String>,
    phone: Option<String>,
    email: Option<String>,
    preferred_contact: Option<String>,
    hourly_wage: Option<f64>,
    wage_currency: Option<String>,
    default_availability: String,
    availability: String,
    deleted: bool,
}

fn employee_from_row(row: EmployeeRow) -> Employee {
    let EmployeeRow {
        id,
        first_name,
        last_name,
        nickname,
        roles: roles_json,
        start_date: start_date_str,
        target_weekly_hours: target_weekly,
        weekly_hours_deviation: deviation,
        max_daily_hours: max_daily,
        notes,
        bank_details,
        phone,
        email,
        preferred_contact,
        hourly_wage,
        wage_currency,
        default_availability: default_avail_json,
        availability: avail_json,
        deleted,
    } = row;
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
        phone,
        email,
        preferred_contact,
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
    sqlx::query(
        "UPDATE shift_templates SET deleted = 1, last_modified = ?, sync_status = 0 WHERE id = ?",
    )
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
    let (id, name, weekdays_str, start_str, end_str, required_role, min_emp, max_emp, deleted) =
        row;
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
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO rotas (week_start, last_modified, sync_status) VALUES (?, ?, 0) RETURNING id",
    )
    .bind(week_start.to_string())
    .bind(&now)
    .fetch_one(pool)
    .await?;

    Ok(id)
}

pub async fn get_rota(pool: &SqlitePool, id: i64) -> Result<Option<Rota>, sqlx::Error> {
    let row: Option<(i64, String)> =
        sqlx::query_as("SELECT id, week_start FROM rotas WHERE id = ?")
            .bind(id)
            .fetch_optional(pool)
            .await?;

    let Some((rota_id, week_start_str)) = row else {
        return Ok(None);
    };

    let week_start = NaiveDate::parse_from_str(&week_start_str, "%Y-%m-%d")
        .unwrap_or_else(|_| NaiveDate::default());

    let assignments = list_assignments_for_rota(pool, rota_id).await?;

    Ok(Some(Rota {
        id: rota_id,
        week_start,
        assignments,
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

/// Fetch all rotas whose `week_start` falls within the given date range
/// (inclusive). Calulates the Monday-aligned week boundaries automatically.
pub async fn get_rotas_in_range(
    pool: &SqlitePool,
    start_date: NaiveDate,
    end_date: NaiveDate,
) -> Result<Vec<Rota>, sqlx::Error> {
    use chrono::Datelike;

    // Align to Monday of each bounding week.
    let first_monday =
        start_date - chrono::Duration::days(start_date.weekday().num_days_from_monday() as i64);
    let last_monday =
        end_date - chrono::Duration::days(end_date.weekday().num_days_from_monday() as i64);

    let rows: Vec<(i64,)> = sqlx::query_as(
        "SELECT id FROM rotas WHERE week_start >= ? AND week_start <= ? ORDER BY week_start",
    )
    .bind(first_monday.to_string())
    .bind(last_monday.to_string())
    .fetch_all(pool)
    .await?;

    let mut rotas = Vec::with_capacity(rows.len());
    for (id,) in rows {
        if let Some(rota) = get_rota(pool, id).await? {
            rotas.push(rota);
        }
    }
    Ok(rotas)
}

/// Delete a rota and all its data. Deletes all shifts first (which cascades
/// to assignments via the ON DELETE CASCADE FK), then removes the rota row.
pub async fn delete_rota(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    // Insert tombstones for assignments belonging to shifts in this rota.
    let assignment_ids: Vec<i64> = sqlx::query_scalar(
        "SELECT a.id FROM assignments a JOIN shifts s ON s.id = a.shift_id WHERE s.rota_id = ?",
    )
    .bind(id)
    .fetch_all(pool)
    .await?;
    insert_tombstones(pool, "assignments", &assignment_ids).await?;

    // Insert tombstones for shifts in this rota.
    let shift_ids: Vec<i64> = sqlx::query_scalar("SELECT id FROM shifts WHERE rota_id = ?")
        .bind(id)
        .fetch_all(pool)
        .await?;
    insert_tombstones(pool, "shifts", &shift_ids).await?;

    // Delete assignments explicitly (FK CASCADE on shift_id may not fire
    // if foreign_keys pragma is not enabled on the pool connection).
    sqlx::query(
        "DELETE FROM assignments WHERE shift_id IN (SELECT id FROM shifts WHERE rota_id = ?)",
    )
    .bind(id)
    .execute(pool)
    .await?;

    sqlx::query("DELETE FROM shifts WHERE rota_id = ?")
        .bind(id)
        .execute(pool)
        .await?;

    // Delete any saves for this rota.
    sqlx::query("DELETE FROM saves WHERE rota_id = ?")
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
    let ids: Vec<i64> =
        sqlx::query_scalar("SELECT id FROM shifts WHERE rota_id = ? AND template_id IS NOT NULL")
            .bind(rota_id)
            .fetch_all(pool)
            .await?;
    insert_tombstones(pool, "shifts", &ids).await?;
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
    let ids: Vec<i64> =
        sqlx::query_scalar("SELECT id FROM assignments WHERE rota_id = ? AND status = 'Proposed'")
            .bind(rota_id)
            .fetch_all(pool)
            .await?;
    insert_tombstones(pool, "assignments", &ids).await?;
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
    sqlx::query(
        "UPDATE assignments SET status = ?, last_modified = ?, sync_status = 0 WHERE id = ?",
    )
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
    sqlx::query(
        "UPDATE assignments SET shift_id = ?, last_modified = ?, sync_status = 0 WHERE id = ?",
    )
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
    sqlx::query(
        "UPDATE assignments SET shift_id = ?, last_modified = ?, sync_status = 0 WHERE id = ?",
    )
    .bind(shift_b)
    .bind(&now)
    .bind(id_a)
    .execute(pool)
    .await?;
    sqlx::query(
        "UPDATE assignments SET shift_id = ?, last_modified = ?, sync_status = 0 WHERE id = ?",
    )
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

fn assignment_from_row(
    row: (i64, i64, i64, i64, String, Option<String>, Option<f64>),
) -> Option<Assignment> {
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
    let rows: Vec<(i64, String)> = sqlx::query_as("SELECT id, name FROM roles ORDER BY name")
        .fetch_all(pool)
        .await?;

    Ok(rows
        .into_iter()
        .map(|(id, name)| Role { id, name })
        .collect())
}

pub async fn insert_role(pool: &SqlitePool, name: &str) -> Result<i64, sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO roles (name, last_modified, sync_status) VALUES (?, ?, 0) RETURNING id",
    )
    .bind(name)
    .bind(&now)
    .fetch_one(pool)
    .await?;

    Ok(id)
}

pub async fn update_role(pool: &SqlitePool, id: i64, new_name: &str) -> Result<(), sqlx::Error> {
    // Get the old name first.
    let old_name: String = sqlx::query_scalar("SELECT name FROM roles WHERE id = ?")
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
    let rows: Vec<(i64, String)> =
        sqlx::query_as("SELECT id, roles FROM employees WHERE roles LIKE '%' || ? || '%'")
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
        sqlx::query(
            "UPDATE employees SET roles = ?, last_modified = ?, sync_status = 0 WHERE id = ?",
        )
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
    let role_name: String = sqlx::query_scalar("SELECT name FROM roles WHERE id = ?")
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
    // `source` is NOT updated on conflict — once a row is classified as
    // "exception" (via the Exceptions UI) we do not want a subsequent edit
    // through the regular availability grid to silently downgrade it to
    // "manual". Upgrades from manual → exception likewise preserve whatever
    // the UI originally chose.
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO employee_availability_overrides (employee_id, date, availability, notes, source, last_modified, sync_status)
         VALUES (?, ?, ?, ?, ?, ?, 0)
         ON CONFLICT(employee_id, date) DO UPDATE SET availability = excluded.availability, notes = excluded.notes, last_modified = excluded.last_modified, sync_status = 0
         RETURNING id",
    )
    .bind(ovr.employee_id)
    .bind(ovr.date.to_string())
    .bind(&avail_json)
    .bind(&ovr.notes)
    .bind(ovr.source.as_str())
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
    let row: Option<(i64, i64, String, String, Option<String>, String)> = sqlx::query_as(
        "SELECT id, employee_id, date, availability, notes, source
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
    let rows: Vec<(i64, i64, String, String, Option<String>, String)> = sqlx::query_as(
        "SELECT id, employee_id, date, availability, notes, source
         FROM employee_availability_overrides WHERE employee_id = ? ORDER BY date",
    )
    .bind(employee_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .filter_map(employee_avail_override_from_row)
        .collect())
}

pub async fn list_all_employee_availability_overrides(
    pool: &SqlitePool,
) -> Result<Vec<EmployeeAvailabilityOverride>, sqlx::Error> {
    let rows: Vec<(i64, i64, String, String, Option<String>, String)> = sqlx::query_as(
        "SELECT id, employee_id, date, availability, notes, source
         FROM employee_availability_overrides ORDER BY date, employee_id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .filter_map(employee_avail_override_from_row)
        .collect())
}

/// List employee availability overrides whose date falls within `[start, end)`.
/// Used by the scheduler so a single rota week doesn't pay for every historical
/// override in memory.
pub async fn list_employee_availability_overrides_in_range(
    pool: &SqlitePool,
    start: NaiveDate,
    end: NaiveDate,
) -> Result<Vec<EmployeeAvailabilityOverride>, sqlx::Error> {
    let start_str = start.format("%Y-%m-%d").to_string();
    let end_str = end.format("%Y-%m-%d").to_string();
    let rows: Vec<(i64, i64, String, String, Option<String>, String)> = sqlx::query_as(
        "SELECT id, employee_id, date, availability, notes, source
         FROM employee_availability_overrides
         WHERE date >= ? AND date < ?
         ORDER BY date, employee_id",
    )
    .bind(&start_str)
    .bind(&end_str)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .filter_map(employee_avail_override_from_row)
        .collect())
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
    row: (i64, i64, String, String, Option<String>, String),
) -> Option<EmployeeAvailabilityOverride> {
    let (id, employee_id, date_str, avail_json, notes, source) = row;
    Some(EmployeeAvailabilityOverride {
        id,
        employee_id,
        date: NaiveDate::parse_from_str(&date_str, "%Y-%m-%d").ok()?,
        availability: DayAvailability::from_json(&avail_json).unwrap_or_default(),
        notes,
        source: OverrideSource::parse(&source),
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
    Ok(rows
        .into_iter()
        .filter_map(shift_template_override_from_row)
        .collect())
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
    Ok(rows
        .into_iter()
        .filter_map(shift_template_override_from_row)
        .collect())
}

pub async fn delete_shift_template_override(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    insert_tombstone(pool, "shift_template_overrides", id).await?;
    sqlx::query("DELETE FROM shift_template_overrides WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

fn shift_template_override_from_row(
    row: (
        i64,
        i64,
        String,
        i64,
        Option<String>,
        Option<String>,
        Option<i64>,
        Option<i64>,
        Option<String>,
    ),
) -> Option<ShiftTemplateOverride> {
    let (id, template_id, date_str, cancelled, start_str, end_str, min_emp, max_emp, notes) = row;
    Some(ShiftTemplateOverride {
        id,
        template_id,
        date: NaiveDate::parse_from_str(&date_str, "%Y-%m-%d").ok()?,
        cancelled: cancelled != 0,
        start_time: start_str
            .as_deref()
            .and_then(|s| NaiveTime::parse_from_str(s, "%H:%M:%S").ok()),
        end_time: end_str
            .as_deref()
            .and_then(|s| NaiveTime::parse_from_str(s, "%H:%M:%S").ok()),
        min_employees: min_emp.map(|v| v as u32),
        max_employees: max_emp.map(|v| v as u32),
        notes,
    })
}

// ─── Shift History ───────────────────────────────────────────

type ShiftHistoryRow = (
    i64,
    i64,
    i64,
    i64,
    String,
    Option<String>,
    Option<f64>,
    String,
    String,
    String,
    String,
    String,
);

fn shift_record_from_row(row: ShiftHistoryRow) -> Option<EmployeeShiftRecord> {
    let (
        assignment_id,
        rota_id,
        shift_id,
        employee_id,
        status_str,
        employee_name,
        hourly_wage,
        date_str,
        start_str,
        end_str,
        required_role,
        week_start_str,
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
    })
}

pub async fn list_employee_shift_history(
    pool: &SqlitePool,
    employee_id: i64,
) -> Result<Vec<EmployeeShiftRecord>, sqlx::Error> {
    let rows: Vec<ShiftHistoryRow> = sqlx::query_as(
        "SELECT a.id, a.rota_id, a.shift_id, a.employee_id, a.status, a.employee_name, a.hourly_wage,
                s.date, s.start_time, s.end_time, s.required_role,
                r.week_start
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

pub async fn list_all_shift_history(
    pool: &SqlitePool,
    start_date: Option<NaiveDate>,
    end_date: Option<NaiveDate>,
) -> Result<Vec<EmployeeShiftRecord>, sqlx::Error> {
    let base = "SELECT a.id, a.rota_id, a.shift_id, a.employee_id, a.status, a.employee_name, a.hourly_wage,
                s.date, s.start_time, s.end_time, s.required_role,
                r.week_start
         FROM assignments a
         JOIN shifts s ON s.id = a.shift_id
         JOIN rotas r ON r.id = a.rota_id";

    let mut conditions = Vec::new();
    if start_date.is_some() {
        conditions.push("s.date >= ?");
    }
    if end_date.is_some() {
        conditions.push("s.date <= ?");
    }

    let sql = if conditions.is_empty() {
        format!("{base} ORDER BY s.date, s.start_time")
    } else {
        format!(
            "{base} WHERE {} ORDER BY s.date, s.start_time",
            conditions.join(" AND ")
        )
    };

    let mut query = sqlx::query_as::<_, ShiftHistoryRow>(&sql);
    if let Some(d) = start_date {
        query = query.bind(d.to_string());
    }
    if let Some(d) = end_date {
        query = query.bind(d.to_string());
    }

    let rows: Vec<ShiftHistoryRow> = query.fetch_all(pool).await?;
    Ok(rows.into_iter().filter_map(shift_record_from_row).collect())
}

// ─── Saves ────────────────────────────────────────────────────

/// Create a save snapshot for all shifts in the rota.
/// Returns the new save ID.
pub async fn create_save(pool: &SqlitePool, rota_id: i64) -> Result<i64, sqlx::Error> {
    let week_start_str: String = sqlx::query_scalar("SELECT week_start FROM rotas WHERE id = ?")
        .bind(rota_id)
        .fetch_one(pool)
        .await?;

    let shifts = list_shifts_for_rota(pool, rota_id).await?;

    if shifts.is_empty() {
        return Err(sqlx::Error::Protocol(
            "cannot create save: rota has no shifts".into(),
        ));
    }

    // Batch-load wage currencies for all employees referenced in assignments.
    let all_assignments = list_assignments_for_rota(pool, rota_id).await?;
    let employee_ids: Vec<i64> = all_assignments
        .iter()
        .map(|a| a.employee_id)
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let mut wage_currencies: HashMap<i64, Option<String>> = HashMap::new();
    for &eid in &employee_ids {
        let currency: Option<String> =
            sqlx::query_scalar("SELECT wage_currency FROM employees WHERE id = ?")
                .bind(eid)
                .fetch_optional(pool)
                .await?
                .flatten();
        wage_currencies.insert(eid, currency);
    }

    let mut snapshot_shifts = Vec::new();
    let mut all_employee_ids: HashSet<i64> = HashSet::new();
    let mut total_hours: f32 = 0.0;

    for shift in &shifts {
        let assignments: Vec<&Assignment> = all_assignments
            .iter()
            .filter(|a| a.shift_id == shift.id)
            .collect();

        let assignment_snapshots: Vec<SaveAssignmentSnapshot> = assignments
            .iter()
            .map(|a| {
                all_employee_ids.insert(a.employee_id);
                SaveAssignmentSnapshot {
                    assignment_id: a.id,
                    employee_id: a.employee_id,
                    employee_name: a.employee_name.clone().unwrap_or_default(),
                    status: a.status.to_string(),
                    hourly_wage: a.hourly_wage,
                    wage_currency: wage_currencies.get(&a.employee_id).cloned().flatten(),
                }
            })
            .collect();

        total_hours += shift.duration_hours();

        snapshot_shifts.push(SaveShiftSnapshot {
            shift_id: shift.id,
            template_id: shift.template_id,
            date: shift.date.to_string(),
            start_time: shift.start_time.format("%H:%M").to_string(),
            end_time: shift.end_time.format("%H:%M").to_string(),
            required_role: shift.required_role.clone(),
            min_employees: shift.min_employees,
            max_employees: shift.max_employees,
            assignments: assignment_snapshots,
        });
    }

    let saved_shift_ids: Vec<i64> = shifts.iter().map(|s| s.id).collect();
    let avail_overrides = collect_week_override_snapshots(pool, &week_start_str).await?;
    let snapshot = SaveSnapshot {
        week_start: week_start_str,
        saved_shift_ids,
        shifts: snapshot_shifts,
        total_hours,
        total_shifts: shifts.len(),
        unique_employees: all_employee_ids.len(),
        avail_overrides,
    };

    let snapshot_json =
        serde_json::to_string(&snapshot).map_err(|e| sqlx::Error::Protocol(e.to_string()))?;

    let summary = generate_save_summary(shifts.len(), all_employee_ids.len(), total_hours);
    let now = chrono::Utc::now().to_rfc3339();

    let save_id: i64 = sqlx::query_scalar(
        "INSERT INTO saves (rota_id, saved_at, summary, snapshot_json) VALUES (?, ?, ?, ?) RETURNING id",
    )
    .bind(rota_id)
    .bind(&now)
    .bind(&summary)
    .bind(&snapshot_json)
    .fetch_one(pool)
    .await?;

    Ok(save_id)
}

fn generate_save_summary(total_shifts: usize, unique_employees: usize, total_hours: f32) -> String {
    format!(
        "{} shift{}, {} employee{}, {:.0}h",
        total_shifts,
        if total_shifts == 1 { "" } else { "s" },
        unique_employees,
        if unique_employees == 1 { "" } else { "s" },
        total_hours,
    )
}

/// List saves, optionally filtered by rota_id. Ordered by saved_at DESC.
pub async fn list_saves(pool: &SqlitePool, rota_id: Option<i64>) -> Result<Vec<Save>, sqlx::Error> {
    let rows: Vec<(i64, i64, String, String, String, Option<String>)> = match rota_id {
        Some(rid) => {
            sqlx::query_as(
                "SELECT id, rota_id, saved_at, summary, snapshot_json, restored_at
             FROM saves WHERE rota_id = ?
             ORDER BY COALESCE(restored_at, saved_at) DESC",
            )
            .bind(rid)
            .fetch_all(pool)
            .await?
        }
        None => {
            sqlx::query_as(
                "SELECT id, rota_id, saved_at, summary, snapshot_json, restored_at
             FROM saves
             ORDER BY COALESCE(restored_at, saved_at) DESC",
            )
            .fetch_all(pool)
            .await?
        }
    };

    let mut saves: Vec<Save> = rows.into_iter().map(save_from_row).collect();
    let ids: Vec<i64> = saves.iter().map(|s| s.id).collect();
    let tags_by_save = load_tags_for_saves(pool, &ids).await?;
    for save in &mut saves {
        if let Some(tags) = tags_by_save.get(&save.id) {
            save.tags = tags.clone();
        }
    }
    Ok(saves)
}

/// Get a single save by ID.
pub async fn get_save(pool: &SqlitePool, id: i64) -> Result<Option<Save>, sqlx::Error> {
    let row: Option<(i64, i64, String, String, String, Option<String>)> = sqlx::query_as(
        "SELECT id, rota_id, saved_at, summary, snapshot_json, restored_at FROM saves WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    let Some(row) = row else { return Ok(None) };
    let mut save = save_from_row(row);
    save.tags = list_save_tags(pool, save.id).await?;
    Ok(Some(save))
}

/// Check if a rota has any saves.
pub async fn rota_has_saves(pool: &SqlitePool, rota_id: i64) -> Result<bool, sqlx::Error> {
    let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM saves WHERE rota_id = ?)")
        .bind(rota_id)
        .fetch_one(pool)
        .await?;
    Ok(exists)
}

fn save_from_row(row: (i64, i64, String, String, String, Option<String>)) -> Save {
    let (id, rota_id, saved_at, summary, snapshot_json, restored_at) = row;
    Save {
        id,
        rota_id,
        saved_at,
        summary,
        snapshot_json,
        tags: Vec::new(),
        restored_at,
    }
}

/// List tags for a single save, ordered by position.
pub async fn list_save_tags(pool: &SqlitePool, save_id: i64) -> Result<Vec<String>, sqlx::Error> {
    let rows: Vec<(String,)> =
        sqlx::query_as("SELECT tag FROM save_tags WHERE save_id = ? ORDER BY position ASC")
            .bind(save_id)
            .fetch_all(pool)
            .await?;
    Ok(rows.into_iter().map(|r| r.0).collect())
}

/// Batch-load tags for many saves. Returns a map keyed by save_id.
async fn load_tags_for_saves(
    pool: &SqlitePool,
    save_ids: &[i64],
) -> Result<HashMap<i64, Vec<String>>, sqlx::Error> {
    if save_ids.is_empty() {
        return Ok(HashMap::new());
    }
    let placeholders = vec!["?"; save_ids.len()].join(",");
    let sql = format!(
        "SELECT save_id, tag FROM save_tags WHERE save_id IN ({placeholders}) \
         ORDER BY save_id, position ASC",
    );
    let mut q = sqlx::query_as::<_, (i64, String)>(&sql);
    for id in save_ids {
        q = q.bind(id);
    }
    let rows = q.fetch_all(pool).await?;
    let mut map: HashMap<i64, Vec<String>> = HashMap::new();
    for (save_id, tag) in rows {
        map.entry(save_id).or_default().push(tag);
    }
    Ok(map)
}

/// Error returned from tag mutations. Wraps domain errors + raw sqlx errors.
#[derive(Debug)]
pub enum SaveTagError {
    Validation(crate::models::save::TagError),
    Db(sqlx::Error),
}

impl From<sqlx::Error> for SaveTagError {
    fn from(e: sqlx::Error) -> Self {
        SaveTagError::Db(e)
    }
}

impl From<crate::models::save::TagError> for SaveTagError {
    fn from(e: crate::models::save::TagError) -> Self {
        SaveTagError::Validation(e)
    }
}

impl std::fmt::Display for SaveTagError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SaveTagError::Validation(e) => write!(f, "{e}"),
            SaveTagError::Db(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for SaveTagError {}

/// Add a tag to a save. Validates the input, enforces the per-save max,
/// and rejects case-insensitive duplicates.
pub async fn add_save_tag(
    pool: &SqlitePool,
    save_id: i64,
    raw_tag: &str,
) -> Result<(), SaveTagError> {
    use crate::models::save::{TAG_MAX_PER_SAVE, TagError, validate_tag};

    let value = validate_tag(raw_tag)?;

    let existing: Vec<(String, i64)> = sqlx::query_as(
        "SELECT tag, position FROM save_tags WHERE save_id = ? ORDER BY position ASC",
    )
    .bind(save_id)
    .fetch_all(pool)
    .await?;

    if existing.len() >= TAG_MAX_PER_SAVE {
        return Err(TagError::MaxReached.into());
    }

    let lower = value.to_lowercase();
    if existing.iter().any(|(t, _)| t.to_lowercase() == lower) {
        return Err(TagError::Duplicate.into());
    }

    let next_position = existing.last().map(|(_, p)| p + 1).unwrap_or(0);
    sqlx::query("INSERT INTO save_tags (save_id, position, tag) VALUES (?, ?, ?)")
        .bind(save_id)
        .bind(next_position)
        .bind(&value)
        .execute(pool)
        .await?;
    Ok(())
}

/// Remove a tag from a save by exact case-insensitive match.
/// No-op if the tag is not present.
pub async fn remove_save_tag(
    pool: &SqlitePool,
    save_id: i64,
    tag: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM save_tags WHERE save_id = ? AND LOWER(tag) = LOWER(?)")
        .bind(save_id)
        .bind(tag)
        .execute(pool)
        .await?;
    Ok(())
}

/// Compare live shifts for a rota against the latest save snapshot.
/// Returns a diff entry for each live shift that is new or changed.
pub async fn diff_rota_vs_latest_save(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<Vec<ShiftDiff>, sqlx::Error> {
    // Fetch latest save for this rota.
    let latest: Option<(i64, i64, String, String, String, Option<String>)> = sqlx::query_as(
        "SELECT id, rota_id, saved_at, summary, snapshot_json, restored_at
         FROM saves WHERE rota_id = ? ORDER BY saved_at DESC LIMIT 1",
    )
    .bind(rota_id)
    .fetch_optional(pool)
    .await?;

    let Some(row) = latest else {
        // No saves yet — every shift is "new".
        let shifts = list_shifts_for_rota(pool, rota_id).await?;
        return Ok(shifts
            .into_iter()
            .map(|s| ShiftDiff {
                shift_id: s.id,
                is_new: true,
                is_changed: false,
            })
            .collect());
    };

    let save = save_from_row(row);
    let snapshot: SaveSnapshot = serde_json::from_str(&save.snapshot_json)
        .map_err(|e| sqlx::Error::Protocol(e.to_string()))?;

    // Build lookup from snapshot: shift_id → snapshot shift.
    let snap_by_id: HashMap<i64, &SaveShiftSnapshot> =
        snapshot.shifts.iter().map(|s| (s.shift_id, s)).collect();

    // Get live state.
    let live_shifts = list_shifts_for_rota(pool, rota_id).await?;
    let live_assignments = list_assignments_for_rota(pool, rota_id).await?;

    let mut diffs = Vec::new();
    for shift in &live_shifts {
        match snap_by_id.get(&shift.id) {
            None => {
                diffs.push(ShiftDiff {
                    shift_id: shift.id,
                    is_new: true,
                    is_changed: false,
                });
            }
            Some(snap) => {
                let live_start = shift.start_time.format("%H:%M").to_string();
                let live_end = shift.end_time.format("%H:%M").to_string();

                let times_differ = live_start != snap.start_time || live_end != snap.end_time;
                let role_differs = shift.required_role != snap.required_role;
                let cap_differs = shift.min_employees != snap.min_employees
                    || shift.max_employees != snap.max_employees;

                // Compare assignment pairs: (employee_id, status)
                let snap_pairs: HashSet<(i64, String)> = snap
                    .assignments
                    .iter()
                    .map(|a| (a.employee_id, a.status.to_lowercase()))
                    .collect();
                let live_pairs: HashSet<(i64, String)> = live_assignments
                    .iter()
                    .filter(|a| a.shift_id == shift.id)
                    .map(|a| (a.employee_id, a.status.to_string().to_lowercase()))
                    .collect();
                let assignments_differ = snap_pairs != live_pairs;

                if times_differ || role_differs || cap_differs || assignments_differ {
                    diffs.push(ShiftDiff {
                        shift_id: shift.id,
                        is_new: false,
                        is_changed: true,
                    });
                }
            }
        }
    }
    Ok(diffs)
}

/// Build a `SaveSnapshot` from the live state of a rota without persisting
/// a save. Used by detailed-diff queries so live state can be compared
/// against a persisted snapshot with the same pure `diff_snapshots` function.
///
/// Always snapshots all shifts currently in the rota.
pub async fn snapshot_from_live(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<SaveSnapshot, sqlx::Error> {
    let week_start_str: String = sqlx::query_scalar("SELECT week_start FROM rotas WHERE id = ?")
        .bind(rota_id)
        .fetch_one(pool)
        .await?;

    let shifts = list_shifts_for_rota(pool, rota_id).await?;

    let all_assignments = list_assignments_for_rota(pool, rota_id).await?;

    // Batch-load wage currencies for referenced employees.
    let employee_ids: Vec<i64> = all_assignments
        .iter()
        .map(|a| a.employee_id)
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let mut wage_currencies: HashMap<i64, Option<String>> = HashMap::new();
    for &eid in &employee_ids {
        let currency: Option<String> =
            sqlx::query_scalar("SELECT wage_currency FROM employees WHERE id = ?")
                .bind(eid)
                .fetch_optional(pool)
                .await?
                .flatten();
        wage_currencies.insert(eid, currency);
    }

    let mut snapshot_shifts = Vec::new();
    let mut all_employee_ids: HashSet<i64> = HashSet::new();
    let mut total_hours: f32 = 0.0;

    for shift in &shifts {
        let assignment_snapshots: Vec<SaveAssignmentSnapshot> = all_assignments
            .iter()
            .filter(|a| a.shift_id == shift.id)
            .map(|a| {
                all_employee_ids.insert(a.employee_id);
                SaveAssignmentSnapshot {
                    assignment_id: a.id,
                    employee_id: a.employee_id,
                    employee_name: a.employee_name.clone().unwrap_or_default(),
                    status: a.status.to_string(),
                    hourly_wage: a.hourly_wage,
                    wage_currency: wage_currencies.get(&a.employee_id).cloned().flatten(),
                }
            })
            .collect();

        total_hours += shift.duration_hours();

        snapshot_shifts.push(SaveShiftSnapshot {
            shift_id: shift.id,
            template_id: shift.template_id,
            date: shift.date.to_string(),
            start_time: shift.start_time.format("%H:%M").to_string(),
            end_time: shift.end_time.format("%H:%M").to_string(),
            required_role: shift.required_role.clone(),
            min_employees: shift.min_employees,
            max_employees: shift.max_employees,
            assignments: assignment_snapshots,
        });
    }

    let saved_shift_ids = shifts.iter().map(|s| s.id).collect();
    let avail_overrides = collect_week_override_snapshots(pool, &week_start_str).await?;
    Ok(SaveSnapshot {
        week_start: week_start_str,
        saved_shift_ids,
        shifts: snapshot_shifts,
        total_hours,
        total_shifts: shifts.len(),
        unique_employees: all_employee_ids.len(),
        avail_overrides,
    })
}

/// Fetch employee availability overrides that fall within the 7-day window
/// starting at `week_start_str` and convert them to their snapshot form.
/// Returned list is empty when parsing fails — snapshots tolerate missing data.
async fn collect_week_override_snapshots(
    pool: &SqlitePool,
    week_start_str: &str,
) -> Result<Vec<SaveEmployeeAvailabilityOverrideSnapshot>, sqlx::Error> {
    let Ok(week_start) = NaiveDate::parse_from_str(week_start_str, "%Y-%m-%d") else {
        return Ok(vec![]);
    };
    let week_end = week_start + chrono::Duration::days(7);
    let overrides =
        list_employee_availability_overrides_in_range(pool, week_start, week_end).await?;
    Ok(overrides
        .into_iter()
        .map(|o| SaveEmployeeAvailabilityOverrideSnapshot {
            employee_id: o.employee_id,
            date: o.date.format("%Y-%m-%d").to_string(),
            availability_json: o
                .availability
                .to_json()
                .unwrap_or_else(|_| "{}".to_string()),
            notes: o.notes,
            source: o.source.as_str().to_string(),
        })
        .collect())
}

/// Detailed diff between the live state of a rota and its latest save.
/// If no save exists yet, every live shift appears as `ShiftAdded`.
pub async fn diff_rota_vs_latest_save_detailed(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<Vec<ChangeDetail>, sqlx::Error> {
    let latest: Option<(i64, i64, String, String, String, Option<String>)> = sqlx::query_as(
        "SELECT id, rota_id, saved_at, summary, snapshot_json, restored_at
         FROM saves WHERE rota_id = ? ORDER BY saved_at DESC LIMIT 1",
    )
    .bind(rota_id)
    .fetch_optional(pool)
    .await?;

    let live = snapshot_from_live(pool, rota_id).await?;

    let old = match latest {
        Some(row) => {
            let save = save_from_row(row);
            serde_json::from_str(&save.snapshot_json)
                .map_err(|e| sqlx::Error::Protocol(e.to_string()))?
        }
        None => empty_snapshot(&live.week_start),
    };

    Ok(diff_snapshots(&old, &live))
}

/// Detailed diff between two persisted saves.
pub async fn diff_saves(
    pool: &SqlitePool,
    old_save_id: i64,
    new_save_id: i64,
) -> Result<Vec<ChangeDetail>, sqlx::Error> {
    let old_save = get_save(pool, old_save_id)
        .await?
        .ok_or_else(|| sqlx::Error::RowNotFound)?;
    let new_save = get_save(pool, new_save_id)
        .await?
        .ok_or_else(|| sqlx::Error::RowNotFound)?;

    let old_snap: SaveSnapshot = serde_json::from_str(&old_save.snapshot_json)
        .map_err(|e| sqlx::Error::Protocol(e.to_string()))?;
    let new_snap: SaveSnapshot = serde_json::from_str(&new_save.snapshot_json)
        .map_err(|e| sqlx::Error::Protocol(e.to_string()))?;

    Ok(diff_snapshots(&old_snap, &new_snap))
}

/// Detailed diff between a save and the save that immediately preceded
/// it (by saved_at) for the same rota. If this is the first save for
/// the rota, the diff is against an empty snapshot (every shift is new).
pub async fn diff_save_vs_previous(
    pool: &SqlitePool,
    save_id: i64,
) -> Result<Vec<ChangeDetail>, sqlx::Error> {
    let save = get_save(pool, save_id)
        .await?
        .ok_or_else(|| sqlx::Error::RowNotFound)?;

    let prev: Option<(i64, i64, String, String, String, Option<String>)> = sqlx::query_as(
        "SELECT id, rota_id, saved_at, summary, snapshot_json, restored_at
         FROM saves WHERE rota_id = ? AND saved_at < ?
         ORDER BY saved_at DESC LIMIT 1",
    )
    .bind(save.rota_id)
    .bind(&save.saved_at)
    .fetch_optional(pool)
    .await?;

    let new_snap: SaveSnapshot = serde_json::from_str(&save.snapshot_json)
        .map_err(|e| sqlx::Error::Protocol(e.to_string()))?;
    let old_snap: SaveSnapshot = match prev {
        Some(row) => {
            let s = save_from_row(row);
            serde_json::from_str(&s.snapshot_json)
                .map_err(|e| sqlx::Error::Protocol(e.to_string()))?
        }
        None => empty_snapshot(&new_snap.week_start),
    };

    Ok(diff_snapshots(&old_snap, &new_snap))
}

fn empty_snapshot(week_start: &str) -> SaveSnapshot {
    SaveSnapshot {
        week_start: week_start.to_string(),
        saved_shift_ids: vec![],
        shifts: vec![],
        total_hours: 0.0,
        total_shifts: 0,
        unique_employees: 0,
        avail_overrides: vec![],
    }
}

/// Restore a rota to the state captured by a save.
///
/// Transactional: the entire operation is atomic. Existing shifts for the
/// rota are deleted (cascading to their assignments), then shifts and
/// assignments are recreated from the snapshot. Assignments referencing
/// employees that no longer exist are skipped (counted in the result).
///
/// Restored shifts are inserted as ad-hoc (template_id = NULL) since the
/// snapshot does not preserve template linkage. This is intentional: the
/// user's explicit restore should survive any later scheduler regeneration
/// that wipes template-based shifts.
///
/// Side effects:
/// - Tombstones are inserted for the deleted shifts so iCloud sync replays
///   the removal on other devices.
/// - New shift/assignment rows have `sync_status = 0` (dirty) so they sync
///   out normally.
pub async fn restore_from_save(
    pool: &SqlitePool,
    save_id: i64,
) -> Result<RestoreResult, sqlx::Error> {
    let save = get_save(pool, save_id)
        .await?
        .ok_or_else(|| sqlx::Error::RowNotFound)?;
    let snapshot: SaveSnapshot = serde_json::from_str(&save.snapshot_json)
        .map_err(|e| sqlx::Error::Protocol(e.to_string()))?;
    let rota_id = save.rota_id;

    let mut tx = pool.begin().await?;

    // Tombstones for everything we're about to delete (sync hygiene).
    let existing_shift_ids: Vec<i64> =
        sqlx::query_scalar("SELECT id FROM shifts WHERE rota_id = ?")
            .bind(rota_id)
            .fetch_all(&mut *tx)
            .await?;
    let existing_assignment_ids: Vec<i64> =
        sqlx::query_scalar("SELECT id FROM assignments WHERE rota_id = ?")
            .bind(rota_id)
            .fetch_all(&mut *tx)
            .await?;
    let now = chrono::Utc::now().to_rfc3339();
    for chunk in existing_shift_ids.chunks(300) {
        let placeholders = vec!["(?, ?, ?)"; chunk.len()].join(", ");
        let sql = format!(
            "INSERT INTO sync_tombstones (table_name, record_id, deleted_at) VALUES {placeholders}"
        );
        let mut q = sqlx::query(&sql);
        for &sid in chunk {
            q = q.bind("shifts").bind(sid).bind(&now);
        }
        q.execute(&mut *tx).await?;
    }
    for chunk in existing_assignment_ids.chunks(300) {
        let placeholders = vec!["(?, ?, ?)"; chunk.len()].join(", ");
        let sql = format!(
            "INSERT INTO sync_tombstones (table_name, record_id, deleted_at) VALUES {placeholders}"
        );
        let mut q = sqlx::query(&sql);
        for &aid in chunk {
            q = q.bind("assignments").bind(aid).bind(&now);
        }
        q.execute(&mut *tx).await?;
    }

    // Explicitly delete assignments first — FK CASCADE on shift_id may not
    // fire if the foreign_keys pragma is not enabled on the specific pooled
    // connection serving this transaction.
    sqlx::query("DELETE FROM assignments WHERE rota_id = ?")
        .bind(rota_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM shifts WHERE rota_id = ?")
        .bind(rota_id)
        .execute(&mut *tx)
        .await?;

    // Re-insert shifts from snapshot, capturing old→new id mapping.
    let mut id_map: HashMap<i64, i64> = HashMap::new();
    let mut shifts_restored = 0usize;
    for snap_shift in &snapshot.shifts {
        // Normalize time format: snapshot stores HH:MM, DB expects HH:MM:SS.
        let start_time = normalize_time(&snap_shift.start_time);
        let end_time = normalize_time(&snap_shift.end_time);
        let new_id: i64 = sqlx::query_scalar(
            "INSERT INTO shifts (template_id, rota_id, date, start_time, end_time, required_role, min_employees, max_employees, last_modified, sync_status)
             VALUES (NULL, ?, ?, ?, ?, ?, ?, ?, ?, 0) RETURNING id",
        )
        .bind(rota_id)
        .bind(&snap_shift.date)
        .bind(&start_time)
        .bind(&end_time)
        .bind(&snap_shift.required_role)
        .bind(snap_shift.min_employees)
        .bind(snap_shift.max_employees)
        .bind(&now)
        .fetch_one(&mut *tx)
        .await?;
        id_map.insert(snap_shift.shift_id, new_id);
        shifts_restored += 1;
    }

    // Load active (non-deleted) employee IDs so we can skip assignments for
    // employees that have been removed or soft-deleted since the save.
    let existing_emp_ids: Vec<i64> =
        sqlx::query_scalar("SELECT id FROM employees WHERE deleted = 0")
            .fetch_all(&mut *tx)
            .await?;
    let existing_emp: HashSet<i64> = existing_emp_ids.into_iter().collect();

    let mut assignments_restored = 0usize;
    let mut assignments_skipped = 0usize;
    for snap_shift in &snapshot.shifts {
        let Some(&new_shift_id) = id_map.get(&snap_shift.shift_id) else {
            continue;
        };
        for a in &snap_shift.assignments {
            if !existing_emp.contains(&a.employee_id) {
                assignments_skipped += 1;
                continue;
            }
            sqlx::query(
                "INSERT INTO assignments (rota_id, shift_id, employee_id, status, employee_name, hourly_wage, last_modified, sync_status)
                 VALUES (?, ?, ?, ?, ?, ?, ?, 0)",
            )
            .bind(rota_id)
            .bind(new_shift_id)
            .bind(a.employee_id)
            .bind(&a.status)
            .bind(&a.employee_name)
            .bind(a.hourly_wage)
            .bind(&now)
            .execute(&mut *tx)
            .await?;
            assignments_restored += 1;
        }
    }

    // Stamp the target save so the UI can promote it to the top of its
    // week's list and badge it "Restored".
    sqlx::query("UPDATE saves SET restored_at = ? WHERE id = ?")
        .bind(&now)
        .bind(save_id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;

    Ok(RestoreResult {
        rota_id,
        shifts_restored,
        assignments_restored,
        assignments_skipped,
    })
}

/// Accept either `HH:MM` or `HH:MM:SS`; return `HH:MM:SS`.
fn normalize_time(s: &str) -> String {
    if s.len() == 5 {
        format!("{s}:00")
    } else {
        s.to_string()
    }
}

// ���── Sync ─���────────────────────────────────────��────────────

pub async fn get_sync_metadata(
    pool: &SqlitePool,
    key: &str,
) -> Result<Option<String>, sqlx::Error> {
    sqlx::query_scalar("SELECT value FROM sync_metadata WHERE key = ?")
        .bind(key)
        .fetch_optional(pool)
        .await
}

pub async fn set_sync_metadata(
    pool: &SqlitePool,
    key: &str,
    value: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("INSERT INTO sync_metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        .bind(key)
        .bind(value)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn insert_tombstone(
    pool: &SqlitePool,
    table_name: &str,
    record_id: i64,
) -> Result<i64, sqlx::Error> {
    let now = chrono::Utc::now().to_rfc3339();
    let result = sqlx::query(
        "INSERT INTO sync_tombstones (table_name, record_id, deleted_at) VALUES (?, ?, ?)",
    )
    .bind(table_name)
    .bind(record_id)
    .bind(&now)
    .execute(pool)
    .await?;
    Ok(result.last_insert_rowid())
}

/// Batch insert of tombstones for many record_ids in the same table.
/// Builds a single multi-row INSERT, chunked to stay under SQLite's bind limit.
pub async fn insert_tombstones(
    pool: &SqlitePool,
    table_name: &str,
    record_ids: &[i64],
) -> Result<(), sqlx::Error> {
    if record_ids.is_empty() {
        return Ok(());
    }
    let now = chrono::Utc::now().to_rfc3339();
    // 3 binds per row; SQLite default SQLITE_MAX_VARIABLE_NUMBER is 999 → 300 rows safe.
    for chunk in record_ids.chunks(300) {
        let placeholders = vec!["(?, ?, ?)"; chunk.len()].join(", ");
        let sql = format!(
            "INSERT INTO sync_tombstones (table_name, record_id, deleted_at) VALUES {placeholders}"
        );
        let mut q = sqlx::query(&sql);
        for id in chunk {
            q = q.bind(table_name).bind(*id).bind(&now);
        }
        q.execute(pool).await?;
    }
    Ok(())
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
    let sql = format!("DELETE FROM sync_tombstones WHERE id IN ({})", placeholders);
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
            "id",
            "first_name",
            "last_name",
            "nickname",
            "roles",
            "start_date",
            "target_weekly_hours",
            "weekly_hours_deviation",
            "max_daily_hours",
            "notes",
            "bank_details",
            "phone",
            "email",
            "preferred_contact",
            "hourly_wage",
            "wage_currency",
            "default_availability",
            "availability",
            "deleted",
            "last_modified",
        ],
        "shift_templates" => vec![
            "id",
            "name",
            "weekdays",
            "start_time",
            "end_time",
            "required_role",
            "min_employees",
            "max_employees",
            "deleted",
            "last_modified",
        ],
        "rotas" => vec!["id", "week_start", "last_modified"],
        "shifts" => vec![
            "id",
            "template_id",
            "rota_id",
            "date",
            "start_time",
            "end_time",
            "required_role",
            "min_employees",
            "max_employees",
            "last_modified",
        ],
        "assignments" => vec![
            "id",
            "rota_id",
            "shift_id",
            "employee_id",
            "status",
            "employee_name",
            "hourly_wage",
            "last_modified",
        ],
        "roles" => vec!["id", "name", "last_modified"],
        "employee_availability_overrides" => vec![
            "id",
            "employee_id",
            "date",
            "availability",
            "notes",
            "source",
            "last_modified",
        ],
        "shift_template_overrides" => vec![
            "id",
            "template_id",
            "date",
            "cancelled",
            "start_time",
            "end_time",
            "min_employees",
            "max_employees",
            "notes",
            "last_modified",
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
    let placeholders: String = record_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
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
    let _fields: serde_json::Value =
        serde_json::from_str(&record.fields).map_err(|e| sqlx::Error::Protocol(e.to_string()))?;

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

// ── Availability Progress ────────────────────────────────────────────────────

/// List availability-progress flags for a given week.
pub async fn list_availability_progress(
    pool: &SqlitePool,
    week_start: &str,
) -> Result<Vec<(i64, bool)>, sqlx::Error> {
    let rows: Vec<(i64, bool)> =
        sqlx::query_as("SELECT employee_id, done FROM availability_progress WHERE week_start = ?")
            .bind(week_start)
            .fetch_all(pool)
            .await?;
    Ok(rows)
}

/// Mark an employee's availability as done/not-done for a given week (upsert).
pub async fn set_availability_progress(
    pool: &SqlitePool,
    employee_id: i64,
    week_start: &str,
    done: bool,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO availability_progress (employee_id, week_start, done)
         VALUES (?, ?, ?)
         ON CONFLICT(employee_id, week_start) DO UPDATE SET done = excluded.done",
    )
    .bind(employee_id)
    .bind(week_start)
    .bind(done)
    .execute(pool)
    .await?;
    Ok(())
}
