//! Corpus-driven invariant suite: runs `schedule_pure` over many seeded,
//! realistic weeks and asserts global properties that must hold for every
//! output, regardless of input shape.
//!
//! Pinned (Overridden) corpus assignments deliberately bypass eligibility,
//! so hour/overlap invariants are asserted for the scheduler's own choices:
//! a Proposed assignment must never break a cap or overlap anything, and an
//! employee without pins must be fully within budget.

mod helpers;

use std::collections::{HashMap, HashSet};

use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::AvailabilityState;
use autorota_core::models::shift::Shift;
use autorota_core::scheduler::{ScheduleResult, schedule_pure};
use chrono::{Duration, NaiveDate, NaiveDateTime};

use helpers::corpus::{Corpus, CorpusConfig, generate_corpus_with};

const SEEDS: [u64; 10] = [1, 2, 3, 5, 8, 13, 21, 42, 999, 0xC0FFEE];
const SIZES: [usize; 2] = [50, 200];

fn all_configs() -> Vec<CorpusConfig> {
    let mut out = Vec::new();
    for &employees in &SIZES {
        for &seed in &SEEDS {
            for enriched_shifts in [false, true] {
                out.push(CorpusConfig {
                    employees,
                    weeks: 1,
                    seed,
                    enriched_shifts,
                });
            }
        }
    }
    out
}

fn run(c: &Corpus) -> ScheduleResult {
    schedule_pure(
        &c.shifts,
        &c.employees,
        &c.existing_assignments,
        &c.avail_overrides,
        c.rota.id,
        c.week_start,
    )
}

/// Concrete `[start, end)` interval; overnight shifts end the next day.
fn interval(shift: &Shift) -> (NaiveDateTime, NaiveDateTime) {
    let start = shift.date.and_time(shift.start_time);
    let end_date = if shift.end_time >= shift.start_time {
        shift.date
    } else {
        shift.date + Duration::days(1)
    };
    (start, end_date.and_time(shift.end_time))
}

/// Hours per calendar day, split at midnight for overnight shifts.
fn daily_portions(shift: &Shift) -> Vec<(NaiveDate, f32)> {
    if shift.end_time >= shift.start_time {
        vec![(shift.date, shift.duration_hours())]
    } else {
        let until_midnight = 24.0
            - shift
                .start_time
                .signed_duration_since(chrono::NaiveTime::MIN)
                .num_seconds() as f32
                / 3600.0;
        vec![
            (shift.date, until_midnight),
            (
                shift.date + Duration::days(1),
                shift.duration_hours() - until_midnight,
            ),
        ]
    }
}

fn ctx(cfg: &CorpusConfig) -> String {
    format!(
        "seed={} employees={} enriched={}",
        cfg.seed, cfg.employees, cfg.enriched_shifts
    )
}

#[test]
fn no_duplicate_employee_shift_pairs() {
    for cfg in all_configs() {
        let c = generate_corpus_with(cfg);
        let result = run(&c);
        let mut seen = HashSet::new();
        for a in &result.assignments {
            assert!(
                seen.insert((a.employee_id, a.shift_id)),
                "duplicate assignment for employee {} on shift {} [{}]",
                a.employee_id,
                a.shift_id,
                ctx(&cfg)
            );
        }
    }
}

#[test]
fn shift_capacity_never_exceeded() {
    for cfg in all_configs() {
        let c = generate_corpus_with(cfg);
        let result = run(&c);
        let shift_map: HashMap<i64, &Shift> = c.shifts.iter().map(|s| (s.id, s)).collect();
        let mut counts: HashMap<i64, u32> = HashMap::new();
        for a in &result.assignments {
            *counts.entry(a.shift_id).or_default() += 1;
        }
        for (shift_id, count) in counts {
            let max = shift_map[&shift_id].max_employees;
            assert!(
                count <= max,
                "shift {shift_id} has {count} assignments, max {max} [{}]",
                ctx(&cfg)
            );
        }
    }
}

