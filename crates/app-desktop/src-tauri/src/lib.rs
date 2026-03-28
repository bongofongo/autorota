use autorota_core::db;
use autorota_core::db::queries;
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::AvailabilityState;
use autorota_core::models::employee::Employee;
use autorota_core::models::overrides::{DayAvailability, EmployeeAvailabilityOverride, ShiftTemplateOverride};
use autorota_core::models::rota::Rota;
use autorota_core::models::role::Role;
use autorota_core::models::shift::ShiftTemplate;
use autorota_core::models::shift_history::EmployeeShiftRecord;
use autorota_core::scheduler;
use autorota_core::scheduler::ScheduleResult;
use chrono::{Datelike, Local, NaiveDate, NaiveTime};
use sqlx::SqlitePool;
use std::collections::HashMap;
use tauri::{AppHandle, Manager, State};
use tokio::sync::Mutex;

struct AppState {
    pool: Mutex<Option<SqlitePool>>,
}

async fn get_pool(state: &State<'_, AppState>) -> Result<SqlitePool, String> {
    let guard = state.pool.lock().await;
    guard
        .clone()
        .ok_or_else(|| "Database not initialized".to_string())
}

// ─── Init ────────────────────────────────────────────────────

#[tauri::command]
async fn init_db(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    let app_data = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to resolve app data dir: {e}"))?;
    std::fs::create_dir_all(&app_data)
        .map_err(|e| format!("Failed to create app data dir: {e}"))?;
    let db_path = app_data.join("autorota.db");
    let url = format!("sqlite:{}", db_path.display());
    let pool = db::connect(&url).await.map_err(|e| e.to_string())?;
    let mut guard = state.pool.lock().await;
    *guard = Some(pool);
    Ok(())
}

// ─── Employees ───────────────────────────────────────────────

