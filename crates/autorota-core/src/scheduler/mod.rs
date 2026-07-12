pub mod scoring;
pub mod tiebreak;

use crate::models::assignment::{Assignment, AssignmentStatus};
use crate::models::availability::AvailabilityState;
use crate::models::employee::Employee;
use crate::models::overrides::EmployeeAvailabilityOverride;
use crate::models::shift::Shift;
use chrono::{Datelike, Duration, NaiveDate, NaiveDateTime};
use std::collections::{HashMap, HashSet};

// ─── Overnight-aware time helpers ────────────────────────────

/// Concrete `[start, end)` interval for a shift. An overnight shift
/// (end_time <= start_time) ends on the following calendar day.
fn shift_interval(shift: &Shift) -> (NaiveDateTime, NaiveDateTime) {
    let start = shift.date.and_time(shift.start_time);
    // end == start is a zero-duration shift (matches duration_hours), not 24h.
    let end_date = if shift.end_time >= shift.start_time {
        shift.date
    } else {
        shift.date + Duration::days(1)
    };
    (start, end_date.and_time(shift.end_time))
}

/// Hours a shift contributes to each calendar day it touches. Overnight
/// shifts split at midnight; the second entry is zero-hours otherwise.
fn daily_hour_portions(shift: &Shift) -> [(NaiveDate, f32); 2] {
    if shift.end_time >= shift.start_time {
        [(shift.date, shift.duration_hours()), (shift.date, 0.0)]
    } else {
        let until_midnight = (86400
            - shift
                .start_time
                .signed_duration_since(chrono::NaiveTime::MIN)
                .num_seconds()) as f32
            / 3600.0;
        let after_midnight = shift
            .end_time
            .signed_duration_since(chrono::NaiveTime::MIN)
            .num_seconds() as f32
            / 3600.0;
        [
            (shift.date, until_midnight),
            (shift.date + Duration::days(1), after_midnight),
        ]
    }
}

// ─── Types ───────────────────────────────────────────────────

/// A shift that could not be fully staffed.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ShortfallWarning {
    pub shift_id: i64,
    pub needed: u32,
    pub filled: u32,
    pub weekday: String,
    pub start_time: String,
    pub end_time: String,
    /// Legacy display role (the role that fell short, or the shift's role).
    pub required_role: String,
    /// Which role fell short. `None` for an overall headcount shortfall.
    #[serde(default)]
    pub role: Option<String>,
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
}

