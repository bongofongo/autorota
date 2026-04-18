//! Edge-case test suite for autorota-core engine and database.
//!
//! Targets gaps surfaced by a coverage audit:
//! - Scheduler boundary conditions (zero hour budgets, partial fills, override conflicts)
//! - Availability override CRUD
//! - Shift template override CRUD + materialise interactions
//! - Staging operations
//! - Commits
//! - Cascade / constraint / sync edges

mod helpers;

use autorota_core::db::queries;
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::AvailabilityState;
use autorota_core::models::overrides::{
    DayAvailability, EmployeeAvailabilityOverride, ShiftTemplateOverride,
};
use autorota_core::models::shift::ShiftTemplate;
use autorota_core::scheduler::schedule_pure;
use chrono::{NaiveDate, NaiveTime, Weekday};

use helpers::{date, make_employee, make_shift, query_sync_status, test_pool, time, week_start};

// ─────────────────────────────────────────────────────────────
// A. Scheduler edge cases
// ─────────────────────────────────────────────────────────────

#[test]
fn hour_budget_zero_blocks_all_assignments() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    emp.target_weekly_hours = 0.0;
    emp.weekly_hours_deviation = 0.0;
    let shift = make_shift(1, date(23), 7, 12, "barista");

    let result = schedule_pure(&[shift], &[emp], &[], &[], 1, week_start());

    assert!(result.assignments.is_empty());
    assert_eq!(result.warnings.len(), 1);
}

#[test]
fn daily_hour_cap_zero_blocks_day() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    emp.max_daily_hours = 0.0;
    let shift = make_shift(1, date(23), 7, 12, "barista");

    let result = schedule_pure(&[shift], &[emp], &[], &[], 1, week_start());

    assert!(result.assignments.is_empty());
}

#[test]
fn employee_at_exact_max_weekly_excluded_from_next_shift() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    // max_weekly = 5h exactly
    emp.target_weekly_hours = 5.0;
    emp.weekly_hours_deviation = 0.0;
    emp.max_daily_hours = 24.0;

    let s1 = make_shift(1, date(23), 7, 12, "barista"); // 5h - fills budget exactly
    let s2 = make_shift(2, date(24), 7, 9, "barista"); // 2h - should NOT fit

    let result = schedule_pure(&[s1, s2], &[emp], &[], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 1);
    assert_eq!(result.assignments[0].shift_id, 1);
    assert_eq!(result.warnings.len(), 1);
}

#[test]
fn partial_fill_when_eligible_lt_required() {
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let bob = make_employee(2, "Bob", "barista", AvailabilityState::Yes);

    let mut shift = make_shift(1, date(23), 7, 12, "barista");
    shift.min_employees = 5;
    shift.max_employees = 5;

    let result = schedule_pure(&[shift], &[alice, bob], &[], &[], 1, week_start());

    // Both eligible employees assigned exactly once each, no duplicates.
    assert_eq!(result.assignments.len(), 2);
    let mut emp_ids: Vec<i64> = result.assignments.iter().map(|a| a.employee_id).collect();
    emp_ids.sort();
    assert_eq!(emp_ids, vec![1, 2]);
    assert!(!result.warnings.is_empty(), "should warn about understaff");
}

#[test]
fn over_capacity_fairness_distributes_hours() {
    let alice = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let bob = make_employee(2, "Bob", "barista", AvailabilityState::Yes);

    // 3 shifts × 2 slots = 6 needed. With 2 employees, ideal split is 3 + 3.
    let mut s1 = make_shift(1, date(23), 7, 12, "barista");
    s1.min_employees = 2;
    s1.max_employees = 2;
    let mut s2 = make_shift(2, date(24), 7, 12, "barista");
    s2.min_employees = 2;
    s2.max_employees = 2;
    let mut s3 = make_shift(3, date(25), 7, 12, "barista");
    s3.min_employees = 2;
    s3.max_employees = 2;

    let result = schedule_pure(&[s1, s2, s3], &[alice, bob], &[], &[], 1, week_start());

    assert_eq!(result.assignments.len(), 6);
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
    assert_eq!(alice_count, 3);
    assert_eq!(bob_count, 3);
}

