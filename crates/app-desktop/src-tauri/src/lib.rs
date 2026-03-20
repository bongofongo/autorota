use autorota_core::db;
use autorota_core::db::queries;
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::employee::Employee;
use autorota_core::models::rota::Rota;
use autorota_core::models::shift::ShiftTemplate;
use autorota_core::scheduler;
use autorota_core::scheduler::ScheduleResult;
use chrono::NaiveDate;
use sqlx::SqlitePool;
use tauri::{AppHandle, Manager, State};
use tokio::sync::Mutex;

struct AppState {
    pool: Mutex<Option<SqlitePool>>,
}

async fn get_pool(state: &State<'_, AppState>) -> Result<SqlitePool, String> {
    let guard = state.pool.lock().await;
    guard.clone().ok_or_else(|| "Database not initialized".to_string())
}

// ─── Init ────────────────────────────────────────────────────

#[tauri::command]
async fn init_db(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    let app_data = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to resolve app data dir: {e}"))?;
    std::fs::create_dir_all(&app_data).map_err(|e| format!("Failed to create app data dir: {e}"))?;
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
    queries::list_employees(&pool).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_employee(state: State<'_, AppState>, id: i64) -> Result<Option<Employee>, String> {
    let pool = get_pool(&state).await?;
    queries::get_employee(&pool, id).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_employee(state: State<'_, AppState>, employee: Employee) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    queries::insert_employee(&pool, &employee).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_employee(state: State<'_, AppState>, employee: Employee) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::update_employee(&pool, &employee).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_employee(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::delete_employee(&pool, id).await.map_err(|e| e.to_string())
}

// ─── Shift Templates ─────────────────────────────────────────

#[tauri::command]
async fn list_shift_templates(state: State<'_, AppState>) -> Result<Vec<ShiftTemplate>, String> {
    let pool = get_pool(&state).await?;
    queries::list_shift_templates(&pool).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_shift_template(state: State<'_, AppState>, template: ShiftTemplate) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    queries::insert_shift_template(&pool, &template).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_shift_template(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::delete_shift_template(&pool, id).await.map_err(|e| e.to_string())
}

// ─── Rotas ───────────────────────────────────────────────────

#[tauri::command]
async fn get_rota(state: State<'_, AppState>, id: i64) -> Result<Option<Rota>, String> {
    let pool = get_pool(&state).await?;
    queries::get_rota(&pool, id).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_rota_by_week(state: State<'_, AppState>, week_start: String) -> Result<Option<Rota>, String> {
    let pool = get_pool(&state).await?;
    let date = NaiveDate::parse_from_str(&week_start, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;
    queries::get_rota_by_week(&pool, date).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_rota(state: State<'_, AppState>, week_start: String) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    let date = NaiveDate::parse_from_str(&week_start, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;
    queries::insert_rota(&pool, date).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn finalize_rota(state: State<'_, AppState>, id: i64) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::finalize_rota(&pool, id).await.map_err(|e| e.to_string())
}

// ─── Assignments ─────────────────────────────────────────────

#[tauri::command]
async fn create_assignment(state: State<'_, AppState>, assignment: Assignment) -> Result<i64, String> {
    let pool = get_pool(&state).await?;
    queries::insert_assignment(&pool, &assignment).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_assignment_status(
    state: State<'_, AppState>,
    id: i64,
    status: AssignmentStatus,
) -> Result<(), String> {
    let pool = get_pool(&state).await?;
    queries::update_assignment_status(&pool, id, status).await.map_err(|e| e.to_string())
}

// ─── Scheduling ──────────────────────────────────────────────

/// Create a rota for the given week, materialise shifts from templates,
/// run the scheduling algorithm, and return the result.
#[tauri::command]
async fn run_schedule(state: State<'_, AppState>, week_start: String) -> Result<ScheduleResult, String> {
    let pool = get_pool(&state).await?;
    let date = NaiveDate::parse_from_str(&week_start, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;

    println!("[run_schedule] week_start={}", date);

    // Create or reuse the rota for this week
    let rota_id = match queries::get_rota_by_week(&pool, date).await.map_err(|e| e.to_string())? {
        Some(existing) => {
            if existing.finalized {
                return Err("This week's rota is already finalized".to_string());
            }
            println!("[run_schedule] Reusing existing rota_id={}, clearing assignments and re-materialising shifts", existing.id);
            // Clear all proposed assignments and stale shifts, then re-materialise
            // from the current templates so deleted/changed templates take effect.
            queries::delete_proposed_assignments(&pool, existing.id).await.map_err(|e| e.to_string())?;
            queries::delete_shifts_for_rota(&pool, existing.id).await.map_err(|e| e.to_string())?;
            queries::materialise_shifts(&pool, existing.id, date).await.map_err(|e| e.to_string())?;
            existing.id
        }
        None => {
            let id = queries::insert_rota(&pool, date).await.map_err(|e| e.to_string())?;
            println!("[run_schedule] Created new rota_id={}, materialising shifts", id);
            queries::materialise_shifts(&pool, id, date).await.map_err(|e| e.to_string())?;
            id
        }
    };

    let result = scheduler::schedule(&pool, rota_id).await.map_err(|e| e.to_string())?;
    println!("[run_schedule] Complete: {} assignments, {} warnings", result.assignments.len(), result.warnings.len());
    Ok(result)
}

/// Get the full rota for a week including shifts and employee names.
#[tauri::command]
async fn get_week_schedule(state: State<'_, AppState>, week_start: String) -> Result<Option<WeekSchedule>, String> {
    let pool = get_pool(&state).await?;
    let date = NaiveDate::parse_from_str(&week_start, "%Y-%m-%d")
        .map_err(|e| format!("Invalid date: {e}"))?;

    let rota = match queries::get_rota_by_week(&pool, date).await.map_err(|e| e.to_string())? {
        Some(r) => r,
        None => return Ok(None),
    };

    let shifts = queries::list_shifts_for_rota(&pool, rota.id).await.map_err(|e| e.to_string())?;
    let employees = queries::list_employees(&pool).await.map_err(|e| e.to_string())?;

    let emp_map: std::collections::HashMap<i64, &Employee> = employees.iter().map(|e| (e.id, e)).collect();

    let entries: Vec<ScheduleEntry> = rota.assignments.iter().filter_map(|a| {
        let shift = shifts.iter().find(|s| s.id == a.shift_id)?;
        let emp = emp_map.get(&a.employee_id)?;
        Some(ScheduleEntry {
            shift_id: shift.id,
            date: shift.date.to_string(),
            weekday: shift.weekday().to_string(),
            start_time: shift.start_time.format("%H:%M").to_string(),
            end_time: shift.end_time.format("%H:%M").to_string(),
            required_role: shift.required_role.clone(),
            employee_id: emp.id,
            employee_name: emp.name.clone(),
            status: a.status.to_string(),
        })
    }).collect();

    Ok(Some(WeekSchedule {
        rota_id: rota.id,
        week_start: rota.week_start.to_string(),
        finalized: rota.finalized,
        entries,
    }))
}

#[derive(serde::Serialize)]
struct ScheduleEntry {
    shift_id: i64,
    date: String,
    weekday: String,
    start_time: String,
    end_time: String,
    required_role: String,
    employee_id: i64,
    employee_name: String,
    status: String,
}

#[derive(serde::Serialize)]
struct WeekSchedule {
    rota_id: i64,
    week_start: String,
    finalized: bool,
    entries: Vec<ScheduleEntry>,
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
            list_employees,
            get_employee,
            create_employee,
            update_employee,
            delete_employee,
            list_shift_templates,
            create_shift_template,
            delete_shift_template,
            get_rota,
            get_rota_by_week,
            create_rota,
            finalize_rota,
            create_assignment,
            update_assignment_status,
            run_schedule,
            get_week_schedule,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
