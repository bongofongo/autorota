mod helpers;

use autorota_core::db::queries;
use autorota_core::models::assignment::AssignmentStatus;
use autorota_core::models::availability::AvailabilityState;
use autorota_core::scheduler::{SchedulerError, schedule};
use autorota_core::testutil::*;
use chrono::Weekday;

// ─── Helper ────────────────────────────────────────────────────────────────

/// Standard setup: seed one role, one employee, one template, create rota,
/// materialise shifts, and return (pool, rota_id).
async fn setup_single(role: &str, emp_avail: AvailabilityState) -> (sqlx::SqlitePool, i64) {
    let pool = test_pool().await;

    seed_roles(&pool, &[role]).await;

    let emp = EmployeeBuilder::new("Alice")
        .role(role)
        .available(emp_avail)
        .build();
    seed_employees(&pool, &[emp]).await;

    let tmpl = ShiftTemplateBuilder::new("Morning")
        .weekdays(&[Weekday::Mon])
        .times(7, 12)
        .role(role)
        .capacity(1, 1)
        .build();
    seed_templates(&pool, &[tmpl]).await;

    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();
    queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();

    (pool, rota_id)
}

// ─── Happy-path tests ──────────────────────────────────────────────────────

#[tokio::test]
async fn schedule_assigns_employee_to_shift() {
    let (pool, rota_id) = setup_single("barista", AvailabilityState::Yes).await;

    let result = schedule(&pool, rota_id).await.unwrap();

    assert_eq!(result.assignments.len(), 1);
    assert_eq!(result.assignments[0].status, AssignmentStatus::Proposed);
    assert!(result.warnings.is_empty());

    // Verify persisted in DB
    let db_assignments = queries::list_assignments_for_rota(&pool, rota_id)
        .await
        .unwrap();
    assert_eq!(db_assignments.len(), 1);
}

#[tokio::test]
async fn schedule_multiple_employees_multiple_shifts() {
    let pool = test_pool().await;

    seed_roles(&pool, &["barista"]).await;

    let employees = vec![
        EmployeeBuilder::new("Alice")
            .role("barista")
            .available(AvailabilityState::Yes)
            .build(),
        EmployeeBuilder::new("Bob")
            .role("barista")
            .available(AvailabilityState::Yes)
            .build(),
        EmployeeBuilder::new("Carol")
            .role("barista")
            .available(AvailabilityState::Yes)
            .build(),
    ];
    seed_employees(&pool, &employees).await;

    let templates = vec![
        ShiftTemplateBuilder::new("Mon Morning")
            .weekdays(&[Weekday::Mon])
            .times(7, 12)
            .role("barista")
            .capacity(1, 1)
            .build(),
        ShiftTemplateBuilder::new("Tue Morning")
            .weekdays(&[Weekday::Tue])
            .times(7, 12)
            .role("barista")
            .capacity(1, 1)
            .build(),
        ShiftTemplateBuilder::new("Wed Morning")
            .weekdays(&[Weekday::Wed])
            .times(7, 12)
            .role("barista")
            .capacity(1, 1)
            .build(),
    ];
    seed_templates(&pool, &templates).await;

    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();
    queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();

    let result = schedule(&pool, rota_id).await.unwrap();

    assert_eq!(result.assignments.len(), 3);
    assert!(result.warnings.is_empty());
}

#[tokio::test]
async fn schedule_preserves_existing_confirmed_assignments() {
    let pool = test_pool().await;

    seed_roles(&pool, &["barista"]).await;

    let employees = vec![
        EmployeeBuilder::new("Alice")
            .role("barista")
            .available(AvailabilityState::Yes)
            .build(),
        EmployeeBuilder::new("Bob")
            .role("barista")
            .available(AvailabilityState::Yes)
            .build(),
    ];
    let emp_ids = seed_employees(&pool, &employees).await;

    let templates = vec![
        ShiftTemplateBuilder::new("Mon Morning")
            .weekdays(&[Weekday::Mon])
            .times(7, 12)
            .role("barista")
            .capacity(1, 1)
            .build(),
        ShiftTemplateBuilder::new("Tue Morning")
            .weekdays(&[Weekday::Tue])
            .times(7, 12)
            .role("barista")
            .capacity(1, 1)
            .build(),
    ];
    seed_templates(&pool, &templates).await;

    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();
    queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();

    // Get the materialised shifts so we can pick one for the confirmed assignment
    let shifts = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    assert_eq!(shifts.len(), 2);

    // Insert a confirmed assignment for Alice on the first shift
    let confirmed = AssignmentBuilder::new(shifts[0].id, emp_ids[0])
        .rota(rota_id)
        .confirmed()
        .name("Alice")
        .build();
    queries::insert_assignment(&pool, &confirmed).await.unwrap();

    let result = schedule(&pool, rota_id).await.unwrap();

    // The scheduler's pure function only pre-assigns Overridden status in pass 1.
    // Confirmed assignments are not consumed by the scheduler — both shifts get
    // Proposed assignments. The confirmed assignment remains in the DB untouched.
    let proposed = result
        .assignments
        .iter()
        .filter(|a| a.status == AssignmentStatus::Proposed)
        .count();
    assert_eq!(proposed, 2, "both shifts should get proposed assignments");

    // Verify the original confirmed assignment is still in the DB
    let db_assignments = queries::list_assignments_for_rota(&pool, rota_id)
        .await
        .unwrap();
    let db_confirmed = db_assignments
        .iter()
        .filter(|a| a.status == AssignmentStatus::Confirmed)
        .count();
    assert_eq!(db_confirmed, 1, "confirmed assignment should persist in DB");

    // Total DB assignments: 1 confirmed (pre-existing) + 2 proposed (from scheduler)
    assert_eq!(db_assignments.len(), 3);
}

