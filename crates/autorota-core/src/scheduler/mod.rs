pub mod scoring;
pub mod tiebreak;

use crate::models::assignment::{Assignment, AssignmentStatus};
use crate::models::availability::AvailabilityState;
use crate::models::employee::Employee;
use crate::models::shift::Shift;
use chrono::NaiveDate;
use std::collections::HashMap;

// ─── Types ───────────────────────────────────────────────────

/// A shift that could not be fully staffed.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ShortfallWarning {
    pub shift_id: i64,
    pub needed: u32,
    pub filled: u32,
}

/// The output of a scheduling run.
#[derive(Debug, serde::Serialize)]
pub struct ScheduleResult {
    pub assignments: Vec<Assignment>,
    pub warnings: Vec<ShortfallWarning>,
}

#[derive(Debug, thiserror::Error)]
pub enum SchedulerError {
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("rota not found: {0}")]
    RotaNotFound(i64),
    #[error("rota {0} is already finalized")]
    AlreadyFinalized(i64),
}

/// Mutable state accumulated during a scheduling run.
struct SchedulerState {
    /// employee_id → total hours assigned this week
    weekly_hours: HashMap<i64, f32>,
    /// (employee_id, date) → total hours assigned on that day
    daily_hours: HashMap<(i64, NaiveDate), f32>,
    /// shift_id → employee_ids assigned to that shift
    shift_assignments: HashMap<i64, Vec<i64>>,
    /// All assignments produced so far
    assignments: Vec<Assignment>,
}

impl SchedulerState {
    fn new() -> Self {
        Self {
            weekly_hours: HashMap::new(),
            daily_hours: HashMap::new(),
            shift_assignments: HashMap::new(),
            assignments: Vec::new(),
        }
    }

    fn record_assignment(
        &mut self,
        employee_id: i64,
        shift: &Shift,
        rota_id: i64,
        status: AssignmentStatus,
    ) {
        let hours = shift.duration_hours();
        *self.weekly_hours.entry(employee_id).or_default() += hours;
        *self
            .daily_hours
            .entry((employee_id, shift.date))
            .or_default() += hours;
        self.shift_assignments
            .entry(shift.id)
            .or_default()
            .push(employee_id);
        self.assignments.push(Assignment {
            id: 0,
            rota_id,
            shift_id: shift.id,
            employee_id,
            status,
        });
    }

    fn employee_weekly_hours(&self, employee_id: i64) -> f32 {
        self.weekly_hours.get(&employee_id).copied().unwrap_or(0.0)
    }

    fn employee_daily_hours(&self, employee_id: i64, date: NaiveDate) -> f32 {
        self.daily_hours
            .get(&(employee_id, date))
            .copied()
            .unwrap_or(0.0)
    }

    fn slots_filled(&self, shift_id: i64) -> u32 {
        self.shift_assignments
            .get(&shift_id)
            .map(|v| v.len() as u32)
            .unwrap_or(0)
    }

    fn is_assigned_to_shift(&self, employee_id: i64, shift_id: i64) -> bool {
        self.shift_assignments
            .get(&shift_id)
            .is_some_and(|ids| ids.contains(&employee_id))
    }
}

// ─── Eligibility ─────────────────────────────────────────────

fn is_eligible(
    employee: &Employee,
    shift: &Shift,
    state: &SchedulerState,
    all_shifts: &HashMap<i64, &Shift>,
) -> bool {
    // Must have the required role
    if !employee.has_role(&shift.required_role) {
        return false;
    }

    // Must not have No availability for any hour of the shift
    let avail =
        employee
            .availability
            .for_window(shift.weekday(), shift.start_hour(), shift.end_hour());
    if avail == AvailabilityState::No {
        return false;
    }

    // Must not already be assigned to this shift
    if state.is_assigned_to_shift(employee.id, shift.id) {
        return false;
    }

    let shift_hours = shift.duration_hours();

    // Must have daily budget remaining
    let daily = state.employee_daily_hours(employee.id, shift.date);
    if daily + shift_hours > employee.max_daily_hours {
        return false;
    }

    // Must have weekly budget remaining
    let weekly = state.employee_weekly_hours(employee.id);
    if weekly + shift_hours > employee.max_weekly_hours() {
        return false;
    }

    // Must not overlap with another shift on the same day
    if has_time_overlap(employee.id, shift, state, all_shifts) {
        return false;
    }

    true
}