#[test]
fn hour_caps_hold_for_scheduler_choices() {
    for cfg in all_configs() {
        let c = generate_corpus_with(cfg);
        let result = run(&c);
        let shift_map: HashMap<i64, &Shift> = c.shifts.iter().map(|s| (s.id, s)).collect();
        let emp_map: HashMap<i64, _> = c.employees.iter().map(|e| (e.id, e)).collect();

        let mut weekly: HashMap<i64, f32> = HashMap::new();
        let mut daily: HashMap<(i64, NaiveDate), f32> = HashMap::new();
        let mut has_pin: HashSet<i64> = HashSet::new();
        for a in &result.assignments {
            let shift = shift_map[&a.shift_id];
            *weekly.entry(a.employee_id).or_default() += shift.duration_hours();
            for (day, hours) in daily_portions(shift) {
                *daily.entry((a.employee_id, day)).or_default() += hours;
            }
            if a.status == AssignmentStatus::Overridden {
                has_pin.insert(a.employee_id);
            }
        }

        // Pins bypass eligibility, so caps are only guaranteed for employees
        // whose week the scheduler built entirely by itself.
        const EPS: f32 = 1e-4;
        for (&emp_id, &hours) in &weekly {
            if has_pin.contains(&emp_id) {
                continue;
            }
            let Some(emp) = emp_map.get(&emp_id) else {
                continue;
            };
            assert!(
                hours <= emp.max_weekly_hours() + EPS,
                "employee {emp_id} at {hours}h > weekly cap {} [{}]",
                emp.max_weekly_hours(),
                ctx(&cfg)
            );
        }
        for (&(emp_id, day), &hours) in &daily {
            if has_pin.contains(&emp_id) {
                continue;
            }
            let Some(emp) = emp_map.get(&emp_id) else {
                continue;
            };
            assert!(
                hours <= emp.max_daily_hours + EPS,
                "employee {emp_id} at {hours}h on {day} > daily cap {} [{}]",
                emp.max_daily_hours,
                ctx(&cfg)
            );
        }
    }
}

#[test]
fn proposed_assignments_never_overlap_anything() {
    for cfg in all_configs() {
        let c = generate_corpus_with(cfg);
        let result = run(&c);
        let shift_map: HashMap<i64, &Shift> = c.shifts.iter().map(|s| (s.id, s)).collect();

        let mut by_emp: HashMap<i64, Vec<&Assignment>> = HashMap::new();
        for a in &result.assignments {
            by_emp.entry(a.employee_id).or_default().push(a);
        }
        for (emp_id, assignments) in by_emp {
            for (i, a) in assignments.iter().enumerate() {
                for b in &assignments[i + 1..] {
                    // Pin-vs-pin overlaps can come straight from hostile input;
                    // the scheduler only guarantees its own picks don't collide.
                    if a.status == AssignmentStatus::Overridden
                        && b.status == AssignmentStatus::Overridden
                    {
                        continue;
                    }
                    let (s1, e1) = interval(shift_map[&a.shift_id]);
                    let (s2, e2) = interval(shift_map[&b.shift_id]);
                    assert!(
                        !(s1 < e2 && s2 < e1),
                        "employee {emp_id} double-booked: shifts {} and {} overlap [{}]",
                        a.shift_id,
                        b.shift_id,
                        ctx(&cfg)
                    );
                }
            }
        }
    }
}

