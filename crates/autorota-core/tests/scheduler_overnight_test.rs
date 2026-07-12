//! Overnight-shift correctness and Pass-1 (override) robustness.
//!
//! Overnight shifts (end_time <= start_time) cross midnight: the tail lands on
//! the following calendar day. Overlap detection and daily-hour budgets must
//! account for that tail.

mod helpers;

use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::AvailabilityState;
use autorota_core::scheduler::schedule_pure;

use helpers::{date, make_employee, make_shift, week_start};

fn overridden(id: i64, employee_id: i64, shift_id: i64) -> Assignment {
    Assignment {
        id,
        rota_id: 1,
        shift_id,
        employee_id,
        status: AssignmentStatus::Overridden,
        employee_name: None,
        hourly_wage: None,
    }
}

// ── Overnight overlap ────────────────────────────────────────

#[test]
fn overnight_shift_blocks_same_day_overlap() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    // Fri 22:00–02:00 (overnight) and Fri 20:00–23:00 overlap 22:00–23:00.
    let overnight = make_shift(1, date(27), 22, 2, "barista");
    let evening = make_shift(2, date(27), 20, 23, "barista");

    let result = schedule_pure(&[overnight, evening], &[emp], &[], &[], 1, week_start());

    assert_eq!(
        result.assignments.len(),
        1,
        "overlapping shifts must not both be assigned to one employee"
    );
    assert_eq!(result.warnings.len(), 1);
}

#[test]
fn overnight_tail_blocks_next_day_overlap() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    // Fri 22:00–02:00 spills into Saturday; Sat 01:00–05:00 overlaps 01:00–02:00.
    let overnight = make_shift(1, date(27), 22, 2, "barista");
    let early = make_shift(2, date(28), 1, 5, "barista");

    let result = schedule_pure(&[overnight, early], &[emp], &[], &[], 1, week_start());

    assert_eq!(
        result.assignments.len(),
        1,
        "overnight tail overlaps next-day shift; both assigned = double-booking"
    );
    assert_eq!(result.warnings.len(), 1);
}

#[test]
fn overnight_tail_counts_toward_next_day_cap() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    emp.max_daily_hours = 6.0;
    // Fri 22:00–02:00 books 2h on Saturday. Sat 03:00–08:00 (5h) would take
    // Saturday to 7h > 6h cap. No time overlap — daily budget must block it.
    let overnight = make_shift(1, date(27), 22, 2, "barista");
    let saturday = make_shift(2, date(28), 3, 8, "barista");

    let result = schedule_pure(&[overnight, saturday], &[emp], &[], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 1);
    assert_eq!(
        result.assignments[0].shift_id, 1,
        "overnight shift (earlier date) is scheduled first; Saturday shift must be blocked by its 2h tail"
    );
}

#[test]
fn non_overnight_shifts_on_adjacent_days_do_not_overlap() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    // Sanity: plain evening shift then next-morning shift — no overlap, both fine.
    let fri = make_shift(1, date(27), 18, 22, "barista");
    let sat = make_shift(2, date(28), 7, 11, "barista");

    let result = schedule_pure(&[fri, sat], &[emp], &[], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 2);
    assert!(result.warnings.is_empty());
}

// ── Pass-1 robustness ────────────────────────────────────────

#[test]
fn duplicate_overridden_rows_counted_once() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    // target=4, deviation=6 → max weekly 10h
    emp.target_weekly_hours = 4.0;
    emp.weekly_hours_deviation = 6.0;

    let pinned = make_shift(1, date(27), 7, 12, "barista"); // 5h, pinned twice
    let open = make_shift(2, date(28), 7, 11, "barista"); // 4h; 5+4=9 ≤ 10 must fit

    let result = schedule_pure(
        &[pinned, open],
        &[emp],
        &[overridden(1, 1, 1), overridden(2, 1, 1)],
        &[],
        1,
        week_start(),
    );

    let for_pinned = result
        .assignments
        .iter()
        .filter(|a| a.shift_id == 1)
        .count();
    assert_eq!(
        for_pinned, 1,
        "duplicate Overridden rows must collapse to one assignment"
    );
    assert_eq!(
        result.assignments.len(),
        2,
        "double-counted pinned hours must not eat the weekly budget for shift 2"
    );
}

#[test]
fn override_for_unknown_employee_survives_without_snapshot() {
    // Employee 99 was deleted but the Overridden row remains — the pin is
    // honored, with no name/wage snapshot to copy.
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let shift = make_shift(1, date(27), 7, 12, "barista");

    let result = schedule_pure(
        &[shift],
        &[alice],
        &[overridden(1, 99, 1)],
        &[],
        1,
        week_start(),
    );

    let pinned = result
        .assignments
        .iter()
        .find(|a| a.employee_id == 99)
        .expect("override for unknown employee is still honored");
    assert_eq!(pinned.status, AssignmentStatus::Overridden);
    assert_eq!(pinned.employee_name, None);
    assert_eq!(pinned.hourly_wage, None);
    // Shift (capacity 1) is full — Alice must not be added on top.
    assert_eq!(result.assignments.len(), 1);
}

#[test]
fn override_with_dangling_shift_is_skipped() {
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let shift = make_shift(1, date(27), 7, 12, "barista");

    let result = schedule_pure(
        &[shift],
        &[alice],
        &[overridden(1, 1, 99)],
        &[],
        1,
        week_start(),
    );

    assert!(
        result.assignments.iter().all(|a| a.shift_id != 99),
        "override pointing at a nonexistent shift is dropped"
    );
    // The real shift still gets filled normally.
    assert_eq!(result.assignments.len(), 1);
    assert_eq!(result.assignments[0].shift_id, 1);
    assert_eq!(result.assignments[0].status, AssignmentStatus::Proposed);
}

#[test]
fn overrides_beyond_capacity_do_not_grow_in_pass_two() {
    // Two pins on a max-1 shift: Pass 1 keeps both (manual pins win), but
    // Pass 2 must not add anyone else.
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let bob = make_employee(2, "Bob", "barista", AvailabilityState::Yes);
    let carol = make_employee(3, "Carol", "barista", AvailabilityState::Yes);
    let shift = make_shift(1, date(27), 7, 12, "barista"); // capacity 1/1

    let result = schedule_pure(
        &[shift],
        &[alice, bob, carol],
        &[overridden(1, 1, 1), overridden(2, 2, 1)],
        &[],
        1,
        week_start(),
    );

    assert_eq!(result.assignments.len(), 2);
    assert!(
        result
            .assignments
            .iter()
            .all(|a| a.status == AssignmentStatus::Overridden),
        "no Proposed assignment may be added to an over-pinned shift"
    );
}