/// Mutable state accumulated during a scheduling run.
struct SchedulerState {
    /// employee_id → total hours assigned this week
    weekly_hours: HashMap<i64, f32>,
    /// (employee_id, date) → total hours assigned on that day
    daily_hours: HashMap<(i64, NaiveDate), f32>,
    /// shift_id → employee_ids assigned to that shift
    shift_assignments: HashMap<i64, HashSet<i64>>,
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
        employee_name: Option<String>,
        hourly_wage: Option<f32>,
        shift: &Shift,
        rota_id: i64,
        status: AssignmentStatus,
    ) {
        *self.weekly_hours.entry(employee_id).or_default() += shift.duration_hours();
        for (day, hours) in daily_hour_portions(shift) {
            if hours > 0.0 {
                *self.daily_hours.entry((employee_id, day)).or_default() += hours;
            }
        }
        self.shift_assignments
            .entry(shift.id)
            .or_default()
            .insert(employee_id);
        self.assignments.push(Assignment {
            id: 0,
            rota_id,
            shift_id: shift.id,
            employee_id,
            status,
            employee_name,
            hourly_wage,
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
    avail_override_map: &HashMap<(i64, NaiveDate), &EmployeeAvailabilityOverride>,
) -> bool {
    // Role is no longer a hard eligibility gate — multi-role coverage is handled
    // by the two-stage fill (role minimums first, then any eligible employee).
    // Eligibility here is purely availability / hours / overlap / not-already-assigned.

    // Must not have No availability for any hour of the shift.
    // Use date-specific override when present, otherwise fall back to weekly availability.
    let avail = if let Some(ovr) = avail_override_map.get(&(employee.id, shift.date)) {
        // Invariant: the override's stored date must describe the same calendar
        // day as the shift. If it doesn't, the DB row is corrupt (raw edit or a
        // broken sync merge) and the override would silently apply to the wrong
        // weekday. Debug-only assertion — release builds trust the map key.
        debug_assert_eq!(
            ovr.date.weekday(),
            shift.date.weekday(),
            "override weekday does not match shift weekday: override date = {}, shift date = {}",
            ovr.date,
            shift.date
        );
        ovr.availability
            .for_window(shift.start_hour(), shift.end_hour())
    } else {
        employee
            .availability
            .for_window(shift.weekday(), shift.start_hour(), shift.end_hour())
    };
    if avail == AvailabilityState::No {
        return false;
    }

    // Must not already be assigned to this shift
    if state.is_assigned_to_shift(employee.id, shift.id) {
        return false;
    }

    // Must have daily budget remaining on every day the shift touches
    // (an overnight shift's tail counts toward the following day).
    for (day, hours) in daily_hour_portions(shift) {
        if hours > 0.0
            && state.employee_daily_hours(employee.id, day) + hours > employee.max_daily_hours
        {
            return false;
        }
    }

    // Must have weekly budget remaining
    let weekly = state.employee_weekly_hours(employee.id);
    if weekly + shift.duration_hours() > employee.max_weekly_hours() {
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
    let (start, end) = shift_interval(shift);
    for assignment in &state.assignments {
        if assignment.employee_id != employee_id {
            continue;
        }
        if let Some(existing) = all_shifts.get(&assignment.shift_id) {
            // Overnight shifts spill into the next day, so shifts up to one
            // calendar day apart can still collide.
            if (existing.date - shift.date).num_days().abs() > 1 {
                continue;
            }
            let (e_start, e_end) = shift_interval(existing);
            // Two shifts overlap if one starts before the other ends and vice versa
            if start < e_end && e_start < end {
                return true;
            }
        }
    }
    false
}

// ─── Multi-role coverage helpers ─────────────────────────────

/// Remaining unmet minimum per required role, after accounting for employees
/// already assigned to the shift who hold that role. Roles already satisfied are
/// omitted.
fn role_deficits(
    shift: &Shift,
    state: &SchedulerState,
    emp_map: &HashMap<i64, &Employee>,
) -> HashMap<String, u32> {
    let assigned = state.shift_assignments.get(&shift.id);
    let mut deficits = HashMap::new();
    for req in &shift.role_requirements {
        let covered = assigned
            .map(|ids| {
                ids.iter()
                    .filter(|id| emp_map.get(id).is_some_and(|e| e.has_role(&req.role)))
                    .count() as u32
            })
            .unwrap_or(0);
        let deficit = req.min_count.saturating_sub(covered);
        if deficit > 0 {
            deficits.insert(req.role.clone(), deficit);
        }
    }
    deficits
}

/// Best-scoring eligible employee for a shift, optionally restricted to holders
/// of `role`. Uses the same score + deterministic tiebreak as the greedy fill.
#[allow(clippy::too_many_arguments)]
fn best_candidate<'a>(
    employees: &'a [Employee],
    shift: &Shift,
    state: &SchedulerState,
    shift_map: &HashMap<i64, &Shift>,
    avail_override_map: &HashMap<(i64, NaiveDate), &EmployeeAvailabilityOverride>,
    week_start: &NaiveDate,
    role: Option<&str>,
) -> Option<&'a Employee> {
    let mut candidates: Vec<(&Employee, (u8, i32, i32), u64)> = employees
        .iter()
        .filter(|e| role.is_none_or(|r| e.has_role(r)))
        .filter(|e| is_eligible(e, shift, state, shift_map, avail_override_map))
        .map(|e| {
            let weekly = state.employee_weekly_hours(e.id);
            let daily = state.employee_daily_hours(e.id, shift.date);
            let day_avail = avail_override_map
                .get(&(e.id, shift.date))
                .map(|o| &o.availability);
            let score = scoring::score_employee(e, shift, weekly, daily, day_avail);
            let tb = tiebreak::tiebreak_key(e.id, week_start);
            (e, score, tb)
        })
        .collect();
    // Best score first, then tiebreak (higher hash wins).
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then(b.2.cmp(&a.2)));
    candidates.first().map(|(e, _, _)| *e)
}