#[test]
fn proposed_assignments_respect_no_availability() {
    for cfg in all_configs() {
        let c = generate_corpus_with(cfg);
        let result = run(&c);
        let shift_map: HashMap<i64, &Shift> = c.shifts.iter().map(|s| (s.id, s)).collect();
        let emp_map: HashMap<i64, _> = c.employees.iter().map(|e| (e.id, e)).collect();
        let override_map: HashMap<(i64, NaiveDate), _> = c
            .avail_overrides
            .iter()
            .map(|o| ((o.employee_id, o.date), o))
            .collect();

        for a in &result.assignments {
            if a.status != AssignmentStatus::Proposed {
                continue;
            }
            let shift = shift_map[&a.shift_id];
            let emp = emp_map[&a.employee_id];
            let avail = match override_map.get(&(a.employee_id, shift.date)) {
                Some(ovr) => ovr
                    .availability
                    .for_window(shift.start_hour(), shift.end_hour()),
                None => emp.availability.for_window(
                    shift.weekday(),
                    shift.start_hour(),
                    shift.end_hour(),
                ),
            };
            assert_ne!(
                avail,
                AvailabilityState::No,
                "employee {} proposed on shift {} despite No availability [{}]",
                a.employee_id,
                a.shift_id,
                ctx(&cfg)
            );
        }
    }
}

#[test]
fn unmet_minimums_always_carry_a_warning() {
    for cfg in all_configs() {
        let c = generate_corpus_with(cfg);
        let result = run(&c);
        let emp_map: HashMap<i64, _> = c.employees.iter().map(|e| (e.id, e)).collect();

        let mut by_shift: HashMap<i64, Vec<&Assignment>> = HashMap::new();
        for a in &result.assignments {
            by_shift.entry(a.shift_id).or_default().push(a);
        }

        for shift in &c.shifts {
            let assigned = by_shift.get(&shift.id).map(Vec::as_slice).unwrap_or(&[]);
            // Per-role minimums: unmet → warning naming that role.
            for req in &shift.role_requirements {
                let holders = assigned
                    .iter()
                    .filter(|a| {
                        emp_map
                            .get(&a.employee_id)
                            .is_some_and(|e| e.has_role(&req.role))
                    })
                    .count() as u32;
                if holders < req.min_count {
                    assert!(
                        result.warnings.iter().any(|w| w.shift_id == shift.id
                            && w.role.as_deref() == Some(req.role.as_str())),
                        "shift {} role {} unmet ({holders}/{}) but no warning [{}]",
                        shift.id,
                        req.role,
                        req.min_count,
                        ctx(&cfg)
                    );
                }
            }
            // Wildcard headcount: under min → warning with no role.
            if !shift.has_required_role() && (assigned.len() as u32) < shift.min_employees {
                assert!(
                    result
                        .warnings
                        .iter()
                        .any(|w| w.shift_id == shift.id && w.role.is_none()),
                    "wildcard shift {} under-staffed ({}/{}) but no warning [{}]",
                    shift.id,
                    assigned.len(),
                    shift.min_employees,
                    ctx(&cfg)
                );
            }
        }
    }
}

#[test]
fn corpus_scale_determinism() {
    for cfg in all_configs() {
        let c = generate_corpus_with(cfg);
        let a = serde_json::to_string(&run(&c)).unwrap();
        let b = serde_json::to_string(&run(&c)).unwrap();
        assert_eq!(a, b, "same corpus scheduled twice diverged [{}]", ctx(&cfg));
    }
}

#[test]
fn legacy_corpus_is_byte_stable_for_benches() {
    // The bench/perf corpus must not drift when the generator grows knobs:
    // criterion history and XCUITest perf baselines compare against it.
    let via_legacy = helpers::corpus::generate_corpus(200, 1, helpers::corpus::DEFAULT_SEED);
    let via_config = generate_corpus_with(CorpusConfig {
        employees: 200,
        weeks: 1,
        seed: helpers::corpus::DEFAULT_SEED,
        enriched_shifts: false,
    });
    assert_eq!(
        serde_json::to_string(&run(&via_legacy)).unwrap(),
        serde_json::to_string(&run(&via_config)).unwrap(),
        "legacy generate_corpus path must be identical to enriched_shifts=false"
    );
    assert_eq!(via_legacy.shifts.len(), via_config.shifts.len());
    assert_eq!(
        via_legacy.templates.len(),
        6,
        "legacy template set grew — bench baselines invalidated"
    );
}
