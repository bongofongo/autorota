//! Deterministic synthetic corpus generator for performance benchmarks.
//!
//! Builds a realistic-shaped rota: ~60% baristas / ~25% leads / ~15% kitchen,
//! shifts fanned across all seven weekdays, mixed availability (Yes/Maybe/No),
//! ~5% of assignments pre-pinned as overridden so Pass 1 of the scheduler has
//! work to do.
//!
//! The generator is seeded via `ChaCha8Rng` so the same `(employees, weeks, seed)`
//! tuple always yields byte-identical output. This keeps criterion runs and
//! XCUITest perf runs comparable across machines and CI runs.
//!
//! Use `generate_corpus(...)` for pure benches (scheduler, render). Use
//! `seed_corpus_into_pool(...)` to populate a real SqlitePool for the
//! `autorota_seed_perf_corpus` FFI hook.

use chrono::{Datelike, Duration, NaiveDate, NaiveTime, Weekday};
use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha8Rng;
use sqlx::SqlitePool;

use crate::db::queries;
use crate::models::assignment::{Assignment, AssignmentStatus};
use crate::models::availability::{Availability, AvailabilityState};
use crate::models::employee::Employee;
use crate::models::overrides::{DayAvailability, EmployeeAvailabilityOverride, OverrideSource};
use crate::models::rota::Rota;
use crate::models::shift::{RoleRequirement, Shift, ShiftTemplate};

pub const ROLES: &[&str] = &["barista", "lead", "kitchen"];

#[derive(Debug, Clone, Copy)]
pub struct CorpusSize {
    pub employees: usize,
    pub weeks: usize,
}

pub const SMALL: CorpusSize = CorpusSize {
    employees: 50,
    weeks: 1,
};
pub const MEDIUM: CorpusSize = CorpusSize {
    employees: 200,
    weeks: 1,
};
pub const LARGE: CorpusSize = CorpusSize {
    employees: 500,
    weeks: 1,
};

/// Multi-week sizes. Fix employees at 200 and scale the week (shift) axis —
/// the dimension that actually grows scheduler workload. `weeks==1` output is
/// byte-identical to `MEDIUM`, so these only *append* later weeks.
pub const WEEKS_4: CorpusSize = CorpusSize {
    employees: 200,
    weeks: 4,
};
pub const WEEKS_12: CorpusSize = CorpusSize {
    employees: 200,
    weeks: 12,
};

/// Default seed used by benches and the FFI corpus hook so results compare
/// cleanly across runs. Chosen arbitrarily; the value itself doesn't matter
/// as long as it's stable.
pub const DEFAULT_SEED: u64 = 0x0000_00A0_70C0_FFEE_u64;

/// All the data needed to drive the scheduler / renderer for one synthetic week.
#[derive(Debug, Clone)]
pub struct Corpus {
    pub rota: Rota,
    pub roles: Vec<String>,
    pub employees: Vec<Employee>,
    pub templates: Vec<ShiftTemplate>,
    pub shifts: Vec<Shift>,
    pub avail_overrides: Vec<EmployeeAvailabilityOverride>,
    pub existing_assignments: Vec<Assignment>,
    pub week_start: NaiveDate,
}

/// Knobs for corpus generation beyond the size/seed triple.
#[derive(Debug, Clone, Copy)]
pub struct CorpusConfig {
    pub employees: usize,
    pub weeks: usize,
    pub seed: u64,
    /// Also generate multi-role, wildcard, and overnight shift templates.
    /// Off for benches: their corpus must stay byte-identical so criterion and
    /// XCUITest perf baselines remain comparable across runs.
    pub enriched_shifts: bool,
}

/// Generate a deterministic corpus.
///
/// `weeks` fans the templates across `weeks` consecutive weeks. `weeks==1` is
/// byte-identical to the legacy single-week output; larger counts append later
/// weeks so multi-week baselines stay comparable.
pub fn generate_corpus(employees: usize, weeks: usize, seed: u64) -> Corpus {
    generate_corpus_with(CorpusConfig {
        employees,
        weeks,
        seed,
        enriched_shifts: false,
    })
}