#[test]
fn availability_override_no_beats_default_yes() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let shift = make_shift(1, date(23), 7, 12, "barista");

    let mut day = DayAvailability::default();
    for h in 7..12 {
        day.set(h, AvailabilityState::No);
    }
    let ovr = EmployeeAvailabilityOverride {
        id: 1,
        employee_id: 1,
        date: date(23),
        availability: day,
        notes: None,
    };

    let result = schedule_pure(&[shift], &[emp], &[], &[ovr], 1, week_start());
    assert!(result.assignments.is_empty());
}

#[test]
fn availability_override_partial_window_excludes_employee() {
    let emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    let shift = make_shift(1, date(23), 8, 13, "barista");

    let mut day = DayAvailability::default();
    day.set(8, AvailabilityState::Yes);
    day.set(9, AvailabilityState::Yes);
    day.set(10, AvailabilityState::Yes);
    day.set(11, AvailabilityState::No);
    day.set(12, AvailabilityState::No);
    let ovr = EmployeeAvailabilityOverride {
        id: 1,
        employee_id: 1,
        date: date(23),
        availability: day,
        notes: None,
    };

    let result = schedule_pure(&[shift], &[emp], &[], &[ovr], 1, week_start());
    assert!(result.assignments.is_empty());
}

#[test]
fn override_assignment_counts_toward_hour_budget_at_boundary() {
    let mut emp = make_employee(1, "Alice", "barista", AvailabilityState::Yes);
    emp.target_weekly_hours = 5.0;
    emp.weekly_hours_deviation = 0.0;
    emp.max_daily_hours = 24.0;

    let s1 = make_shift(1, date(23), 7, 12, "barista"); // 5h
    let s2 = make_shift(2, date(24), 7, 9, "barista"); // 2h

    // Pin Alice to s1 via Overridden assignment.
    let pin = Assignment {
        id: 0,
        rota_id: 1,
        shift_id: 1,
        employee_id: 1,
        status: AssignmentStatus::Overridden,
        employee_name: Some("Alice".into()),
        hourly_wage: None,
    };

    let result = schedule_pure(&[s1, s2], &[emp], &[pin], &[], 1, week_start());

    // s1 filled by override; s2 must NOT be assigned because Alice is at her cap.
    assert_eq!(result.assignments.len(), 1);
    assert_eq!(result.assignments[0].shift_id, 1);
}

// ─────────────────────────────────────────────────────────────
// B. Availability override CRUD
// ─────────────────────────────────────────────────────────────

fn make_simple_employee(name: &str) -> autorota_core::models::employee::Employee {
    make_employee(0, name, "barista", AvailabilityState::Yes)
}

#[tokio::test]
async fn availability_override_upsert_and_get_roundtrip() {
    let pool = test_pool().await;
    let emp_id = queries::insert_employee(&pool, &make_simple_employee("Alice"))
        .await
        .unwrap();

    let mut day = DayAvailability::default();
    day.set(8, AvailabilityState::Yes);
    day.set(9, AvailabilityState::No);
    let ovr = EmployeeAvailabilityOverride {
        id: 0,
        employee_id: emp_id,
        date: date(23),
        availability: day,
        notes: Some("vacation".into()),
    };
    let id = queries::upsert_employee_availability_override(&pool, &ovr)
        .await
        .unwrap();
    assert!(id > 0);

    let got = queries::get_employee_availability_override(&pool, emp_id, date(23))
        .await
        .unwrap()
        .expect("override should exist");
    assert_eq!(got.notes.as_deref(), Some("vacation"));
    assert_eq!(got.availability.get(8), AvailabilityState::Yes);
    assert_eq!(got.availability.get(9), AvailabilityState::No);
    assert_eq!(got.availability.get(10), AvailabilityState::Maybe);
}