fn has_time_overlap(
    employee_id: i64,
    shift: &Shift,
    state: &SchedulerState,
    all_shifts: &HashMap<i64, &Shift>,
) -> bool {
    for assignment in &state.assignments {
        if assignment.employee_id != employee_id {
            continue;
        }
        if let Some(existing) = all_shifts.get(&assignment.shift_id) {
            if existing.date != shift.date {
                continue;
            }
            // Two shifts overlap if one starts before the other ends and vice versa
            if shift.start_time < existing.end_time && existing.start_time < shift.end_time {
                return true;
            }
        }
    }
    false
}

// ─── Pure scheduling core ────────────────────────────────────

/// Pure function implementing the two-pass scheduling algorithm.
/// Takes all data as arguments — no DB access, easy to test.
pub fn schedule_pure(
    shifts: &[Shift],
    employees: &[Employee],
    existing_assignments: &[Assignment],
    rota_id: i64,
    week_start: NaiveDate,
) -> ScheduleResult {
    println!(
        "[Scheduler] Starting schedule_pure: {} shifts, {} employees, {} existing assignments, rota_id={}, week_start={}",
        shifts.len(),
        employees.len(),
        existing_assignments.len(),
        rota_id,
        week_start
    );
    for s in shifts {
        println!(
            "[Scheduler]   Shift id={} date={} {}–{} role={} min={} max={}",
            s.id,
            s.date,
            s.start_time,
            s.end_time,
            s.required_role,
            s.min_employees,
            s.max_employees
        );
    }
    for e in employees {
        println!(
            "[Scheduler]   Employee id={} name={} roles={:?} daily={}h target_weekly={}h (±{})",
            e.id,
            e.name,
            e.roles,
            e.max_daily_hours,
            e.target_weekly_hours,
            e.weekly_hours_deviation
        );
    }

    let shift_map: HashMap<i64, &Shift> = shifts.iter().map(|s| (s.id, s)).collect();
    let mut state = SchedulerState::new();
    let mut warnings = Vec::new();

    // ── Pass 1: Pre-assignments (overrides) ──────────────────
    for a in existing_assignments {
        if a.status != AssignmentStatus::Overridden {
            continue;
        }
        if let Some(shift) = shift_map.get(&a.shift_id) {
            state.record_assignment(a.employee_id, shift, rota_id, AssignmentStatus::Overridden);
        }
    }

    // ── Pass 2: Greedy assignment ────────────────────────────

    // Compute difficulty: count eligible employees per shift.
    // Sort shifts hardest-to-fill first.
    let mut shift_order: Vec<&Shift> = shifts
        .iter()
        .filter(|s| state.slots_filled(s.id) < s.max_employees)
        .collect();

    // Pre-compute difficulty for the initial sort
    let difficulty: HashMap<i64, usize> = shift_order
        .iter()
        .map(|s| {
            let eligible_count = employees
                .iter()
                .filter(|e| is_eligible(e, s, &state, &shift_map))
                .count();
            (s.id, eligible_count)
        })
        .collect();

    shift_order.sort_by(|a, b| {
        let diff_a = difficulty.get(&a.id).copied().unwrap_or(0);
        let diff_b = difficulty.get(&b.id).copied().unwrap_or(0);
        diff_a
            .cmp(&diff_b) // fewest eligible first
            .then(b.min_employees.cmp(&a.min_employees)) // larger capacity needs first
            .then(a.date.cmp(&b.date)) // earlier date first
            .then(a.start_time.cmp(&b.start_time)) // earlier time first
    });

    println!(
        "[Scheduler] Pass 2: {} shifts to fill (sorted by difficulty)",
        shift_order.len()
    );

    // For each shift, fill remaining slots one at a time
    for shift in &shift_order {
        let remaining = shift.max_employees - state.slots_filled(shift.id);
        println!(
            "[Scheduler]   Filling shift id={} {} {} {}–{} role={} (need {} more)",
            shift.id,
            shift.date,
            shift.weekday(),
            shift.start_time,
            shift.end_time,
            shift.required_role,
            remaining
        );

        for slot in 0..remaining {
            // Find and score all eligible candidates
            let mut candidates: Vec<(&Employee, (u8, i32, i32), u64)> = employees
                .iter()
                .filter(|e| {
                    let eligible = is_eligible(e, shift, &state, &shift_map);
                    if !eligible {
                        // Log why each employee is ineligible
                        let has_role = e.has_role(&shift.required_role);
                        let avail = e.availability.for_window(shift.weekday(), shift.start_hour(), shift.end_hour());
                        let already = state.is_assigned_to_shift(e.id, shift.id);
                        let daily = state.employee_daily_hours(e.id, shift.date);
                        let weekly = state.employee_weekly_hours(e.id);
                        let hours = shift.duration_hours();
                        println!("[Scheduler]     {} ineligible: role={} avail={} already_assigned={} daily={}/{}h weekly={}/{}h shift_hours={}", e.name, has_role, avail, already, daily, e.max_daily_hours, weekly, e.max_weekly_hours(), hours);
                    }
                    eligible
                })
                .map(|e| {
                    let weekly = state.employee_weekly_hours(e.id);
                    let daily = state.employee_daily_hours(e.id, shift.date);
                    let score = scoring::score_employee(e, shift, weekly, daily);
                    let tb = tiebreak::tiebreak_key(e.id, &week_start);
                    (e, score, tb)
                })
                .collect();

            println!(
                "[Scheduler]     Slot {}: {} eligible candidates",
                slot + 1,
                candidates.len()
            );

            if candidates.is_empty() {
                println!("[Scheduler]     No candidates available, stopping fill for this shift");
                break;
            }

            // Sort: best score first, then tiebreak (higher hash = wins)
            candidates.sort_by(|a, b| {
                b.1.cmp(&a.1) // score descending
                    .then(b.2.cmp(&a.2)) // tiebreak descending
            });

            let winner = candidates[0].0;
            println!(
                "[Scheduler]     Assigned: {} (score={:?})",
                winner.name, candidates[0].1
            );
            state.record_assignment(winner.id, shift, rota_id, AssignmentStatus::Proposed);
        }

        let filled = state.slots_filled(shift.id);
        if filled < shift.min_employees {
            warnings.push(ShortfallWarning {
                shift_id: shift.id,
                needed: shift.min_employees,
                filled,
            });
        }
    }

    println!(
        "[Scheduler] Done: {} assignments, {} warnings",
        state.assignments.len(),
        warnings.len()
    );
    ScheduleResult {
        assignments: state.assignments,
        warnings,
    }
}

// ─── Async DB wrapper ────────────────────────────────────────

/// Load data from the database, run the scheduler, and persist new assignments.
pub async fn schedule(
    pool: &sqlx::SqlitePool,
    rota_id: i64,
) -> Result<ScheduleResult, SchedulerError> {
    use crate::db::queries;

    let rota = queries::get_rota(pool, rota_id)
        .await?
        .ok_or(SchedulerError::RotaNotFound(rota_id))?;

    if rota.finalized {
        return Err(SchedulerError::AlreadyFinalized(rota_id));
    }

    let shifts = queries::list_shifts_for_rota(pool, rota_id).await?;
    let employees = queries::list_employees(pool).await?;
    let existing = queries::list_assignments_for_rota(pool, rota_id).await?;

    let result = schedule_pure(&shifts, &employees, &existing, rota_id, rota.week_start);

    // Persist only newly generated assignments (not the existing overrides)
    for assignment in &result.assignments {
        if assignment.status == AssignmentStatus::Proposed {
            queries::insert_assignment(pool, assignment).await?;
        }
    }

    Ok(result)
}