/// Generate a corpus with explicit config. The legacy `enriched_shifts: false`
/// path is byte-identical to `generate_corpus`.
pub fn generate_corpus_with(cfg: CorpusConfig) -> Corpus {
    let CorpusConfig {
        employees,
        weeks,
        seed,
        ..
    } = cfg;
    let mut rng = ChaCha8Rng::seed_from_u64(seed);
    let week_start = NaiveDate::from_ymd_opt(2026, 4, 20).unwrap(); // Monday
    let rota_id: i64 = 1;

    let mut templates = build_templates();
    if cfg.enriched_shifts {
        templates.extend(enriched_templates());
    }
    let templates = templates;
    let employees_v = build_employees(&mut rng, employees);
    let shifts = build_shifts(&mut rng, &templates, week_start, weeks, rota_id);
    let avail_overrides = build_avail_overrides(&mut rng, &employees_v, week_start);
    let existing_assignments = build_pinned_assignments(&mut rng, &employees_v, &shifts, rota_id);

    let rota = Rota {
        id: rota_id,
        week_start,
        assignments: existing_assignments.clone(),
    };

    Corpus {
        rota,
        roles: ROLES.iter().map(|s| s.to_string()).collect(),
        employees: employees_v,
        templates,
        shifts,
        avail_overrides,
        existing_assignments,
        week_start,
    }
}

/// Insert a generated corpus into a live SQLite pool.
///
/// Used by the `autorota_seed_perf_corpus` FFI hook so XCUITest can measure
/// real cold-launch + week-render timings against a known-shaped dataset.
/// Does not return new IDs — caller is responsible for re-querying if needed.
pub async fn seed_corpus_into_pool(pool: &SqlitePool, c: &Corpus) -> Result<(), sqlx::Error> {
    for role in &c.roles {
        let _ = queries::insert_role(pool, role).await?;
    }
    let mut emp_id_map: std::collections::HashMap<i64, i64> =
        std::collections::HashMap::with_capacity(c.employees.len());
    for emp in &c.employees {
        let new_id = queries::insert_employee(pool, emp).await?;
        emp_id_map.insert(emp.id, new_id);
    }
    let mut tmpl_id_map: std::collections::HashMap<i64, i64> =
        std::collections::HashMap::with_capacity(c.templates.len());
    for tmpl in &c.templates {
        let new_id = queries::insert_shift_template(pool, tmpl).await?;
        tmpl_id_map.insert(tmpl.id, new_id);
    }
    let new_rota_id = queries::insert_rota(pool, c.week_start).await?;

    let mut shift_id_map: std::collections::HashMap<i64, i64> =
        std::collections::HashMap::with_capacity(c.shifts.len());
    for shift in &c.shifts {
        let mut s = shift.clone();
        s.rota_id = new_rota_id;
        s.template_id = s.template_id.and_then(|id| tmpl_id_map.get(&id).copied());
        let new_id = queries::insert_shift(pool, &s).await?;
        shift_id_map.insert(shift.id, new_id);
    }
    for a in &c.existing_assignments {
        let Some(&new_shift_id) = shift_id_map.get(&a.shift_id) else {
            continue;
        };
        let Some(&new_emp_id) = emp_id_map.get(&a.employee_id) else {
            continue;
        };
        let mut copy = a.clone();
        copy.rota_id = new_rota_id;
        copy.shift_id = new_shift_id;
        copy.employee_id = new_emp_id;
        let _ = queries::insert_assignment(pool, &copy).await?;
    }
    for ovr in &c.avail_overrides {
        let Some(&new_emp_id) = emp_id_map.get(&ovr.employee_id) else {
            continue;
        };
        let mut copy = ovr.clone();
        copy.employee_id = new_emp_id;
        let _ = queries::upsert_employee_availability_override(pool, &copy).await?;
    }
    Ok(())
}

// ── Internals ────────────────────────────────────────────────