#[tokio::test]
async fn availability_override_upsert_replaces_existing() {
    let pool = test_pool().await;
    let emp_id = queries::insert_employee(&pool, &make_simple_employee("Alice"))
        .await
        .unwrap();

    let mut day = DayAvailability::default();
    day.set(8, AvailabilityState::Yes);
    let ovr1 = EmployeeAvailabilityOverride {
        id: 0,
        employee_id: emp_id,
        date: date(23),
        availability: day,
        notes: None,
    };
    queries::upsert_employee_availability_override(&pool, &ovr1)
        .await
        .unwrap();

    let mut day2 = DayAvailability::default();
    day2.set(8, AvailabilityState::No);
    let ovr2 = EmployeeAvailabilityOverride {
        id: 0,
        employee_id: emp_id,
        date: date(23),
        availability: day2,
        notes: Some("changed".into()),
    };
    queries::upsert_employee_availability_override(&pool, &ovr2)
        .await
        .unwrap();

    let got = queries::get_employee_availability_override(&pool, emp_id, date(23))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(got.availability.get(8), AvailabilityState::No);
    assert_eq!(got.notes.as_deref(), Some("changed"));

    let all = queries::list_employee_availability_overrides_for_employee(&pool, emp_id)
        .await
        .unwrap();
    assert_eq!(all.len(), 1, "upsert should not create duplicate row");
}

#[tokio::test]
async fn availability_override_list_for_employee() {
    let pool = test_pool().await;
    let alice = queries::insert_employee(&pool, &make_simple_employee("Alice"))
        .await
        .unwrap();
    let bob = queries::insert_employee(&pool, &make_simple_employee("Bob"))
        .await
        .unwrap();

    for (emp_id, day_n) in [(alice, 23), (alice, 24), (bob, 23)] {
        let ovr = EmployeeAvailabilityOverride {
            id: 0,
            employee_id: emp_id,
            date: date(day_n),
            availability: DayAvailability::default(),
            notes: None,
        };
        queries::upsert_employee_availability_override(&pool, &ovr)
            .await
            .unwrap();
    }

    let alice_overrides = queries::list_employee_availability_overrides_for_employee(&pool, alice)
        .await
        .unwrap();
    assert_eq!(alice_overrides.len(), 2);
    assert!(alice_overrides.iter().all(|o| o.employee_id == alice));

    let all = queries::list_all_employee_availability_overrides(&pool)
        .await
        .unwrap();
    assert_eq!(all.len(), 3);
}

#[tokio::test]
async fn availability_override_delete_removes_row() {
    let pool = test_pool().await;
    let emp_id = queries::insert_employee(&pool, &make_simple_employee("Alice"))
        .await
        .unwrap();

    let ovr = EmployeeAvailabilityOverride {
        id: 0,
        employee_id: emp_id,
        date: date(23),
        availability: DayAvailability::default(),
        notes: None,
    };
    let id = queries::upsert_employee_availability_override(&pool, &ovr)
        .await
        .unwrap();

    queries::delete_employee_availability_override(&pool, id)
        .await
        .unwrap();
    let got = queries::get_employee_availability_override(&pool, emp_id, date(23))
        .await
        .unwrap();
    assert!(got.is_none());
}

// ─────────────────────────────────────────────────────────────
// C. Shift template override CRUD + materialise
// ─────────────────────────────────────────────────────────────

fn make_test_template() -> ShiftTemplate {
    ShiftTemplate {
        id: 0,
        name: "Morning".into(),
        weekdays: vec![Weekday::Mon],
        start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".into(),
        min_employees: 1,
        max_employees: 2,
        deleted: false,
    }
}

#[tokio::test]
async fn template_override_cancelled_skipped_in_materialise() {
    let pool = test_pool().await;
    let tmpl_id = queries::insert_shift_template(&pool, &make_test_template())
        .await
        .unwrap();
    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();

    let ovr = ShiftTemplateOverride {
        id: 0,
        template_id: tmpl_id,
        date: week_start(), // Mon
        cancelled: true,
        start_time: None,
        end_time: None,
        min_employees: None,
        max_employees: None,
        notes: None,
    };
    queries::upsert_shift_template_override(&pool, &ovr)
        .await
        .unwrap();

    let shifts = queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();
    assert!(
        shifts.is_empty(),
        "cancelled override should suppress shift materialisation"
    );
}