#[tokio::test]
async fn schedule_with_availability_overrides() {
    let pool = test_pool().await;

    seed_roles(&pool, &["barista"]).await;

    let emp = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let emp_ids = seed_employees(&pool, &[emp]).await;

    // Template on Monday only
    let tmpl = ShiftTemplateBuilder::new("Mon Morning")
        .weekdays(&[Weekday::Mon])
        .times(7, 12)
        .role("barista")
        .capacity(1, 1)
        .build();
    seed_templates(&pool, &[tmpl]).await;

    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();
    queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();

    // Override Alice's availability to No on Monday (date(23))
    let ovr = EmployeeOverrideBuilder::new(emp_ids[0], date(23))
        .available_range(0, 24, AvailabilityState::No)
        .build();
    queries::upsert_employee_availability_override(&pool, &ovr)
        .await
        .unwrap();

    let result = schedule(&pool, rota_id).await.unwrap();

    // Alice should NOT be assigned because her override says No
    let proposed = result
        .assignments
        .iter()
        .filter(|a| a.status == AssignmentStatus::Proposed)
        .count();
    assert_eq!(proposed, 0);
    // Should produce a shortfall warning
    assert!(!result.warnings.is_empty());
}

#[tokio::test]
async fn schedule_persists_assignments_to_db() {
    let (pool, rota_id) = setup_single("barista", AvailabilityState::Yes).await;

    let _result = schedule(&pool, rota_id).await.unwrap();

    let db_assignments = queries::list_assignments_for_rota(&pool, rota_id)
        .await
        .unwrap();
    assert_eq!(db_assignments.len(), 1);
    assert_eq!(db_assignments[0].status, AssignmentStatus::Proposed);
    assert_eq!(db_assignments[0].rota_id, rota_id);
}

// ─── Error-case tests ──────────────────────────────────────────────────────

#[tokio::test]
async fn schedule_rota_not_found() {
    let pool = test_pool().await;

    let result = schedule(&pool, 99999).await;

    assert!(result.is_err());
    match result.unwrap_err() {
        SchedulerError::RotaNotFound(id) => assert_eq!(id, 99999),
        other => panic!("expected RotaNotFound, got: {other}"),
    }
}

#[tokio::test]
async fn schedule_finalized_rota_rejected() {
    let pool = test_pool().await;

    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();
    queries::finalize_rota(&pool, rota_id).await.unwrap();

    let result = schedule(&pool, rota_id).await;

    assert!(result.is_err());
    match result.unwrap_err() {
        SchedulerError::AlreadyFinalized(id) => assert_eq!(id, rota_id),
        other => panic!("expected AlreadyFinalized, got: {other}"),
    }
}

// ─── Edge-case tests ───────────────────────────────────────────────────────

#[tokio::test]
async fn schedule_no_shifts_no_assignments() {
    let pool = test_pool().await;

    // Create a rota but don't seed any templates — no shifts to materialise
    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();
    queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();

    let result = schedule(&pool, rota_id).await.unwrap();

    assert!(result.assignments.is_empty());
    assert!(result.warnings.is_empty());
}

#[tokio::test]
async fn schedule_no_employees_produces_warnings() {
    let pool = test_pool().await;

    seed_roles(&pool, &["barista"]).await;

    // Seed a template but no employees
    let tmpl = ShiftTemplateBuilder::new("Morning")
        .weekdays(&[Weekday::Mon])
        .times(7, 12)
        .role("barista")
        .capacity(1, 1)
        .build();
    seed_templates(&pool, &[tmpl]).await;

    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();
    queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();

    let result = schedule(&pool, rota_id).await.unwrap();

    assert!(result.assignments.is_empty());
    assert!(
        !result.warnings.is_empty(),
        "should produce shortfall warnings when no employees exist"
    );
}

#[tokio::test]
async fn schedule_respects_role_matching() {
    let pool = test_pool().await;

    seed_roles(&pool, &["barista", "cashier"]).await;

    // Employee has "cashier" role
    let emp = EmployeeBuilder::new("Alice")
        .role("cashier")
        .available(AvailabilityState::Yes)
        .build();
    seed_employees(&pool, &[emp]).await;

    // Shift requires "barista" role
    let tmpl = ShiftTemplateBuilder::new("Morning")
        .weekdays(&[Weekday::Mon])
        .times(7, 12)
        .role("barista")
        .capacity(1, 1)
        .build();
    seed_templates(&pool, &[tmpl]).await;

    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();
    queries::materialise_shifts(&pool, rota_id, week_start())
        .await
        .unwrap();

    let result = schedule(&pool, rota_id).await.unwrap();

    assert!(
        result.assignments.is_empty()
            || result
                .assignments
                .iter()
                .all(|a| a.status != AssignmentStatus::Proposed),
        "cashier employee should not be assigned to barista shift"
    );
    assert!(
        !result.warnings.is_empty(),
        "should produce shortfall warning for role mismatch"
    );
}
