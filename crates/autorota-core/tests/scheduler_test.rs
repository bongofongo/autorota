use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::{Availability, AvailabilityState};
use autorota_core::models::employee::Employee;
use autorota_core::models::shift::Shift;
use autorota_core::scheduler::schedule_pure;
use chrono::{NaiveDate, NaiveTime, Weekday};

fn date(d: u32) -> NaiveDate {
    // March 2026: 23=Mon, 24=Tue, ...
    NaiveDate::from_ymd_opt(2026, 3, d).unwrap()
}

fn time(h: u32) -> NaiveTime {
    NaiveTime::from_hms_opt(h, 0, 0).unwrap()
}

fn week_start() -> NaiveDate {
    date(23) // Monday
}

fn make_employee(id: i64, name: &str, role: &str, avail_state: AvailabilityState) -> Employee {
    let mut avail = Availability::default();
    for day in [
        Weekday::Mon,
        Weekday::Tue,
        Weekday::Wed,
        Weekday::Thu,
        Weekday::Fri,
    ] {
        for h in 6..22 {
            avail.set(day, h, avail_state);
        }
    }
    Employee {
        id,
        name: name.to_string(),
        roles: vec![role.to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 40.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: avail.clone(),
        availability: avail,
    }
}

fn make_shift(id: i64, date: NaiveDate, start: u32, end: u32, role: &str) -> Shift {
    Shift {
        id,
        template_id: 1,
        rota_id: 1,
        date,
        start_time: time(start),
        end_time: time(end),
        required_role: role.to_string(),
        min_employees: 1,
        max_employees: 1,
    }
}

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