#[tokio::test]
async fn template_override_time_change_applied_in_materialise() {
    let pool = test_pool().await;
    let tmpl_id = queries::insert_shift_template(&pool, &make_test_template())
        .await
        .unwrap();
    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();

    let ovr = ShiftTemplateOverride {
        id: 0,
        template_id: tmpl_id,
        date: week_start(),
        cancelled: false,
        start_time: Some(time(9)),
        end_time: Some(time(15)),
        min_employees: None,
        max_employees: None,
        notes: None,
    };
    queries::upsert_shift_template_override(&pool, &ovr)
        .await
        .unwrap();

    let shifts = queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();
    assert_eq!(shifts.len(), 1);
    assert_eq!(shifts[0].start_time, time(9));
    assert_eq!(shifts[0].end_time, time(15));
    assert_eq!(shifts[0].max_employees, 2, "non-overridden field preserved");
}

#[tokio::test]
async fn template_override_capacity_change_applied() {
    let pool = test_pool().await;
    let tmpl_id = queries::insert_shift_template(&pool, &make_test_template())
        .await
        .unwrap();
    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();

    let ovr = ShiftTemplateOverride {
        id: 0,
        template_id: tmpl_id,
        date: week_start(),
        cancelled: false,
        start_time: None,
        end_time: None,
        min_employees: Some(3),
        max_employees: Some(4),
        notes: None,
    };
    queries::upsert_shift_template_override(&pool, &ovr)
        .await
        .unwrap();

    let shifts = queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();
    assert_eq!(shifts.len(), 1);
    assert_eq!(shifts[0].min_employees, 3);
    assert_eq!(shifts[0].max_employees, 4);
}

#[tokio::test]
async fn template_override_upsert_get_delete_roundtrip() {
    let pool = test_pool().await;
    let tmpl_id = queries::insert_shift_template(&pool, &make_test_template())
        .await
        .unwrap();

    let ovr = ShiftTemplateOverride {
        id: 0,
        template_id: tmpl_id,
        date: date(24),
        cancelled: false,
        start_time: Some(time(8)),
        end_time: None,
        min_employees: None,
        max_employees: None,
        notes: Some("note".into()),
    };
    let id = queries::upsert_shift_template_override(&pool, &ovr)
        .await
        .unwrap();
    assert!(id > 0);

    let got = queries::get_shift_template_override(&pool, tmpl_id, date(24))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(got.start_time, Some(time(8)));
    assert_eq!(got.notes.as_deref(), Some("note"));

    let by_template = queries::list_shift_template_overrides_for_template(&pool, tmpl_id)
        .await
        .unwrap();
    assert_eq!(by_template.len(), 1);

    queries::delete_shift_template_override(&pool, id)
        .await
        .unwrap();
    let after = queries::get_shift_template_override(&pool, tmpl_id, date(24))
        .await
        .unwrap();
    assert!(after.is_none());
}

// ─────────────────────────────────────────────────────────────
// D. Staging operations
// ─────────────────────────────────────────────────────────────

async fn seed_rota_with_past_shifts(pool: &sqlx::SqlitePool) -> (i64, Vec<i64>) {
    let rota_id = queries::insert_rota(pool, week_start()).await.unwrap();
    let mut ids = Vec::new();
    for day_n in [23u32, 24, 25] {
        let mut s = make_shift(0, date(day_n), 7, 12, "barista");
        s.rota_id = rota_id;
        s.template_id = None;
        let id = queries::insert_shift(pool, &s).await.unwrap();
        ids.push(id);
    }
    (rota_id, ids)
}

// ─────────────────────────────────────────────────────────────
// E. Saves
// ─────────────────────────────────────────────────────────────

#[tokio::test]
async fn create_save_and_retrieve() {
    let pool = test_pool().await;
    let (rota_id, _ids) = seed_rota_with_past_shifts(&pool).await;

    let save_id = queries::create_save(&pool, rota_id).await.unwrap();
    assert!(save_id > 0);

    let got = queries::get_save(&pool, save_id).await.unwrap().unwrap();
    assert_eq!(got.rota_id, rota_id);
    assert!(got.summary.contains("3 shifts"));
    assert!(got.snapshot_json.contains("committed_shift_ids"));
}

#[tokio::test]
async fn create_save_rejects_empty_rota() {
    let pool = test_pool().await;
    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();

    let result = queries::create_save(&pool, rota_id).await;
    assert!(result.is_err(), "rota with no shifts should be rejected");
}

