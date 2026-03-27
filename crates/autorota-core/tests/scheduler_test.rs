mod helpers;

use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::AvailabilityState;
use autorota_core::scheduler::schedule_pure;
use chrono::Weekday;

use helpers::{date, make_employee, make_shift, week_start};

#[test]
fn single_employee_single_shift() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let shift = make_shift(1, date(23), 7, 12, "barista");

    let result = schedule_pure(&[shift], &[emp], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 1);
    assert_eq!(result.assignments[0].employee_id, 1);
    assert_eq!(result.assignments[0].status, AssignmentStatus::Proposed);
    assert!(result.warnings.is_empty());
}

#[test]
fn yes_preferred_over_maybe() {
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Maybe);
    let bob = make_employee(2, "Bob", "barista", AvailabilityState::Yes);
    let shift = make_shift(1, date(23), 7, 12, "barista");

    let result = schedule_pure(&[shift], &[alice, bob], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 1);
    assert_eq!(result.assignments[0].employee_id, 2); // Bob (Yes) wins
}

#[test]
fn no_availability_excluded() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::No);
    let shift = make_shift(1, date(23), 7, 12, "barista");

    let result = schedule_pure(&[shift], &[emp], &[], 1, week_start());

    assert!(result.assignments.is_empty());
    assert_eq!(result.warnings.len(), 1);
    assert_eq!(result.warnings[0].shift_id, 1);
}

#[test]
fn wrong_role_excluded() {
    let emp = make_employee(1, "Alice", "cashier", AvailabilityState::Yes);
    let shift = make_shift(1, date(23), 7, 12, "barista");

    let result = schedule_pure(&[shift], &[emp], &[], 1, week_start());

    assert!(result.assignments.is_empty());
    assert_eq!(result.warnings.len(), 1);
}

#[test]
fn weekly_hour_cap_respected() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    // target=4, deviation=6 → max=10h
    emp.target_weekly_hours = 4.0;
    emp.weekly_hours_deviation = 6.0;

    // Two 6-hour shifts — only the first should be assigned (6 < 10, but 12 > 10)
    let s1 = make_shift(1, date(23), 7, 13, "barista"); // 6h
    let s2 = make_shift(2, date(24), 7, 13, "barista"); // 6h, would exceed 10h cap

    let result = schedule_pure(&[s1, s2], &[emp], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 1);
    assert_eq!(result.assignments[0].shift_id, 1);
    assert_eq!(result.warnings.len(), 1); // s2 understaffed
}

#[test]
fn daily_hour_cap_respected() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    emp.max_daily_hours = 6.0;

    // Two shifts on the same day, 4h each — second would exceed 6h cap
    let s1 = make_shift(1, date(23), 7, 11, "barista"); // 4h
    let s2 = make_shift(2, date(23), 13, 17, "barista"); // 4h, total=8 > 6

    let result = schedule_pure(&[s1, s2], &[emp], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 1);
}

#[test]
fn fairness_spreads_hours() {
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let bob = make_employee(2, "Bob", "barista", AvailabilityState::Yes);

    // Three shifts across different days
    let s1 = make_shift(1, date(23), 7, 12, "barista"); // Mon
    let s2 = make_shift(2, date(24), 7, 12, "barista"); // Tue
    let s3 = make_shift(3, date(25), 7, 12, "barista"); // Wed

    let result = schedule_pure(&[s1, s2, s3], &[alice, bob], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 3);

    let alice_count = result
        .assignments
        .iter()
        .filter(|a| a.employee_id == 1)
        .count();
    let bob_count = result
        .assignments
        .iter()
        .filter(|a| a.employee_id == 2)
        .count();

    // With fairness, hours should be spread: one gets 2, the other gets 1
    // (not all 3 to the same person)
    assert!(alice_count >= 1 && bob_count >= 1);
}

#[test]
fn overrides_respected() {
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let bob = make_employee(2, "Bob", "barista", AvailabilityState::Yes);

    let shift = make_shift(1, date(23), 7, 12, "barista");

    // Pre-assign Bob as an override
    let existing = vec![Assignment {
        id: 1,
        rota_id: 1,
        shift_id: 1,
        employee_id: 2,
        status: AssignmentStatus::Overridden,
        employee_name: Some("Bob".to_string()),
    }];

    let result = schedule_pure(&[shift], &[alice, bob], &existing, 1, week_start());

    // The override should be included, and no additional assignment for a 1-person shift
    assert_eq!(result.assignments.len(), 1);
    assert_eq!(result.assignments[0].employee_id, 2);
    assert_eq!(result.assignments[0].status, AssignmentStatus::Overridden);
}

#[test]
fn multi_capacity_shift() {
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let bob = make_employee(2, "Bob", "barista", AvailabilityState::Yes);

    let mut shift = make_shift(1, date(23), 7, 12, "barista");
    shift.min_employees = 2;
    shift.max_employees = 2;

    let result = schedule_pure(&[shift], &[alice, bob], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 2);
    assert!(result.warnings.is_empty());
}

#[test]
fn overlapping_shifts_prevented() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);

    // Two overlapping shifts on the same day
    let s1 = make_shift(1, date(23), 7, 12, "barista"); // 7-12
    let s2 = make_shift(2, date(23), 10, 15, "barista"); // 10-15, overlaps s1

    let result = schedule_pure(&[s1, s2], &[emp], &[], 1, week_start());

    // Only one should be assigned (the other has no eligible candidate)
    assert_eq!(result.assignments.len(), 1);
    assert_eq!(result.warnings.len(), 1);
}