/// Construct a shortfall warning. `role` is the role that fell short, or `None`
/// for an overall headcount shortfall.
fn role_warning(shift: &Shift, needed: u32, filled: u32, role: Option<String>) -> ShortfallWarning {
    ShortfallWarning {
        shift_id: shift.id,
        needed,
        filled,
        weekday: shift.weekday().to_string(),
        start_time: shift.start_time.format("%H:%M").to_string(),
        end_time: shift.end_time.format("%H:%M").to_string(),
        required_role: role.clone().unwrap_or_else(|| shift.required_role.clone()),
        role,
    }
}

// ─── Pure scheduling core ────────────────────────────────────

/// Pure function implementing the two-pass scheduling algorithm.
/// Takes all data as arguments — no DB access, easy to test.
///
/// `avail_overrides` — date-specific availability overrides for employees.
/// When a shift falls on a date that has an override for a given employee,
/// the override's `DayAvailability` is used instead of the weekly availability map.
pub fn schedule_pure(
    shifts: &[Shift],
    employees: &[Employee],
    existing_assignments: &[Assignment],
    avail_overrides: &[EmployeeAvailabilityOverride],
    rota_id: i64,
    week_start: NaiveDate,
) -> ScheduleResult {
    let shift_map: HashMap<i64, &Shift> = shifts.iter().map(|s| (s.id, s)).collect();
    let emp_map: HashMap<i64, &Employee> = employees.iter().map(|e| (e.id, e)).collect();
    // Build a (employee_id, date) → override lookup for O(1) access during scheduling.
    let avail_override_map: HashMap<(i64, NaiveDate), &EmployeeAvailabilityOverride> =
        avail_overrides
            .iter()
            .map(|o| ((o.employee_id, o.date), o))
            .collect();
    let mut state = SchedulerState::new();
    let mut warnings = Vec::new();

    // ── Pass 1: Pre-assignments (overrides) ──────────────────
    for a in existing_assignments {
        if a.status != AssignmentStatus::Overridden {
            continue;
        }
        if let Some(shift) = shift_map.get(&a.shift_id) {
            // Duplicate Overridden rows for the same (employee, shift) must not
            // double-count hours or emit a second assignment.
            if state.is_assigned_to_shift(a.employee_id, a.shift_id) {
                continue;
            }
            let emp = emp_map.get(&a.employee_id);
            let name = emp.map(|e| e.display_name());
            let wage = emp.and_then(|e| e.hourly_wage);
            state.record_assignment(
                a.employee_id,
                name,
                wage,
                shift,
                rota_id,
                AssignmentStatus::Overridden,
            );
        }
    }

    // ── Pass 2: Greedy assignment ────────────────────────────

    // Compute difficulty and sort shifts hardest-to-fill first. For a
    // role-constrained shift, difficulty is the scarcest required role's
    // eligible-holder count; otherwise the total eligible count.
    let mut shift_order: Vec<&Shift> = shifts
        .iter()
        .filter(|s| state.slots_filled(s.id) < s.max_employees)
        .collect();

    let difficulty: HashMap<i64, usize> = shift_order
        .iter()
        .map(|s| {
            let eligible_total = employees
                .iter()
                .filter(|e| is_eligible(e, s, &state, &shift_map, &avail_override_map))
                .count();
            let diff = if s.has_required_role() {
                s.role_requirements
                    .iter()
                    .map(|req| {
                        employees
                            .iter()
                            .filter(|e| {
                                e.has_role(&req.role)
                                    && is_eligible(e, s, &state, &shift_map, &avail_override_map)
                            })
                            .count()
                    })
                    .min()
                    .unwrap_or(eligible_total)
            } else {
                eligible_total
            };
            (s.id, diff)
        })
        .collect();

    shift_order.sort_by(|a, b| {
        let diff_a = difficulty.get(&a.id).copied().unwrap_or(0);
        let diff_b = difficulty.get(&b.id).copied().unwrap_or(0);
        diff_a
            .cmp(&diff_b) // fewest eligible first
            .then(b.effective_min().cmp(&a.effective_min())) // larger needs first
            .then(a.date.cmp(&b.date)) // earlier date first
            .then(a.start_time.cmp(&b.start_time)) // earlier time first
    });

    for shift in &shift_order {
        // ── Stage 1: cover each role minimum (shared coverage) ──
        // One employee who holds several required roles reduces several deficits
        // at once. Always pick the role with the largest remaining deficit.
        let mut deficits = role_deficits(shift, &state, &emp_map);
        while !deficits.is_empty() && state.slots_filled(shift.id) < shift.max_employees {
            // Largest deficit first; break ties by role name for determinism.
            let role = deficits
                .iter()
                .max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0)))
                .map(|(r, _)| r.clone())
                .unwrap();

            match best_candidate(
                employees,
                shift,
                &state,
                &shift_map,
                &avail_override_map,
                &week_start,
                Some(&role),
            ) {
                Some(emp) => {
                    state.record_assignment(
                        emp.id,
                        Some(emp.display_name()),
                        emp.hourly_wage,
                        shift,
                        rota_id,
                        AssignmentStatus::Proposed,
                    );
                    // Covers one unit of every still-needed role this employee holds.
                    deficits.retain(|r, count| {
                        if emp.has_role(r) {
                            *count -= 1;
                            *count > 0
                        } else {
                            true
                        }
                    });
                }
                // No eligible holder for this role — stop trying to cover it.
                // The final per-role shortfall pass reports it.
                None => {
                    deficits.remove(&role);
                }
            }
        }

        // Reserve slots for any role minimum that couldn't be covered, so stage
        // 2 doesn't fill a role's slot with a non-qualifying employee (matching
        // the old hard role gate). With shared coverage, the minimum number of
        // slots to keep open for the remaining deficits is the largest deficit.
        let unmet = role_deficits(shift, &state, &emp_map);
        let reserved = unmet.values().copied().max().unwrap_or(0);
        let stage2_cap = shift.max_employees.saturating_sub(reserved);

        // ── Stage 2: fill non-reserved slots with any eligible employee ──
        while state.slots_filled(shift.id) < stage2_cap {
            let Some(emp) = best_candidate(
                employees,
                shift,
                &state,
                &shift_map,
                &avail_override_map,
                &week_start,
                None,
            ) else {
                break;
            };
            state.record_assignment(
                emp.id,
                Some(emp.display_name()),
                emp.hourly_wage,
                shift,
                rota_id,
                AssignmentStatus::Proposed,
            );
        }

        // ── Shortfall warnings ──
        // Per-role: any role minimum still unmet (these slots were left open).
        for req in &shift.role_requirements {
            if let Some(missing) = unmet.get(&req.role) {
                warnings.push(role_warning(
                    shift,
                    req.min_count,
                    req.min_count - missing,
                    Some(req.role.clone()),
                ));
            }
        }
        // Overall headcount: only the bodies demanded beyond the role-derived
        // floor (avoids double-warning the legacy single-role case).
        let filled = state.slots_filled(shift.id);
        let warn_headcount = if shift.has_required_role() {
            shift.min_employees > shift.derived_min() && filled < shift.min_employees
        } else {
            filled < shift.min_employees
        };
        if warn_headcount {
            warnings.push(role_warning(shift, shift.min_employees, filled, None));
        }
    }

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

    let shifts = queries::list_shifts_for_rota(pool, rota_id).await?;
    let employees = queries::list_employees(pool).await?;
    let existing = queries::list_assignments_for_rota(pool, rota_id).await?;
    let week_end = rota.week_start + chrono::Duration::days(7);
    let avail_overrides =
        queries::list_employee_availability_overrides_in_range(pool, rota.week_start, week_end)
            .await?;

    let result = schedule_pure(
        &shifts,
        &employees,
        &existing,
        &avail_overrides,
        rota_id,
        rota.week_start,
    );

    // Persist only newly generated assignments (not the existing overrides)
    for assignment in &result.assignments {
        if assignment.status == AssignmentStatus::Proposed {
            queries::insert_assignment(pool, assignment).await?;
        }
    }

    Ok(result)
}