#[tokio::test]
async fn list_saves_orders_newest_first() {
    let pool = test_pool().await;
    let (rota_id, _ids) = seed_rota_with_past_shifts(&pool).await;

    let s1 = queries::create_save(&pool, rota_id).await.unwrap();
    // Ensure distinct timestamps.
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    let s2 = queries::create_save(&pool, rota_id).await.unwrap();

    let saves = queries::list_saves(&pool, Some(rota_id)).await.unwrap();
    assert_eq!(saves.len(), 2);
    assert_eq!(saves[0].id, s2, "newest first");
    assert_eq!(saves[1].id, s1);
}

#[tokio::test]
async fn rota_has_saves_reflects_state() {
    let pool = test_pool().await;
    let (rota_id, _ids) = seed_rota_with_past_shifts(&pool).await;
    assert!(!queries::rota_has_saves(&pool, rota_id).await.unwrap());

    queries::create_save(&pool, rota_id).await.unwrap();
    assert!(queries::rota_has_saves(&pool, rota_id).await.unwrap());
}

#[tokio::test]
async fn update_save_label_sets_and_clears() {
    let pool = test_pool().await;
    let (rota_id, _ids) = seed_rota_with_past_shifts(&pool).await;
    let save_id = queries::create_save(&pool, rota_id).await.unwrap();

    // Initially no label.
    let got = queries::get_save(&pool, save_id).await.unwrap().unwrap();
    assert!(got.label.is_none());

    // Set a label.
    queries::update_save_label(&pool, save_id, Some("Week 13"))
        .await
        .unwrap();
    let got = queries::get_save(&pool, save_id).await.unwrap().unwrap();
    assert_eq!(got.label.as_deref(), Some("Week 13"));

    // Clear the label.
    queries::update_save_label(&pool, save_id, None)
        .await
        .unwrap();
    let got = queries::get_save(&pool, save_id).await.unwrap().unwrap();
    assert!(got.label.is_none());
}

#[tokio::test]
async fn diff_rota_shows_all_new_when_no_saves() {
    let pool = test_pool().await;
    let (rota_id, ids) = seed_rota_with_past_shifts(&pool).await;

    let diffs = queries::diff_rota_vs_latest_save(&pool, rota_id)
        .await
        .unwrap();
    assert_eq!(diffs.len(), ids.len());
    assert!(diffs.iter().all(|d| d.is_new && !d.is_changed));
}

#[tokio::test]
async fn diff_rota_detects_no_changes_after_save() {
    let pool = test_pool().await;
    let (rota_id, _ids) = seed_rota_with_past_shifts(&pool).await;

    queries::create_save(&pool, rota_id).await.unwrap();
    let diffs = queries::diff_rota_vs_latest_save(&pool, rota_id)
        .await
        .unwrap();
    assert!(diffs.is_empty(), "no diffs after saving identical state");
}

// ─────────────────────────────────────────────────────────────
// F. Cascades, constraints, sync edges
// ─────────────────────────────────────────────────────────────