#[tauri::command]
async fn list_employees(state: State<'_, AppState>) -> Result<Vec<Employee>, String> {
    let pool = get_pool(&state).await?;
    queries::list_employees(&pool)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_employee(state: State<'_, AppState>, id: i64) -> Result<Option<Employee>, String> {
    let pool = get_pool(&state).await?;
    queries::get_employee(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_employee(state: State<'_, AppState>, employee: Employee) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    queries::insert_employee(&pool, &employee)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_employee(state: State<'_, AppState>, employee: Employee) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::update_employee(&pool, &employee)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_employee(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::delete_employee(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// ─── Roles ──────────────────────────────────────────────────

#[tauri::command]
async fn list_roles(state: State<'_, AppState>) -> Result<Vec<Role>, String> {
    let pool = get_pool(&state).await?;
    queries::list_roles(&pool)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_role(state: State<'_, AppState>, name: String) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    queries::insert_role(&pool, &name)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_role(state: State<'_, AppState>, id: i64, name: String) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::update_role(&pool, id, &name)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_role(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::delete_role(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// ─── Shift Templates ─────────────────────────────────────────

#[tauri::command]
async fn list_shift_templates(state: State<'_, AppState>) -> Result<Vec<ShiftTemplate>, String> {
    let pool = get_pool(&state).await?;
    queries::list_shift_templates(&pool)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_shift_template(
    state: State<'_, AppState>,
    template: ShiftTemplate,
) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    queries::insert_shift_template(&pool, &template)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_shift_template(
    state: State<'_, AppState>,
    template: ShiftTemplate,
) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::update_shift_template(&pool, &template)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_shift_template(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::delete_shift_template(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// ─── Rotas ───────────────────────────────────────────────────

#[tauri::command]
async fn get_rota(state: State<'_, AppState>, id: i64) -> Result<Option<Rota>, String> {
    let pool = get_pool(&state).await?;
    queries::get_rota(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_rota_by_week(
    state: State<'_, AppState>,
    week_start: String,
) -> Result<Option<Rota>, String> {
    let pool = get_pool(&state).await?;
    let date = NaiveDate::parse_from_str(&week_start, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;
    queries::get_rota_by_week(&pool, date)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_rota(state: State<'_, AppState>, week_start: String) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    let date = NaiveDate::parse_from_str(&week_start, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;
    queries::insert_rota(&pool, date)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn finalize_rota(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::finalize_rota(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// ─── Assignments ─────────────────────────────────────────────

#[tauri::command]
async fn create_assignment(
    state: State<'_, AppState>,
    mut assignment: Assignment,
) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    // Snapshot the employee name if not already set
    if assignment.employee_name.is_none() {
        if let Some(emp) = queries::get_employee(&pool, assignment.employee_id)
            .await
            .map_err(|e| e.to_string())?
        {
            assignment.employee_name = Some(emp.display_name());
        }
    }
    queries::insert_assignment(&pool, &assignment)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_assignment_status(
    state: State<'_, AppState>,
    id: i64,
    status: AssignmentStatus,
) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::update_assignment_status(&pool, id, status)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn move_assignment(
    state: State<'_, AppState>,
    id: i64,
    new_shift_id: i64,
) -> Result<(), String> {
    let pool = get_pool(&state).await?;

    // Load the assignment to find its rota
    let assignment = sqlx::query_as::<_, (i64, i64, i64, i64, String, Option<String>)>(
        "SELECT id, rota_id, shift_id, employee_id, status, employee_name FROM assignments WHERE id = ?"
    )
    .bind(id)
    .fetch_optional(&pool)
    .await
    .map_err(|e| e.to_string())?
    .ok_or("Assignment not found")?;

    let rota_id = assignment.1;

    // Validate target shift belongs to same rota
    let target_shift = sqlx::query_as::<_, (i64, i64, u32)>(
        "SELECT id, rota_id, max_employees FROM shifts WHERE id = ?"
    )
    .bind(new_shift_id)
    .fetch_optional(&pool)
    .await
    .map_err(|e| e.to_string())?
    .ok_or("Target shift not found")?;

    if target_shift.1 != rota_id {
        return Err("Target shift belongs to a different rota".into());
    }

    // Check capacity
    let current_count: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM assignments WHERE shift_id = ?"
    )
    .bind(new_shift_id)
    .fetch_one(&pool)
    .await
    .map_err(|e| e.to_string())?;

    if current_count.0 >= target_shift.2 as i64 {
        return Err("Target shift is at capacity".into());
    }

    queries::update_assignment_shift(&pool, id, new_shift_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn swap_assignments(
    state: State<'_, AppState>,
    id_a: i64,
    id_b: i64,
) -> Result<(), String> {
    let pool = get_pool(&state).await?;

    let a = sqlx::query_as::<_, (i64, i64)>(
        "SELECT id, shift_id FROM assignments WHERE id = ?"
    )
    .bind(id_a)
    .fetch_optional(&pool)
    .await
    .map_err(|e| e.to_string())?
    .ok_or("Assignment A not found")?;

    let b = sqlx::query_as::<_, (i64, i64)>(
        "SELECT id, shift_id FROM assignments WHERE id = ?"
    )
    .bind(id_b)
    .fetch_optional(&pool)
    .await
    .map_err(|e| e.to_string())?
    .ok_or("Assignment B not found")?;

    queries::swap_assignment_shifts(&pool, a.0, a.1, b.0, b.1)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_assignment(
    state: State<'_, AppState>,
    id: i64,
) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::delete_assignment(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_shift(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::delete_shift(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_shift_times(
    state: State<'_, AppState>,
    id: i64,
    start_time: String,
    end_time: String,
) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    let start = chrono::NaiveTime::parse_from_str(&start_time, "%H:%M")
        .or_else(|_| chrono::NaiveTime::parse_from_str(&start_time, "%H:%M:%S"))
        .map_err(|e| format!("Invalid start time: {e}"))?;
    let end = chrono::NaiveTime::parse_from_str(&end_time, "%H:%M")
        .or_else(|_| chrono::NaiveTime::parse_from_str(&end_time, "%H:%M:%S"))
        .map_err(|e| format!("Invalid end time: {e}"))?;
    queries::update_shift_times(&pool, id, start, end)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_ad_hoc_shift(
    state: State<'_, AppState>,
    rota_id: i64,
    date: String,
    start_time: String,
    end_time: String,
    required_role: String,
) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    let shift_date = NaiveDate::parse_from_str(&date, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;
    let start = chrono::NaiveTime::parse_from_str(&start_time, "%H:%M")
        .map_err(|e| format!("Invalid start time: {e}"))?;
    let end = chrono::NaiveTime::parse_from_str(&end_time, "%H:%M")
        .map_err(|e| format!("Invalid end time: {e}"))?;

    let shift = autorota_core::models::shift::Shift {
        id: 0,
        template_id: None,
        rota_id,
        date: shift_date,
        start_time: start,
        end_time: end,
        required_role,
        min_employees: 1,
        max_employees: 1,
    };

    queries::insert_shift(&pool, &shift)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn materialise_week(
    state: State<'_, AppState>,
    week_start: String,
) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    let date = NaiveDate::parse_from_str(&week_start, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;

    // Reuse existing rota or create new one with materialised shifts
    match queries::get_rota_by_week(&pool, date)
        .await
        .map_err(|e| e.to_string())?
    {
        Some(existing) => Ok(existing.id),
        None => {
            let id = queries::insert_rota(&pool, date)
                .await
                .map_err(|e| e.to_string())?;
            queries::materialise_shifts(&pool, id, date)
                .await
                .map_err(|e| e.to_string())?;
            Ok(id)
        }
    }
}

// ─── Scheduling ──────────────────────────────────────────────

/// Create a rota for the given week, materialise shifts from templates,
/// run the scheduling algorithm, and return the result.
#[tauri::command]
async fn run_schedule(
    state: State<'_, AppState>,
    week_start: String,
) -> Result<ScheduleResult, String> {
    let pool = get_pool(&state).await?;
    let date = NaiveDate::parse_from_str(&week_start, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;

    // Guard: only allow scheduling for future weeks
    let today = Local::now().date_naive();
    let current_monday = today - chrono::Duration::days(today.weekday().num_days_from_monday() as i64);
    if date <= current_monday {
        return Err("Cannot generate schedule for current or past weeks".to_string());
    }

    println!("[run_schedule] week_start={}", date);

    // Create or reuse the rota for this week
    let rota_id = match queries::get_rota_by_week(&pool, date)
        .await
        .map_err(|e| e.to_string())?
    {
        Some(existing) => {
            if existing.finalized {
                return Err("This week's rota is already finalized".to_string());
            }
            println!(
                "[run_schedule] Reusing existing rota_id={}, clearing assignments and re-materialising shifts",
                existing.id
            );
            // Clear all proposed assignments and stale shifts, then re-materialise
            // from the current templates so deleted/changed templates take effect.
            queries::delete_proposed_assignments(&pool, existing.id)
                .await
                .map_err(|e| e.to_string())?;
            queries::delete_shifts_for_rota(&pool, existing.id)
                .await
                .map_err(|e| e.to_string())?;
            queries::materialise_shifts(&pool, existing.id, date)
                .await
                .map_err(|e| e.to_string())?;
            existing.id
        }
        None => {
            let id = queries::insert_rota(&pool, date)
                .await
                .map_err(|e| e.to_string())?;
            println!(
                "[run_schedule] Created new rota_id={}, materialising shifts",
                id
            );
            queries::materialise_shifts(&pool, id, date)
                .await
                .map_err(|e| e.to_string())?;
            id
        }
    };

    let result = scheduler::schedule(&pool, rota_id)
        .await
        .map_err(|e| e.to_string())?;
    println!(
        "[run_schedule] Complete: {} assignments, {} warnings",
        result.assignments.len(),
        result.warnings.len()
    );
    Ok(result)
}

/// Get the full rota for a week including shifts and employee names.
#[tauri::command]
async fn get_week_schedule(
    state: State<'_, AppState>,
    week_start: String,
) -> Result<Option<WeekSchedule>, String> {
    let pool = get_pool(&state).await?;
    let date = NaiveDate::parse_from_str(&week_start, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;

    let rota = match queries::get_rota_by_week(&pool, date)
        .await
        .map_err(|e| e.to_string())?
    {
        Some(r) => r,
        None => return Ok(None),
    };

    let shifts = queries::list_shifts_for_rota(&pool, rota.id)
        .await
        .map_err(|e| e.to_string())?;
    // Use list_all_employees (including soft-deleted) so historical schedules can resolve names
    let employees = queries::list_all_employees(&pool)
        .await
        .map_err(|e| e.to_string())?;

    let emp_map: std::collections::HashMap<i64, &Employee> =
        employees.iter().map(|e| (e.id, e)).collect();

    let entries: Vec<ScheduleEntry> = rota
        .assignments
        .iter()
        .filter_map(|a| {
            let shift = shifts.iter().find(|s| s.id == a.shift_id)?;
            // Resolve employee name: prefer live employee data, fall back to snapshot
            let employee_name = emp_map
                .get(&a.employee_id)
                .map(|e| e.display_name())
                .or_else(|| a.employee_name.clone())
                .unwrap_or_else(|| format!("Employee #{}", a.employee_id));
            Some(ScheduleEntry {
                assignment_id: a.id,
                shift_id: shift.id,
                date: shift.date.to_string(),
                weekday: shift.weekday().to_string(),
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

    let shift_infos: Vec<ShiftInfo> = shifts
        .iter()
        .map(|s| ShiftInfo {
            id: s.id,
            date: s.date.to_string(),
            weekday: s.weekday().to_string(),
            start_time: s.start_time.format("%H:%M").to_string(),
            end_time: s.end_time.format("%H:%M").to_string(),
            required_role: s.required_role.clone(),
            min_employees: s.min_employees,
            max_employees: s.max_employees,
        })
        .collect();

    Ok(Some(WeekSchedule {
        rota_id: rota.id,
        week_start: rota.week_start.to_string(),
        finalized: rota.finalized,
        entries,
        shifts: shift_infos,
    }))
}

#[derive(serde::Serialize)]
struct ScheduleEntry {
    assignment_id: i64,
    shift_id: i64,
    date: String,
    weekday: String,
    start_time: String,
    end_time: String,
    required_role: String,
    employee_id: i64,
    employee_name: String,
    status: String,
    max_employees: u32,
}

#[derive(serde::Serialize)]
struct ShiftInfo {
    id: i64,
    date: String,
    weekday: String,
    start_time: String,
    end_time: String,
    required_role: String,
    min_employees: u32,
    max_employees: u32,
}

#[derive(serde::Serialize)]
struct WeekSchedule {
    rota_id: i64,
    week_start: String,
    finalized: bool,
    entries: Vec<ScheduleEntry>,
    shifts: Vec<ShiftInfo>,
}

// ─── Employee Shift History ─────────────────────────────────

#[derive(serde::Serialize)]
struct TauriEmployeeShiftRecord {
    assignment_id: i64,
    rota_id: i64,
    shift_id: i64,
    employee_id: i64,
    status: String,
    employee_name: Option<String>,
    date: String,
    weekday: String,
    start_time: String,
    end_time: String,
    required_role: String,
    duration_hours: f32,
    week_start: String,
    finalized: bool,
}

fn shift_record_to_tauri(r: EmployeeShiftRecord) -> TauriEmployeeShiftRecord {
    let duration = r.duration_hours();
    TauriEmployeeShiftRecord {
        assignment_id: r.assignment_id,
        rota_id: r.rota_id,
        shift_id: r.shift_id,
        employee_id: r.employee_id,
        status: r.status.to_string(),
        employee_name: r.employee_name,
        date: r.date.to_string(),
        weekday: r.date.weekday().to_string(),
        start_time: r.start_time.format("%H:%M").to_string(),
        end_time: r.end_time.format("%H:%M").to_string(),
        required_role: r.required_role,
        duration_hours: duration,
        week_start: r.week_start.to_string(),
        finalized: r.finalized,
    }
}

#[tauri::command]
async fn list_employee_shift_history(
    state: State<'_, AppState>,
    employee_id: i64,
) -> Result<Vec<TauriEmployeeShiftRecord>, String> {
    let pool = get_pool(&state).await?;
    queries::list_employee_shift_history(&pool, employee_id)
        .await
        .map(|records| records.into_iter().map(shift_record_to_tauri).collect())
        .map_err(|e| e.to_string())
}

// ─── Override DTOs ───────────────────────────────────────────
// Thin structs that use String/HashMap so Tauri's JSON layer
// handles chrono types without relying on chrono's serde impl.

#[derive(serde::Deserialize, serde::Serialize, Clone)]
struct TauriEmployeeAvailabilityOverride {
    id: i64,
    employee_id: i64,
    date: String,
    /// {"8":"Yes","9":"Maybe",...}
    availability: HashMap<String, String>,
    notes: Option<String>,
}

#[derive(serde::Deserialize, serde::Serialize, Clone)]
struct TauriShiftTemplateOverride {
    id: i64,
    template_id: i64,
    date: String,
    cancelled: bool,
    start_time: Option<String>,
    end_time: Option<String>,
    min_employees: Option<u32>,
    max_employees: Option<u32>,
    notes: Option<String>,
}

fn tauri_to_employee_avail_override(
    dto: TauriEmployeeAvailabilityOverride,
) -> Result<EmployeeAvailabilityOverride, String> {
    let date = NaiveDate::parse_from_str(&dto.date, "%Y-%m-%d")
        .map_err(|e| format!("invalid date '{}': {e}", dto.date))?;
    let mut avail = DayAvailability::default();
    for (hour_str, state_str) in dto.availability {
        let hour: u8 = hour_str.parse().map_err(|_| format!("invalid hour key: {hour_str}"))?;
        let state: AvailabilityState = state_str
            .parse()
            .map_err(|e| format!("invalid state '{state_str}': {e}"))?;
        avail.set(hour, state);
    }
    Ok(EmployeeAvailabilityOverride {
        id: dto.id,
        employee_id: dto.employee_id,
        date,
        availability: avail,
        notes: dto.notes,
    })
}

fn employee_avail_override_to_tauri(
    ovr: EmployeeAvailabilityOverride,
) -> TauriEmployeeAvailabilityOverride {
    let avail_map: HashMap<String, String> = ovr
        .availability
        .0
        .into_iter()
        .map(|(h, s)| (h.to_string(), s.to_string()))
        .collect();
    TauriEmployeeAvailabilityOverride {
        id: ovr.id,
        employee_id: ovr.employee_id,
        date: ovr.date.to_string(),
        availability: avail_map,
        notes: ovr.notes,
    }
}

fn parse_optional_time(s: Option<&str>) -> Result<Option<NaiveTime>, String> {
    match s {
        None => Ok(None),
        Some(t) => NaiveTime::parse_from_str(t, "%H:%M")
            .or_else(|_| NaiveTime::parse_from_str(t, "%H:%M:%S"))
            .map(Some)
            .map_err(|e| format!("invalid time '{t}': {e}")),
    }
}

fn tauri_to_shift_template_override(
    dto: TauriShiftTemplateOverride,
) -> Result<ShiftTemplateOverride, String> {
    let date = NaiveDate::parse_from_str(&dto.date, "%Y-%m-%d")
        .map_err(|e| format!("invalid date '{}': {e}", dto.date))?;
    Ok(ShiftTemplateOverride {
        id: dto.id,
        template_id: dto.template_id,
        date,
        cancelled: dto.cancelled,
        start_time: parse_optional_time(dto.start_time.as_deref())?,
        end_time: parse_optional_time(dto.end_time.as_deref())?,
        min_employees: dto.min_employees,
        max_employees: dto.max_employees,
        notes: dto.notes,
    })
}

fn shift_template_override_to_tauri(ovr: ShiftTemplateOverride) -> TauriShiftTemplateOverride {
    TauriShiftTemplateOverride {
        id: ovr.id,
        template_id: ovr.template_id,
        date: ovr.date.to_string(),
        cancelled: ovr.cancelled,
        start_time: ovr.start_time.map(|t| t.format("%H:%M").to_string()),
        end_time: ovr.end_time.map(|t| t.format("%H:%M").to_string()),
        min_employees: ovr.min_employees,
        max_employees: ovr.max_employees,
        notes: ovr.notes,
    }
}

// ─── Employee Availability Override commands ──────────────────

#[tauri::command]
async fn upsert_employee_availability_override(
    state: State<'_, AppState>,
    override_: TauriEmployeeAvailabilityOverride,
) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    let ovr = tauri_to_employee_avail_override(override_)?;
    queries::upsert_employee_availability_override(&pool, &ovr)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_employee_availability_override(
    state: State<'_, AppState>,
    employee_id: i64,
    date: String,
) -> Result<Option<TauriEmployeeAvailabilityOverride>, String> {
    let pool = get_pool(&state).await?;
    let d = NaiveDate::parse_from_str(&date, "%Y-%m-%d")
        .map_err(|e| format!("invalid date '{date}': {e}"))?;
    queries::get_employee_availability_override(&pool, employee_id, d)
        .await
        .map(|opt| opt.map(employee_avail_override_to_tauri))
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn list_employee_availability_overrides(
    state: State<'_, AppState>,
    employee_id: i64,
) -> Result<Vec<TauriEmployeeAvailabilityOverride>, String> {
    let pool = get_pool(&state).await?;
    queries::list_employee_availability_overrides_for_employee(&pool, employee_id)
        .await
        .map(|v| v.into_iter().map(employee_avail_override_to_tauri).collect())
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn list_all_employee_availability_overrides(
    state: State<'_, AppState>,
) -> Result<Vec<TauriEmployeeAvailabilityOverride>, String> {
    let pool = get_pool(&state).await?;
    queries::list_all_employee_availability_overrides(&pool)
        .await
        .map(|v| v.into_iter().map(employee_avail_override_to_tauri).collect())
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_employee_availability_override(
    state: State<'_, AppState>,
    id: i64,
) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::delete_employee_availability_override(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// ─── Shift Template Override commands ────────────────────────

#[tauri::command]
async fn upsert_shift_template_override(
    state: State<'_, AppState>,
    override_: TauriShiftTemplateOverride,
) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    let ovr = tauri_to_shift_template_override(override_)?;
    queries::upsert_shift_template_override(&pool, &ovr)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_shift_template_override(
    state: State<'_, AppState>,
    template_id: i64,
    date: String,
) -> Result<Option<TauriShiftTemplateOverride>, String> {
    let pool = get_pool(&state).await?;
    let d = NaiveDate::parse_from_str(&date, "%Y-%m-%d")
        .map_err(|e| format!("invalid date '{date}': {e}"))?;
    queries::get_shift_template_override(&pool, template_id, d)
        .await
        .map(|opt| opt.map(shift_template_override_to_tauri))
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn list_shift_template_overrides_for_template(
    state: State<'_, AppState>,
    template_id: i64,
) -> Result<Vec<TauriShiftTemplateOverride>, String> {
    let pool = get_pool(&state).await?;
    queries::list_shift_template_overrides_for_template(&pool, template_id)
        .await
        .map(|v| v.into_iter().map(shift_template_override_to_tauri).collect())
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn list_all_shift_template_overrides(
    state: State<'_, AppState>,
) -> Result<Vec<TauriShiftTemplateOverride>, String> {
    let pool = get_pool(&state).await?;
    queries::list_all_shift_template_overrides(&pool)
        .await
        .map(|v| v.into_iter().map(shift_template_override_to_tauri).collect())
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_shift_template_override(
    state: State<'_, AppState>,
    id: i64,
) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::delete_shift_template_override(&pool, id)
        .await
        .map_err(|e| e.to_string())
}

// ─── App entry ───────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState {
            pool: Mutex::new(None),
        })
        .invoke_handler(tauri::generate_handler![
            init_db,
            list_roles,
            create_role,
            update_role,
            delete_role,
            list_employees,
            get_employee,
            create_employee,
            update_employee,
            delete_employee,
            list_shift_templates,
            create_shift_template,
            update_shift_template,
            delete_shift_template,
            get_rota,
            get_rota_by_week,
            create_rota,
            finalize_rota,
            create_assignment,
            update_assignment_status,
            move_assignment,
            swap_assignments,
            delete_assignment,
            delete_shift,
            update_shift_times,
            create_ad_hoc_shift,
            materialise_week,
            run_schedule,
            get_week_schedule,
            upsert_employee_availability_override,
            get_employee_availability_override,
            list_employee_availability_overrides,
            list_all_employee_availability_overrides,
            delete_employee_availability_override,
            upsert_shift_template_override,
            get_shift_template_override,
            list_shift_template_overrides_for_template,
            list_all_shift_template_overrides,
            delete_shift_template_override,
            list_employee_shift_history,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