#[test]
fn hardest_to_fill_assigned_first() {
    // Alice: only barista. Bob: barista + cashier.
    let mut alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    alice.max_daily_hours = 6.0;
    let mut bob = make_employee(2, "Bob", "barista", AvailabilityState::Yes);
    bob.roles.push("cashier".to_string());
    bob.max_daily_hours = 6.0;

    // Barista shift (Alice or Bob eligible) and cashier shift (only Bob eligible)
    // Both on same day — if cashier goes first (hardest to fill), Bob gets cashier,
    // Alice gets barista. Otherwise Bob might get barista and cashier goes unfilled.
    let barista_shift = make_shift(1, date(23), 7, 12, "barista");
    let cashier_shift = make_shift(2, date(23), 7, 12, "cashier");

    let result = schedule_pure(
        &[barista_shift, cashier_shift],
        &[alice, bob],
        &[],
        1,
        week_start(),
    );

    assert_eq!(result.assignments.len(), 2);
    assert!(result.warnings.is_empty());

    // Bob should be assigned to cashier (only option), Alice to barista
    let cashier_assignment = result.assignments.iter().find(|a| a.shift_id == 2).unwrap();
    assert_eq!(cashier_assignment.employee_id, 2); // Bob

    let barista_assignment = result.assignments.iter().find(|a| a.shift_id == 1).unwrap();
    assert_eq!(barista_assignment.employee_id, 1); // Alice
}

// ─── New edge-case tests ─────────────────────────────────────

#[test]
fn empty_inputs_produce_empty_result() {
    let result = schedule_pure(&[], &[], &[], 1, week_start());
    assert!(result.assignments.is_empty());
    assert!(result.warnings.is_empty());
}

#[test]
fn all_maybe_still_assigns() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::Maybe);
    let shift = make_shift(1, date(23), 7, 12, "barista");

    let result = schedule_pure(&[shift], &[emp], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 1);
    assert!(result.warnings.is_empty());
}

#[test]
fn multi_role_employee_fills_different_roles() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    emp.roles.push("cashier".to_string());
    emp.roles.push("manager".to_string());
    emp.max_daily_hours = 15.0;
    emp.target_weekly_hours = 40.0;
    emp.weekly_hours_deviation = 20.0;

    // Three shifts on different days requiring different roles
    let s1 = make_shift(1, date(23), 7, 12, "barista");
    let s2 = make_shift(2, date(24), 7, 12, "cashier");
    let s3 = make_shift(3, date(25), 7, 12, "manager");

    let result = schedule_pure(&[s1, s2, s3], &[emp], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 3);
    assert!(result.warnings.is_empty());
}

#[test]
fn tiebreak_is_deterministic() {
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let bob = make_employee(2, "Bob", "barista", AvailabilityState::Yes);
    let shift = make_shift(1, date(23), 7, 12, "barista");

    let result1 = schedule_pure(&[shift.clone()], &[alice.clone(), bob.clone()], &[], 1, week_start());
    let result2 = schedule_pure(&[shift], &[alice, bob], &[], 1, week_start());

    assert_eq!(result1.assignments[0].employee_id, result2.assignments[0].employee_id);
}

#[test]
fn override_counts_toward_hours_budget() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    emp.target_weekly_hours = 8.0;
    emp.weekly_hours_deviation = 2.0; // max 10h

    let s1 = make_shift(1, date(23), 7, 15, "barista"); // 8h override
    let s2 = make_shift(2, date(24), 7, 12, "barista"); // 5h, would push to 13h > 10h

    let existing = vec![Assignment {
        id: 1,
        rota_id: 1,
        shift_id: 1,
        employee_id: 1,
        status: AssignmentStatus::Overridden,
        employee_name: Some("Alice".to_string()),
    }];

    let result = schedule_pure(&[s1, s2], &[emp], &existing, 1, week_start());

    // Override takes 8h. s2 would push to 13h > 10h max, so it shouldn't be assigned.
    let proposed: Vec<_> = result.assignments.iter().filter(|a| a.status == AssignmentStatus::Proposed).collect();
    assert!(proposed.is_empty(), "second shift should not be assigned due to weekly budget");
    assert_eq!(result.warnings.len(), 1);
}

#[test]
fn overnight_shift_with_matching_availability() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::No);
    // Set availability for overnight hours on Friday
    for h in 22..24 {
        emp.availability.set(Weekday::Fri, h, AvailabilityState::Yes);
        emp.default_availability.set(Weekday::Fri, h, AvailabilityState::Yes);
    }
    for h in 0..6 {
        emp.availability.set(Weekday::Fri, h, AvailabilityState::Yes);
        emp.default_availability.set(Weekday::Fri, h, AvailabilityState::Yes);
    }

    // Friday overnight shift 22:00-02:00
    let shift = make_shift(1, date(27), 22, 2, "barista"); // date(27) = Friday

    let result = schedule_pure(&[shift], &[emp], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 1);
    assert!(result.warnings.is_empty());
}

#[test]
fn zero_max_capacity_shift_produces_no_assignments() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let mut shift = make_shift(1, date(23), 7, 12, "barista");
    shift.min_employees = 0;
    shift.max_employees = 0;

    let result = schedule_pure(&[shift], &[emp], &[], 1, week_start());

    assert!(result.assignments.is_empty());
    assert!(result.warnings.is_empty());
}