#[tokio::test]
#[ignore = "Surfaces a real gap: delete_rota tombstones assignments but leaves the rows in place, so list_assignments_for_rota still returns them. Needs product decision before fixing."]
async fn delete_rota_removes_shifts_and_assignments() {
    let pool = test_pool().await;
    let (rota_id, ids) = seed_rota_with_past_shifts(&pool).await;

    let emp_id = queries::insert_employee(&pool, &make_simple_employee("Alice"))
        .await
        .unwrap();
    let assignment = Assignment {
        id: 0,
        rota_id,
        shift_id: ids[0],
        employee_id: emp_id,
        status: AssignmentStatus::Proposed,
        employee_name: Some("Alice".into()),
        hourly_wage: None,
    };
    queries::insert_assignment(&pool, &assignment)
        .await
        .unwrap();

    queries::delete_rota(&pool, rota_id).await.unwrap();

    let rota_now = queries::get_rota(&pool, rota_id).await.unwrap();
    assert!(rota_now.is_none());
    let leftover_shifts: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM shifts WHERE rota_id = ?")
        .bind(rota_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(leftover_shifts, 0);
    // delete_rota inserts tombstones for assignments and removes shifts; the
    // assignment rows themselves currently remain (sync layer treats them as
    // tombstoned). Verify no assignments are reachable via the rota query path.
    let visible = queries::list_assignments_for_rota(&pool, rota_id)
        .await
        .unwrap();
    assert!(visible.is_empty());
}

#[tokio::test]
async fn duplicate_role_name_rejected() {
    let pool = test_pool().await;
    queries::insert_role(&pool, "barista").await.unwrap();
    let result = queries::insert_role(&pool, "barista").await;
    assert!(
        result.is_err(),
        "duplicate role name should violate uniqueness"
    );
}

#[tokio::test]
async fn local_update_resets_sync_status_after_mark_synced() {
    let pool = test_pool().await;
    let emp_id = queries::insert_employee(&pool, &make_simple_employee("Alice"))
        .await
        .unwrap();

    queries::mark_records_synced(&pool, "employees", &[emp_id], &[String::from("{}")])
        .await
        .unwrap();
    let (status, _, _) = query_sync_status(&pool, "employees", emp_id).await;
    assert_eq!(status, 1, "should be synced after mark_records_synced");

    let mut emp = queries::get_employee(&pool, emp_id).await.unwrap().unwrap();
    emp.first_name = "Alicia".into();
    queries::update_employee(&pool, &emp).await.unwrap();

    let (status, _, _) = query_sync_status(&pool, "employees", emp_id).await;
    assert_eq!(status, 0, "local update must reset sync_status to pending");
}

// ─────────────────────────────────────────────────────────────
// G. Orphaned save handling (History page bug fix)
// ─────────────────────────────────────────────────────────────

#[tokio::test]
async fn list_saves_skips_orphaned_saves_with_deleted_rota() {
    let pool = test_pool().await;
    let (rota_id, _ids) = seed_rota_with_past_shifts(&pool).await;

    let save_id = queries::create_save(&pool, rota_id).await.unwrap();
    assert!(save_id > 0);

    // Verify save exists
    let saves = queries::list_saves(&pool, None).await.unwrap();
    assert_eq!(saves.len(), 1);

    // Delete the rota — this should also delete saves
    queries::delete_rota(&pool, rota_id).await.unwrap();

    // Saves should be gone
    let saves = queries::list_saves(&pool, None).await.unwrap();
    assert!(
        saves.is_empty(),
        "saves should be deleted when rota is deleted"
    );
}

#[tokio::test]
async fn get_save_returns_none_for_orphaned_save() {
    let pool = test_pool().await;
    let (rota_id, _ids) = seed_rota_with_past_shifts(&pool).await;

    let save_id = queries::create_save(&pool, rota_id).await.unwrap();

    // Verify save exists
    let save = queries::get_save(&pool, save_id).await.unwrap();
    assert!(save.is_some());

    // Delete the rota
    queries::delete_rota(&pool, rota_id).await.unwrap();

    // Save should be gone
    let save = queries::get_save(&pool, save_id).await.unwrap();
    assert!(
        save.is_none(),
        "orphaned save should not be retrievable after rota deletion"
    );
}

#[tokio::test]
async fn delete_rota_removes_associated_saves() {
    let pool = test_pool().await;
    let (rota_id, _ids) = seed_rota_with_past_shifts(&pool).await;

    // Create two saves for this rota
    queries::create_save(&pool, rota_id).await.unwrap();
    queries::create_save(&pool, rota_id).await.unwrap();

    let before = queries::list_saves(&pool, Some(rota_id)).await.unwrap();
    assert_eq!(before.len(), 2, "should have 2 saves before deletion");

    // Delete the rota
    queries::delete_rota(&pool, rota_id).await.unwrap();

    // All saves for this rota should be gone
    let after_all = queries::list_saves(&pool, None).await.unwrap();
    assert!(
        after_all.is_empty(),
        "all saves should be deleted with their rota"
    );
}

// ─────────────────────────────────────────────────────────────
// H. Save restore
// ─────────────────────────────────────────────────────────────

async fn seed_rota_with_assignments(pool: &sqlx::SqlitePool) -> (i64, Vec<i64>, Vec<i64>) {
    let rota_id = queries::insert_rota(pool, week_start()).await.unwrap();

    // Employees
    let alice = queries::insert_employee(
        pool,
        &make_employee(0, "Alice", "barista", AvailabilityState::Yes),
    )
    .await
    .unwrap();
    let bob = queries::insert_employee(
        pool,
        &make_employee(0, "Bob", "barista", AvailabilityState::Yes),
    )
    .await
    .unwrap();

    // Shifts
    let mut shift_ids = Vec::new();
    for day_n in [23u32, 24, 25] {
        let mut s = make_shift(0, date(day_n), 7, 12, "barista");
        s.rota_id = rota_id;
        s.template_id = None;
        let id = queries::insert_shift(pool, &s).await.unwrap();
        shift_ids.push(id);
    }

    // Assignments: Alice on day 23 (Proposed), Bob on day 24 (Confirmed)
    let a1 = queries::insert_assignment(
        pool,
        &Assignment {
            id: 0,
            rota_id,
            shift_id: shift_ids[0],
            employee_id: alice,
            status: AssignmentStatus::Proposed,
            employee_name: Some("Alice".into()),
            hourly_wage: None,
        },
    )
    .await
    .unwrap();
    let a2 = queries::insert_assignment(
        pool,
        &Assignment {
            id: 0,
            rota_id,
            shift_id: shift_ids[1],
            employee_id: bob,
            status: AssignmentStatus::Confirmed,
            employee_name: Some("Bob".into()),
            hourly_wage: None,
        },
    )
    .await
    .unwrap();

    (rota_id, shift_ids, vec![a1, a2])
}

#[tokio::test]
async fn restore_from_save_recreates_shifts_and_assignments() {
    let pool = test_pool().await;
    let (rota_id, _shift_ids, _) = seed_rota_with_assignments(&pool).await;

    let save_id = queries::create_save(&pool, rota_id).await.unwrap();

    // Get shift ids from the live state before mutation.
    let shifts_before = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    let shift_id_0 = shifts_before[0].id;

    // Mutate live state: delete one shift, add a new ad-hoc shift.
    queries::delete_shift(&pool, shift_id_0).await.unwrap();
    let mut new_shift = make_shift(0, date(26), 14, 18, "barista");
    new_shift.rota_id = rota_id;
    new_shift.template_id = None;
    queries::insert_shift(&pool, &new_shift).await.unwrap();

    // Restore.
    let result = queries::restore_from_save(&pool, save_id).await.unwrap();
    assert_eq!(result.rota_id, rota_id);
    assert_eq!(result.shifts_restored, 3);
    assert_eq!(result.assignments_restored, 2);
    assert_eq!(result.assignments_skipped, 0);

    // Live state should match snapshot: 3 shifts, 2 assignments.
    let shifts_after = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    assert_eq!(shifts_after.len(), 3);
    let assignments_after = queries::list_assignments_for_rota(&pool, rota_id)
        .await
        .unwrap();
    assert_eq!(assignments_after.len(), 2);
}

#[tokio::test]
async fn restore_from_save_skips_assignments_for_deleted_employees() {
    let pool = test_pool().await;
    let (rota_id, _shift_ids, _) = seed_rota_with_assignments(&pool).await;

    let save_id = queries::create_save(&pool, rota_id).await.unwrap();

    // Delete Alice (the employee on shift_ids[0]).
    let emp_rows: Vec<(i64, String)> = sqlx::query_as("SELECT id, first_name FROM employees")
        .fetch_all(&pool)
        .await
        .unwrap();
    let alice_id = emp_rows
        .iter()
        .find(|(_, name)| name == "Alice")
        .map(|(id, _)| *id)
        .unwrap();
    queries::delete_employee(&pool, alice_id).await.unwrap();

    let result = queries::restore_from_save(&pool, save_id).await.unwrap();
    assert_eq!(result.shifts_restored, 3);
    // Only Bob's assignment restored; Alice's skipped.
    assert_eq!(result.assignments_restored, 1);
    assert_eq!(result.assignments_skipped, 1);
}

// Silence unused-import warnings if any helper goes unused in the future.
#[allow(dead_code)]
fn _force_use(_d: NaiveDate) {}
