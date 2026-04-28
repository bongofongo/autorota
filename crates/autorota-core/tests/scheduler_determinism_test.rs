//! Pin scheduler determinism: identical inputs must always produce identical
//! outputs across many runs. Catches future regressions where someone iterates
//! a `HashMap` to feed scoring (Rust's HashMap uses a randomized seed per
//! process, so iteration order varies run-to-run).

mod helpers;

use autorota_core::models::availability::AvailabilityState;
use autorota_core::scheduler::schedule_pure;
use chrono::Weekday;

use helpers::{date, make_employee, make_shift, week_start};

fn fixed_inputs() -> (
    Vec<autorota_core::models::employee::Employee>,
    Vec<autorota_core::models::shift::Shift>,
) {
    let employees = vec![
        make_employee(1, "Alice", "barista", AvailabilityState::Yes),
        make_employee(2, "Bob", "barista", AvailabilityState::Yes),
        make_employee(3, "Carol", "barista", AvailabilityState::Maybe),
        make_employee(4, "Dave", "barista", AvailabilityState::Yes),
        make_employee(5, "Eve", "cashier", AvailabilityState::Yes),
    ];
    // Mix of roles, weekdays, and capacities so the difficulty/score/tiebreak
    // path is exercised, not just a single trivial pick.
    let shifts = vec![
        make_shift(101, date(23), 7, 12, "barista"),  // Mon
        make_shift(102, date(24), 8, 16, "barista"),  // Tue
        make_shift(103, date(25), 12, 20, "barista"), // Wed
        make_shift(104, date(26), 9, 17, "cashier"),  // Thu
        make_shift(105, date(27), 6, 14, ""),         // Fri wildcard
    ];
    (employees, shifts)
}

#[test]
fn schedule_pure_is_deterministic_across_100_runs() {
    let (employees, shifts) = fixed_inputs();
    let week = week_start();

    let baseline = schedule_pure(&shifts, &employees, &[], &[], 1, week);
    let baseline_json = serde_json::to_string(&baseline).unwrap();

    for i in 1..100 {
        let result = schedule_pure(&shifts, &employees, &[], &[], 1, week);
        let result_json = serde_json::to_string(&result).unwrap();
        assert_eq!(
            baseline_json, result_json,
            "schedule_pure produced a different output on run {i} — non-determinism reintroduced"
        );
    }

    // Sanity: the baseline must do something — an empty result would let the
    // determinism check pass vacuously.
    assert!(
        !baseline.assignments.is_empty(),
        "baseline must include at least one assignment"
    );

    let _ = Weekday::Mon; // imported for symmetry with other scheduler tests
}

/// Stronger guarantee: pick order should depend on score + tiebreak hash, not
/// on the order the caller passes employees / shifts. If a future edit ever
/// makes the result depend on `Vec` insertion order (e.g. swapping a sort for
/// a `HashMap` iteration), this test catches it because the same five
/// employees in a different order would produce a different schedule.
#[test]
fn schedule_pure_output_independent_of_input_order() {
    let (employees, shifts) = fixed_inputs();
    let week = week_start();
    let baseline = schedule_pure(&shifts, &employees, &[], &[], 1, week);
    let baseline_json = serde_json::to_string(&baseline).unwrap();

    let mut emp_rev = employees.clone();
    emp_rev.reverse();
    let result_emp_rev = schedule_pure(&shifts, &emp_rev, &[], &[], 1, week);
    assert_eq!(
        baseline_json,
        serde_json::to_string(&result_emp_rev).unwrap(),
        "reversing employee order changed the schedule"
    );

    let mut shift_rev = shifts.clone();
    shift_rev.reverse();
    let result_shift_rev = schedule_pure(&shift_rev, &employees, &[], &[], 1, week);
    assert_eq!(
        baseline_json,
        serde_json::to_string(&result_shift_rev).unwrap(),
        "reversing shift order changed the schedule"
    );
}
