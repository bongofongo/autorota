use chrono::{NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;

use crate::models::assignment::{Assignment, AssignmentStatus};
use crate::models::availability::Availability;
use crate::models::employee::Employee;
use crate::models::overrides::{DayAvailability, EmployeeAvailabilityOverride, ShiftTemplateOverride};
use crate::models::role::Role;
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
        "INSERT INTO employees (first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, default_availability, availability)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
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
    .bind(&default_avail)
    .bind(&avail)
    .fetch_one(pool)
    .await?;

    Ok(id)
}

pub async fn get_employee(pool: &SqlitePool, id: i64) -> Result<Option<Employee>, sqlx::Error> {
    let row: Option<(i64, String, String, Option<String>, String, String, f64, f64, f64, Option<String>, Option<String>, String, String, bool)> = sqlx::query_as(
        "SELECT id, first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, default_availability, availability, deleted
         FROM employees WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(employee_from_row))
}

pub async fn list_employees(pool: &SqlitePool) -> Result<Vec<Employee>, sqlx::Error> {
    let rows: Vec<(i64, String, String, Option<String>, String, String, f64, f64, f64, Option<String>, Option<String>, String, String, bool)> = sqlx::query_as(
        "SELECT id, first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, default_availability, availability, deleted
         FROM employees WHERE deleted = 0 ORDER BY start_date",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(employee_from_row).collect())
}

/// List all employees including soft-deleted ones (for historical schedule display).
pub async fn list_all_employees(pool: &SqlitePool) -> Result<Vec<Employee>, sqlx::Error> {
    let rows: Vec<(i64, String, String, Option<String>, String, String, f64, f64, f64, Option<String>, Option<String>, String, String, bool)> = sqlx::query_as(
        "SELECT id, first_name, last_name, nickname, roles, start_date, target_weekly_hours, weekly_hours_deviation, max_daily_hours, notes, bank_details, default_availability, availability, deleted
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
        "UPDATE employees SET first_name = ?, last_name = ?, nickname = ?, roles = ?, start_date = ?, target_weekly_hours = ?, weekly_hours_deviation = ?, max_daily_hours = ?,
         notes = ?, bank_details = ?, default_availability = ?, availability = ? WHERE id = ?",
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
        Option<String>,
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

/// Delete a rota and all its data. Deletes all shifts first (which cascades
/// to assignments via the ON DELETE CASCADE FK), then removes the rota row.
pub async fn delete_rota(pool: &SqlitePool, id: i64) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM shifts WHERE rota_id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM rotas WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
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
    let id: i64 =
        sqlx::query_scalar("INSERT INTO roles (name) VALUES (?) RETURNING id")
            .bind(name)
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

    // Update the role name.
    sqlx::query("UPDATE roles SET name = ? WHERE id = ?")
        .bind(new_name)
        .bind(id)
        .execute(pool)
        .await?;

    // Cascade: update shift_templates.required_role
    sqlx::query("UPDATE shift_templates SET required_role = ? WHERE required_role = ?")
        .bind(new_name)
        .bind(&old_name)
        .execute(pool)
        .await?;

    // Cascade: update shifts.required_role
    sqlx::query("UPDATE shifts SET required_role = ? WHERE required_role = ?")
        .bind(new_name)
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
        sqlx::query("UPDATE employees SET roles = ? WHERE id = ?")
            .bind(&updated_json)
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
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO employee_availability_overrides (employee_id, date, availability, notes)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(employee_id, date) DO UPDATE SET availability = excluded.availability, notes = excluded.notes
         RETURNING id",
    )
    .bind(ovr.employee_id)
    .bind(ovr.date.to_string())
    .bind(&avail_json)
    .bind(&ovr.notes)
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
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO shift_template_overrides (template_id, date, cancelled, start_time, end_time, min_employees, max_employees, notes)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(template_id, date) DO UPDATE SET
           cancelled = excluded.cancelled,
           start_time = excluded.start_time,
           end_time = excluded.end_time,
           min_employees = excluded.min_employees,
           max_employees = excluded.max_employees,
           notes = excluded.notes
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
