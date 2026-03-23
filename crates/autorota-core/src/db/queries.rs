use chrono::{NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;

use crate::models::assignment::{Assignment, AssignmentStatus};
use crate::models::availability::Availability;
use crate::models::employee::Employee;
use crate::models::rota::Rota;
use crate::models::shift::{Shift, ShiftTemplate};

type ShiftTemplateRow = (i64, String, String, String, String, String, u32, u32, bool);
type ShiftRow = (i64, Option<i64>, i64, String, String, String, String, u32, u32);

// ─── Employees ───────────────────────────────────────────────

pub async fn insert_employee(pool: &SqlitePool, emp: &Employee) -> Result<i64, sqlx::Error> {
    let roles_json = serde_json::to_string(&emp.roles).unwrap_or_default();
    let default_avail = emp.default_availability.to_json().unwrap_or_default();
    let avail = emp.availability.to_json().unwrap_or_default();

    let id = sqlx::query_scalar(
        "INSERT INTO employees (name, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, default_availability, availability)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(&emp.name)
    .bind(&roles_json)
    .bind(emp.start_date.to_string())
    .bind(emp.target_weekly_hours)
    .bind(emp.weekly_hours_deviation)
    .bind(emp.max_daily_hours)
    .bind(&emp.notes)
    .bind(&emp.bank_details)
    .bind(&default_avail)
    .bind(&avail)
    .fetch_one(pool)
    .await?;

    Ok(id)
}

pub async fn get_employee(pool: &SqlitePool, id: i64) -> Result<Option<Employee>, sqlx::Error> {
    let row: Option<(i64, String, String, String, f64, f64, f64, Option<String>, Option<String>, String, String, bool)> = sqlx::query_as(
        "SELECT id, name, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, default_availability, availability, deleted
         FROM employees WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(employee_from_row))
}

pub async fn list_employees(pool: &SqlitePool) -> Result<Vec<Employee>, sqlx::Error> {
    let rows: Vec<(i64, String, String, String, f64, f64, f64, Option<String>, Option<String>, String, String, bool)> = sqlx::query_as(
        "SELECT id, name, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, default_availability, availability, deleted
         FROM employees WHERE deleted = 0 ORDER BY start_date",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(employee_from_row).collect())
}

/// List all employees including soft-deleted ones (for historical schedule display).
pub async fn list_all_employees(pool: &SqlitePool) -> Result<Vec<Employee>, sqlx::Error> {
    let rows: Vec<(i64, String, String, String, f64, f64, f64, Option<String>, Option<String>, String, String, bool)> = sqlx::query_as(
        "SELECT id, name, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, default_availability, availability, deleted
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

    sqlx::query(
        "UPDATE employees SET name = ?, roles = ?, start_date = ?, target_weekly_hours = ?, weekly_hours_deviation = ?, max_daily_hours = ?,
         notes = ?, bank_details = ?, default_availability = ?, availability = ? WHERE id = ?",
    )
    .bind(&emp.name)
    .bind(&roles_json)
    .bind(emp.start_date.to_string())
    .bind(emp.target_weekly_hours)
    .bind(emp.weekly_hours_deviation)
    .bind(emp.max_daily_hours)
    .bind(&emp.notes)
    .bind(&emp.bank_details)
    .bind(&default_avail)
    .bind(&avail)
    .bind(emp.id)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn delete_employee(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE employees SET deleted = 1 WHERE id = ?")
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
        String,
        f64,
        f64,
        f64,
        Option<String>,
        Option<String>,
        String,
        String,
        bool,
    ),
) -> Employee {
    let (
        id,
        name,
        roles_json,
        start_date_str,
        target_weekly,
        deviation,
        max_daily,
        notes,
        bank_details,
        default_avail_json,
        avail_json,
        deleted,
    ) = row;
    Employee {
        id,
        name,
        roles: serde_json::from_str(&roles_json).unwrap_or_default(),
        start_date: NaiveDate::parse_from_str(&start_date_str, "%Y-%m-%d")
            .unwrap_or_else(|_| NaiveDate::default()),
        target_weekly_hours: target_weekly as f32,
        weekly_hours_deviation: deviation as f32,
        max_daily_hours: max_daily as f32,
        notes,
        bank_details,
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

    let id: i64 = sqlx::query_scalar(
        "INSERT INTO shift_templates (name, weekdays, start_time, end_time, required_role, min_employees, max_employees)
         VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(&tmpl.name)
    .bind(&weekdays_str)
    .bind(&start)
    .bind(&end)
    .bind(&tmpl.required_role)
    .bind(tmpl.min_employees)
    .bind(tmpl.max_employees)
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

pub async fn update_shift_template(
    pool: &SqlitePool,
    tmpl: &ShiftTemplate,
) -> Result<(), sqlx::Error> {
    let weekdays_str = weekdays_to_string(&tmpl.weekdays);
    let start = tmpl.start_time.to_string();
    let end = tmpl.end_time.to_string();

    sqlx::query(
        "UPDATE shift_templates SET name = ?, weekdays = ?, start_time = ?, end_time = ?, required_role = ?, min_employees = ?, max_employees = ? WHERE id = ?",
    )
    .bind(&tmpl.name)
    .bind(&weekdays_str)
    .bind(&start)
    .bind(&end)
    .bind(&tmpl.required_role)
    .bind(tmpl.min_employees)
    .bind(tmpl.max_employees)
    .bind(tmpl.id)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn delete_shift_template(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE shift_templates SET deleted = 1 WHERE id = ?")
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
    let id: i64 =
        sqlx::query_scalar("INSERT INTO rotas (week_start, finalized) VALUES (?, 0) RETURNING id")
            .bind(week_start.to_string())
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

pub async fn finalize_rota(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE rotas SET finalized = 1 WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

// ─── Shifts ──────────────────────────────────────────────────

pub async fn insert_shift(pool: &SqlitePool, shift: &Shift) -> Result<i64, sqlx::Error> {
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO shifts (template_id, rota_id, date, start_time, end_time, required_role, min_employees, max_employees)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(shift.template_id)
    .bind(shift.rota_id)
    .bind(shift.date.to_string())
    .bind(shift.start_time.to_string())
    .bind(shift.end_time.to_string())
    .bind(&shift.required_role)
    .bind(shift.min_employees)
    .bind(shift.max_employees)
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

    let id: i64 = sqlx::query_scalar(
        "INSERT INTO assignments (rota_id, shift_id, employee_id, status, employee_name)
         VALUES (?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(assignment.rota_id)
    .bind(assignment.shift_id)
    .bind(assignment.employee_id)
    .bind(&status_str)
    .bind(&assignment.employee_name)
    .fetch_one(pool)
    .await?;

    Ok(id)
}

pub async fn list_assignments_for_rota(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<Vec<Assignment>, sqlx::Error> {
    let rows: Vec<(i64, i64, i64, i64, String, Option<String>)> = sqlx::query_as(
        "SELECT id, rota_id, shift_id, employee_id, status, employee_name
         FROM assignments WHERE rota_id = ? ORDER BY id",
    )
    .bind(rota_id)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().filter_map(assignment_from_row).collect())
}

pub async fn delete_shifts_for_rota(pool: &SqlitePool, rota_id: i64) -> Result<(), sqlx::Error> {
    // Only delete template-based shifts; preserve ad-hoc shifts (template_id IS NULL).
    sqlx::query("DELETE FROM shifts WHERE rota_id = ? AND template_id IS NOT NULL")
        .bind(rota_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn delete_shift(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
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
    sqlx::query("UPDATE shifts SET start_time = ?, end_time = ? WHERE id = ?")
        .bind(start_time.to_string())
        .bind(end_time.to_string())
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn delete_proposed_assignments(
    pool: &SqlitePool,
    rota_id: i64,
) -> Result<(), sqlx::Error> {
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
    sqlx::query("UPDATE assignments SET status = ? WHERE id = ?")
        .bind(status.to_string())
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
    sqlx::query("UPDATE assignments SET shift_id = ? WHERE id = ?")
        .bind(new_shift_id)
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
    // Swap: A gets B's shift, B gets A's shift
    sqlx::query("UPDATE assignments SET shift_id = ? WHERE id = ?")
        .bind(shift_b)
        .bind(id_a)
        .execute(pool)
        .await?;
    sqlx::query("UPDATE assignments SET shift_id = ? WHERE id = ?")
        .bind(shift_a)
        .bind(id_b)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn delete_assignment(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM assignments WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

fn assignment_from_row(row: (i64, i64, i64, i64, String, Option<String>)) -> Option<Assignment> {
    let (id, rota_id, shift_id, employee_id, status_str, employee_name) = row;
    Some(Assignment {
        id,
        rota_id,
        shift_id,
        employee_id,
        status: status_str.parse().ok()?,
        employee_name,
    })
}