fn build_templates() -> Vec<ShiftTemplate> {
    let mf = vec![
        Weekday::Mon,
        Weekday::Tue,
        Weekday::Wed,
        Weekday::Thu,
        Weekday::Fri,
    ];
    let weekend = vec![Weekday::Sat, Weekday::Sun];
    let all = vec![
        Weekday::Mon,
        Weekday::Tue,
        Weekday::Wed,
        Weekday::Thu,
        Weekday::Fri,
        Weekday::Sat,
        Weekday::Sun,
    ];

    let templates: Vec<ShiftTemplate> = vec![
        ShiftTemplate {
            id: 1,
            name: "Morning open".to_string(),
            weekdays: all.clone(),
            start_time: NaiveTime::from_hms_opt(6, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(11, 0, 0).unwrap(),
            required_role: "barista".to_string(),
            min_employees: 2,
            max_employees: 3,
            role_requirements: Vec::new(),
            deleted: false,
        },
        ShiftTemplate {
            id: 2,
            name: "Lunch peak".to_string(),
            weekdays: mf.clone(),
            start_time: NaiveTime::from_hms_opt(11, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(15, 0, 0).unwrap(),
            required_role: "barista".to_string(),
            min_employees: 3,
            max_employees: 4,
            role_requirements: Vec::new(),
            deleted: false,
        },
        ShiftTemplate {
            id: 3,
            name: "Afternoon".to_string(),
            weekdays: all.clone(),
            start_time: NaiveTime::from_hms_opt(14, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(19, 0, 0).unwrap(),
            required_role: "barista".to_string(),
            min_employees: 2,
            max_employees: 3,
            role_requirements: Vec::new(),
            deleted: false,
        },
        ShiftTemplate {
            id: 4,
            name: "Lead cover".to_string(),
            weekdays: all.clone(),
            start_time: NaiveTime::from_hms_opt(8, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(16, 0, 0).unwrap(),
            required_role: "lead".to_string(),
            min_employees: 1,
            max_employees: 1,
            role_requirements: Vec::new(),
            deleted: false,
        },
        ShiftTemplate {
            id: 5,
            name: "Kitchen prep".to_string(),
            weekdays: mf.clone(),
            start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(13, 0, 0).unwrap(),
            required_role: "kitchen".to_string(),
            min_employees: 1,
            max_employees: 2,
            role_requirements: Vec::new(),
            deleted: false,
        },
        ShiftTemplate {
            id: 6,
            name: "Weekend brunch".to_string(),
            weekdays: weekend,
            start_time: NaiveTime::from_hms_opt(9, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(14, 0, 0).unwrap(),
            required_role: "barista".to_string(),
            min_employees: 3,
            max_employees: 4,
            role_requirements: Vec::new(),
            deleted: false,
        },
    ];

    // Mirror the migration backfill: derive one role requirement from each
    // template's legacy single role so corpus scheduler tests keep their
    // "needs N of role" behavior.
    templates
        .into_iter()
        .map(|mut t| {
            if t.role_requirements.is_empty() && !t.required_role.is_empty() {
                t.role_requirements = vec![RoleRequirement {
                    role: t.required_role.clone(),
                    min_count: t.min_employees,
                }];
            }
            t
        })
        .collect()
}

/// Extra templates for `CorpusConfig::enriched_shifts`: a genuine multi-role
/// shift (two-stage fill), a wildcard shift, and an overnight shift.
fn enriched_templates() -> Vec<ShiftTemplate> {
    let all = vec![
        Weekday::Mon,
        Weekday::Tue,
        Weekday::Wed,
        Weekday::Thu,
        Weekday::Fri,
        Weekday::Sat,
        Weekday::Sun,
    ];
    vec![
        ShiftTemplate {
            id: 7,
            name: "Full service".to_string(),
            weekdays: all.clone(),
            start_time: NaiveTime::from_hms_opt(10, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(16, 0, 0).unwrap(),
            required_role: "barista".to_string(),
            min_employees: 3,
            max_employees: 5,
            role_requirements: vec![
                RoleRequirement {
                    role: "barista".to_string(),
                    min_count: 2,
                },
                RoleRequirement {
                    role: "kitchen".to_string(),
                    min_count: 1,
                },
            ],
            deleted: false,
        },
        ShiftTemplate {
            id: 8,
            name: "Floater".to_string(),
            weekdays: all.clone(),
            start_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(17, 0, 0).unwrap(),
            required_role: String::new(),
            min_employees: 1,
            max_employees: 2,
            role_requirements: Vec::new(),
            deleted: false,
        },
        ShiftTemplate {
            id: 9,
            name: "Night clean".to_string(),
            weekdays: all,
            start_time: NaiveTime::from_hms_opt(22, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(2, 0, 0).unwrap(),
            required_role: String::new(),
            min_employees: 1,
            max_employees: 1,
            role_requirements: Vec::new(),
            deleted: false,
        },
    ]
}

fn build_employees(rng: &mut ChaCha8Rng, count: usize) -> Vec<Employee> {
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let id = (i as i64) + 1;
        // Role distribution: 60% barista, 25% lead, 15% kitchen.
        let r: f32 = rng.r#gen();
        let primary_role = if r < 0.60 {
            "barista"
        } else if r < 0.85 {
            "lead"
        } else {
            "kitchen"
        };
        // ~30% of leads also hold barista; ~20% of kitchen also hold barista.
        let mut roles = vec![primary_role.to_string()];
        if primary_role == "lead" && rng.r#gen::<f32>() < 0.30 {
            roles.push("barista".to_string());
        }
        if primary_role == "kitchen" && rng.r#gen::<f32>() < 0.20 {
            roles.push("barista".to_string());
        }

        let target: f32 = *[20.0_f32, 25.0, 30.0, 35.0, 40.0].choose(rng);
        let availability = build_random_availability(rng);

        out.push(Employee {
            id,
            first_name: format!("Emp{id:04}"),
            last_name: "Synthetic".to_string(),
            nickname: None,
            roles,
            start_date: NaiveDate::from_ymd_opt(2025, 1, 1).unwrap(),
            target_weekly_hours: target,
            weekly_hours_deviation: 6.0,
            max_daily_hours: 10.0,
            notes: None,
            bank_details: None,
            phone: None,
            email: None,
            preferred_contact: None,
            hourly_wage: Some(15.0 + (id % 7) as f32),
            wage_currency: Some("gbp".to_string()),
            default_availability: availability.clone(),
            availability,
            deleted: false,
        });
    }
    out
}

fn build_random_availability(rng: &mut ChaCha8Rng) -> Availability {
    let mut a = Availability::default();
    let weekdays = [
        Weekday::Mon,
        Weekday::Tue,
        Weekday::Wed,
        Weekday::Thu,
        Weekday::Fri,
        Weekday::Sat,
        Weekday::Sun,
    ];
    for wd in weekdays {
        for h in 6..22u8 {
            let r: f32 = rng.r#gen();
            let state = if r < 0.55 {
                AvailabilityState::Yes
            } else if r < 0.80 {
                AvailabilityState::Maybe
            } else {
                AvailabilityState::No
            };
            a.set(wd, h, state);
        }
    }
    a
}

fn build_shifts(
    _rng: &mut ChaCha8Rng,
    templates: &[ShiftTemplate],
    week_start: NaiveDate,
    weeks: usize,
    rota_id: i64,
) -> Vec<Shift> {
    let weeks = weeks.max(1);
    let mut out = Vec::new();
    let mut next_id: i64 = 1;
    // Ordering (template → week → weekday) keeps `weeks == 1` byte-identical to
    // the legacy single-week output; extra weeks only append with fresh ids.
    for tmpl in templates {
        for w in 0..weeks {
            for d in 0..7 {
                let date = week_start + Duration::days((w * 7) as i64 + d);
                if !tmpl.weekdays.contains(&date.weekday()) {
                    continue;
                }
                out.push(Shift {
                    id: next_id,
                    template_id: Some(tmpl.id),
                    rota_id,
                    date,
                    start_time: tmpl.start_time,
                    end_time: tmpl.end_time,
                    required_role: tmpl.required_role.clone(),
                    min_employees: tmpl.min_employees,
                    max_employees: tmpl.max_employees,
                    role_requirements: tmpl.role_requirements.clone(),
                });
                next_id += 1;
            }
        }
    }
    out
}

fn build_avail_overrides(
    rng: &mut ChaCha8Rng,
    employees: &[Employee],
    week_start: NaiveDate,
) -> Vec<EmployeeAvailabilityOverride> {
    let mut out = Vec::new();
    let mut next_id: i64 = 1;
    for emp in employees {
        // ~10% of employees get one override somewhere in the week.
        if rng.r#gen::<f32>() > 0.10 {
            continue;
        }
        let day_offset = rng.gen_range(0..7i64);
        let date = week_start + Duration::days(day_offset);
        let mut da = DayAvailability::default();
        for h in 6..22u8 {
            let r: f32 = rng.r#gen();
            let state = if r < 0.30 {
                AvailabilityState::No
            } else if r < 0.65 {
                AvailabilityState::Maybe
            } else {
                AvailabilityState::Yes
            };
            da.set(h, state);
        }
        out.push(EmployeeAvailabilityOverride {
            id: next_id,
            employee_id: emp.id,
            date,
            availability: da,
            notes: None,
            source: OverrideSource::Exception,
        });
        next_id += 1;
    }
    out
}

fn build_pinned_assignments(
    rng: &mut ChaCha8Rng,
    employees: &[Employee],
    shifts: &[Shift],
    rota_id: i64,
) -> Vec<Assignment> {
    let mut out = Vec::new();
    let mut next_id: i64 = 1;
    for shift in shifts {
        // ~5% chance of one pre-pinned slot per shift (gives Pass 1 work to do).
        if rng.r#gen::<f32>() > 0.05 {
            continue;
        }
        // Pick an employee who at least holds the role.
        let candidates: Vec<&Employee> = employees
            .iter()
            .filter(|e| !shift.has_required_role() || e.has_role(&shift.required_role))
            .collect();
        if candidates.is_empty() {
            continue;
        }
        let pick = candidates[rng.gen_range(0..candidates.len())];
        out.push(Assignment {
            id: next_id,
            rota_id,
            shift_id: shift.id,
            employee_id: pick.id,
            status: AssignmentStatus::Overridden,
            employee_name: Some(pick.display_name()),
            hourly_wage: pick.hourly_wage,
        });
        next_id += 1;
    }
    out
}

// Tiny helper: rand 0.8 doesn't expose a stable choose on &[T]; gen_range works fine.
trait ChooseExt<T: Copy> {
    fn choose(&self, rng: &mut ChaCha8Rng) -> &T;
}
impl<T: Copy> ChooseExt<T> for [T] {
    fn choose(&self, rng: &mut ChaCha8Rng) -> &T {
        &self[rng.gen_range(0..self.len())]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_for_same_seed() {
        let a = generate_corpus(50, 1, 42);
        let b = generate_corpus(50, 1, 42);
        assert_eq!(a.employees.len(), b.employees.len());
        assert_eq!(a.shifts.len(), b.shifts.len());
        assert_eq!(a.avail_overrides.len(), b.avail_overrides.len());
        assert_eq!(a.existing_assignments.len(), b.existing_assignments.len());
        for (ea, eb) in a.employees.iter().zip(&b.employees) {
            assert_eq!(ea.target_weekly_hours, eb.target_weekly_hours);
            assert_eq!(ea.roles, eb.roles);
        }
    }

    #[test]
    fn different_seeds_diverge() {
        let a = generate_corpus(100, 1, 1);
        let b = generate_corpus(100, 1, 2);
        let same = a
            .employees
            .iter()
            .zip(&b.employees)
            .all(|(x, y)| x.target_weekly_hours == y.target_weekly_hours);
        assert!(!same, "different seeds should diverge");
    }

    #[test]
    fn sizes_scale() {
        let small = generate_corpus(50, 1, DEFAULT_SEED);
        let large = generate_corpus(500, 1, DEFAULT_SEED);
        assert_eq!(small.employees.len(), 50);
        assert_eq!(large.employees.len(), 500);
        // Same templates produce same shift count regardless of employee count.
        assert_eq!(small.shifts.len(), large.shifts.len());
        assert!(!small.shifts.is_empty());
    }

    #[test]
    fn role_distribution_within_tolerance() {
        let c = generate_corpus(1000, 1, DEFAULT_SEED);
        let baristas = c
            .employees
            .iter()
            .filter(|e| e.roles[0] == "barista")
            .count();
        // 60% target ± 10pp tolerance.
        assert!(
            (500..=700).contains(&baristas),
            "barista count {baristas} outside tolerance"
        );
    }
}
