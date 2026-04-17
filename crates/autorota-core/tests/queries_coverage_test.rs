mod helpers;

use autorota_core::db::queries;
use autorota_core::models::assignment::AssignmentStatus;
use autorota_core::models::availability::AvailabilityState;
use autorota_core::testutil::*;
use chrono::{NaiveDate, Weekday};

// ─── Employee ───────────────────────────────────────────────

#[tokio::test]
async fn list_all_employees_includes_soft_deleted() {
    let pool = test_pool().await;
    let alice = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let bob = EmployeeBuilder::new("Bob")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();

    let ids = seed_employees(&pool, &[alice, bob]).await;

    // Soft-delete Bob
    queries::delete_employee(&pool, ids[1]).await.unwrap();

    // list_employees should exclude deleted
    let active = queries::list_employees(&pool).await.unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].first_name, "Alice");

    // list_all_employees should include deleted
    let all = queries::list_all_employees(&pool).await.unwrap();
    assert_eq!(all.len(), 2);
    let bob_row = all.iter().find(|e| e.first_name == "Bob").unwrap();
    assert!(bob_row.deleted);
}

#[tokio::test]
async fn list_all_employees_empty_db_returns_empty() {
    let pool = test_pool().await;
    let all = queries::list_all_employees(&pool).await.unwrap();
    assert!(all.is_empty());
}

#[tokio::test]
async fn update_employee_persists_changes() {
    let pool = test_pool().await;
    let emp = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let ids = seed_employees(&pool, &[emp]).await;
    let id = ids[0];

    // Fetch, modify, update
    let mut loaded = queries::get_employee(&pool, id).await.unwrap().unwrap();
    loaded.first_name = "Alicia".to_string();
    loaded.last_name = "Smith".to_string();
    loaded.roles = vec!["manager".to_string()];
    loaded.target_weekly_hours = 30.0;
    queries::update_employee(&pool, &loaded).await.unwrap();

    // Verify changes persisted
    let reloaded = queries::get_employee(&pool, id).await.unwrap().unwrap();
    assert_eq!(reloaded.first_name, "Alicia");
    assert_eq!(reloaded.last_name, "Smith");
    assert_eq!(reloaded.roles, vec!["manager".to_string()]);
    assert!((reloaded.target_weekly_hours - 30.0).abs() < f32::EPSILON);
}

// ─── Shift Templates ────────────────────────────────────────

#[tokio::test]
async fn list_all_shift_templates_includes_soft_deleted() {
    let pool = test_pool().await;
    let morning = ShiftTemplateBuilder::new("Morning")
        .weekdays(&[Weekday::Mon])
        .times(7, 12)
        .role("barista")
        .build();
    let evening = ShiftTemplateBuilder::new("Evening")
        .weekdays(&[Weekday::Mon])
        .times(17, 22)
        .role("barista")
        .build();

    let ids = seed_templates(&pool, &[morning, evening]).await;

    // Soft-delete evening
    queries::delete_shift_template(&pool, ids[1]).await.unwrap();

    // list_shift_templates excludes deleted
    let active = queries::list_shift_templates(&pool).await.unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].name, "Morning");

    // list_all_shift_templates includes deleted
    let all = queries::list_all_shift_templates(&pool).await.unwrap();
    assert_eq!(all.len(), 2);
    let evening_row = all.iter().find(|t| t.name == "Evening").unwrap();
    assert!(evening_row.deleted);
}

#[tokio::test]
async fn update_shift_template_persists_changes() {
    let pool = test_pool().await;
    let tmpl = ShiftTemplateBuilder::new("Morning")
        .weekdays(&[Weekday::Mon])
        .times(7, 12)
        .role("barista")
        .capacity(1, 2)
        .build();
    let ids = seed_templates(&pool, &[tmpl]).await;
    let id = ids[0];

    // Fetch all, find ours, modify, update
    let all = queries::list_all_shift_templates(&pool).await.unwrap();
    let mut loaded = all.into_iter().find(|t| t.id == id).unwrap();
    loaded.name = "Early Morning".to_string();
    loaded.start_time = time(6);
    loaded.end_time = time(11);
    loaded.required_role = "cashier".to_string();
    loaded.min_employees = 2;
    loaded.max_employees = 3;
    queries::update_shift_template(&pool, &loaded)
        .await
        .unwrap();

    let reloaded = queries::list_all_shift_templates(&pool).await.unwrap();
    let t = reloaded.into_iter().find(|t| t.id == id).unwrap();
    assert_eq!(t.name, "Early Morning");
    assert_eq!(t.start_time, time(6));
    assert_eq!(t.end_time, time(11));
    assert_eq!(t.required_role, "cashier");
    assert_eq!(t.min_employees, 2);
    assert_eq!(t.max_employees, 3);
}

#[tokio::test]
async fn delete_shift_template_soft_deletes() {
    let pool = test_pool().await;
    let tmpl = ShiftTemplateBuilder::new("Lunch")
        .weekdays(&[Weekday::Tue])
        .times(11, 15)
        .role("barista")
        .build();
    let ids = seed_templates(&pool, &[tmpl]).await;
    let id = ids[0];

    queries::delete_shift_template(&pool, id).await.unwrap();

    // Not in active list
    let active = queries::list_shift_templates(&pool).await.unwrap();
    assert!(active.is_empty());

    // Still in all list with deleted=true
    let all = queries::list_all_shift_templates(&pool).await.unwrap();
    assert_eq!(all.len(), 1);
    assert!(all[0].deleted);
}

// ─── Rotas ──────────────────────────────────────────────────

#[tokio::test]
async fn get_rotas_in_range_returns_correct_weeks() {
    let pool = test_pool().await;

    // Create rotas for 3 consecutive Mondays
    let week1 = date(23); // 2026-03-23 Mon
    let week2 = date(30); // 2026-03-30 Mon
    let week3 = NaiveDate::from_ymd_opt(2026, 4, 6).unwrap(); // next Mon

    let _id1 = queries::insert_rota(&pool, week1).await.unwrap();
    let _id2 = queries::insert_rota(&pool, week2).await.unwrap();
    let _id3 = queries::insert_rota(&pool, week3).await.unwrap();

    // Query range that covers week1 and week2 but not week3
    let rotas = queries::get_rotas_in_range(&pool, week1, date(29))
        .await
        .unwrap();
    assert_eq!(rotas.len(), 1); // only week1's Monday falls in [23, 29]
    assert_eq!(rotas[0].week_start, week1);

    // Query range covering all three
    let rotas = queries::get_rotas_in_range(&pool, week1, week3)
        .await
        .unwrap();
    assert_eq!(rotas.len(), 3);
}

#[tokio::test]
async fn get_rotas_in_range_empty_returns_empty() {
    let pool = test_pool().await;
    let rotas = queries::get_rotas_in_range(&pool, date(23), date(29))
        .await
        .unwrap();
    assert!(rotas.is_empty());
}

// ─── Shifts ─────────────────────────────────────────────────

#[tokio::test]
async fn delete_shift_removes_and_creates_tombstone() {
    let pool = test_pool().await;
    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();

    let shift = ShiftBuilder::new()
        .rota(rota_id)
        .no_template()
        .date(date(23))
        .times(7, 12)
        .role("barista")
        .build();
    let shift_id = queries::insert_shift(&pool, &shift).await.unwrap();

    // Verify shift exists
    let shifts = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    assert_eq!(shifts.len(), 1);

    // Delete it
    queries::delete_shift(&pool, shift_id).await.unwrap();

    // Shift is gone
    let shifts = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    assert!(shifts.is_empty());

    // Tombstone exists
    let tombstones = queries::get_pending_tombstones(&pool).await.unwrap();
    assert!(
        tombstones
            .iter()
            .any(|t| t.table_name == "shifts" && t.record_id == shift_id)
    );
}

// ─── Assignments ────────────────────────────────────────────

/// Helper: insert a rota + shift + assignment and return (rota_id, shift_id, assignment_id).
async fn setup_assignment(pool: &sqlx::SqlitePool, status: AssignmentStatus) -> (i64, i64, i64) {
    let rota_id = queries::insert_rota(pool, week_start()).await.unwrap();
    let shift = ShiftBuilder::new()
        .rota(rota_id)
        .no_template()
        .date(date(23))
        .times(7, 12)
        .role("barista")
        .build();
    let shift_id = queries::insert_shift(pool, &shift).await.unwrap();

    let emp = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let emp_ids = seed_employees(pool, &[emp]).await;

    let assignment = AssignmentBuilder::new(shift_id, emp_ids[0])
        .rota(rota_id)
        .status(status)
        .name("Alice")
        .build();
    let aid = queries::insert_assignment(pool, &assignment).await.unwrap();
    (rota_id, shift_id, aid)
}

#[tokio::test]
async fn delete_proposed_assignments_keeps_confirmed() {
    let pool = test_pool().await;
    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();

    let shift = ShiftBuilder::new()
        .rota(rota_id)
        .no_template()
        .date(date(23))
        .times(7, 12)
        .role("barista")
        .build();
    let shift_id = queries::insert_shift(&pool, &shift).await.unwrap();

    let emp = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let emp2 = EmployeeBuilder::new("Bob")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let emp_ids = seed_employees(&pool, &[emp, emp2]).await;

    // Insert one Proposed and one Confirmed
    let proposed = AssignmentBuilder::new(shift_id, emp_ids[0])
        .rota(rota_id)
        .name("Alice")
        .build(); // default is Proposed
    let confirmed = AssignmentBuilder::new(shift_id, emp_ids[1])
        .rota(rota_id)
        .confirmed()
        .name("Bob")
        .build();

    let proposed_id = queries::insert_assignment(&pool, &proposed).await.unwrap();
    let _confirmed_id = queries::insert_assignment(&pool, &confirmed).await.unwrap();

    queries::delete_proposed_assignments(&pool, rota_id)
        .await
        .unwrap();

    let remaining = queries::list_assignments_for_rota(&pool, rota_id)
        .await
        .unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].status, AssignmentStatus::Confirmed);

    // Tombstone created for proposed
    let tombstones = queries::get_pending_tombstones(&pool).await.unwrap();
    assert!(
        tombstones
            .iter()
            .any(|t| t.table_name == "assignments" && t.record_id == proposed_id)
    );
}

#[tokio::test]
async fn delete_proposed_assignments_noop_when_none_proposed() {
    let pool = test_pool().await;
    let rota_id = queries::insert_rota(&pool, week_start()).await.unwrap();

    let shift = ShiftBuilder::new()
        .rota(rota_id)
        .no_template()
        .date(date(23))
        .times(7, 12)
        .role("barista")
        .build();
    let shift_id = queries::insert_shift(&pool, &shift).await.unwrap();

    let emp = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let emp_ids = seed_employees(&pool, &[emp]).await;

    let confirmed = AssignmentBuilder::new(shift_id, emp_ids[0])
        .rota(rota_id)
        .confirmed()
        .name("Alice")
        .build();
    queries::insert_assignment(&pool, &confirmed).await.unwrap();

    // No-op: no proposed assignments to delete
    queries::delete_proposed_assignments(&pool, rota_id)
        .await
        .unwrap();

    let remaining = queries::list_assignments_for_rota(&pool, rota_id)
        .await
        .unwrap();
    assert_eq!(remaining.len(), 1);
}

#[tokio::test]
async fn update_assignment_shift_moves_to_new_shift() {
    let pool = test_pool().await;
    let (rota_id, shift_id_1, aid) = setup_assignment(&pool, AssignmentStatus::Proposed).await;

    // Create a second shift
    let shift2 = ShiftBuilder::new()
        .rota(rota_id)
        .no_template()
        .date(date(24))
        .times(12, 17)
        .role("barista")
        .build();
    let shift_id_2 = queries::insert_shift(&pool, &shift2).await.unwrap();

    queries::update_assignment_shift(&pool, aid, shift_id_2)
        .await
        .unwrap();

    let assignments = queries::list_assignments_for_rota(&pool, rota_id)
        .await
        .unwrap();
    assert_eq!(assignments.len(), 1);
    assert_eq!(assignments[0].shift_id, shift_id_2);
    assert_ne!(assignments[0].shift_id, shift_id_1);
}

#[tokio::test]
async fn delete_assignment_removes_and_creates_tombstone() {
    let pool = test_pool().await;
    let (rota_id, _shift_id, aid) = setup_assignment(&pool, AssignmentStatus::Proposed).await;

    queries::delete_assignment(&pool, aid).await.unwrap();

    let assignments = queries::list_assignments_for_rota(&pool, rota_id)
        .await
        .unwrap();
    assert!(assignments.is_empty());

    let tombstones = queries::get_pending_tombstones(&pool).await.unwrap();
    assert!(
        tombstones
            .iter()
            .any(|t| t.table_name == "assignments" && t.record_id == aid)
    );
}

// ─── Shift Template Overrides ───────────────────────────────

#[tokio::test]
async fn list_all_shift_template_overrides_returns_all() {
    let pool = test_pool().await;
    let tmpl1 = ShiftTemplateBuilder::new("Morning")
        .weekdays(&[Weekday::Mon])
        .times(7, 12)
        .role("barista")
        .build();
    let tmpl2 = ShiftTemplateBuilder::new("Evening")
        .weekdays(&[Weekday::Mon])
        .times(17, 22)
        .role("barista")
        .build();
    let ids = seed_templates(&pool, &[tmpl1, tmpl2]).await;

    let ovr1 = ShiftTemplateOverrideBuilder::new(ids[0], date(23))
        .cancelled()
        .build();
    let ovr2 = ShiftTemplateOverrideBuilder::new(ids[1], date(23))
        .times(18, 23)
        .build();

    queries::upsert_shift_template_override(&pool, &ovr1)
        .await
        .unwrap();
    queries::upsert_shift_template_override(&pool, &ovr2)
        .await
        .unwrap();

    let all = queries::list_all_shift_template_overrides(&pool)
        .await
        .unwrap();
    assert_eq!(all.len(), 2);

    let cancelled_one = all.iter().find(|o| o.template_id == ids[0]).unwrap();
    assert!(cancelled_one.cancelled);

    let time_one = all.iter().find(|o| o.template_id == ids[1]).unwrap();
    assert!(!time_one.cancelled);
    assert_eq!(time_one.start_time, Some(time(18)));
    assert_eq!(time_one.end_time, Some(time(23)));
}

// ─── Shift History ──────────────────────────────────────────

/// Helper: set up a rota with shifts and assignments for history tests.
/// Returns (rota_id, shift_ids, employee_ids).
async fn setup_history(pool: &sqlx::SqlitePool) -> (i64, Vec<i64>, Vec<i64>) {
    let rota_id = queries::insert_rota(pool, week_start()).await.unwrap();

    let emp = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let emp_ids = seed_employees(pool, &[emp]).await;

    // Shifts on Mon(23) and Wed(25)
    let s1 = ShiftBuilder::new()
        .rota(rota_id)
        .no_template()
        .date(date(23))
        .times(7, 12)
        .role("barista")
        .build();
    let s2 = ShiftBuilder::new()
        .rota(rota_id)
        .no_template()
        .date(date(25))
        .times(7, 12)
        .role("barista")
        .build();
    let sid1 = queries::insert_shift(pool, &s1).await.unwrap();
    let sid2 = queries::insert_shift(pool, &s2).await.unwrap();

    let a1 = AssignmentBuilder::new(sid1, emp_ids[0])
        .rota(rota_id)
        .name("Alice")
        .build();
    let a2 = AssignmentBuilder::new(sid2, emp_ids[0])
        .rota(rota_id)
        .name("Alice")
        .build();
    queries::insert_assignment(pool, &a1).await.unwrap();
    queries::insert_assignment(pool, &a2).await.unwrap();

    (rota_id, vec![sid1, sid2], emp_ids)
}

#[tokio::test]
async fn list_all_shift_history_no_filter_returns_all() {
    let pool = test_pool().await;
    let (_rota_id, _shift_ids, _emp_ids) = setup_history(&pool).await;

    let history = queries::list_all_shift_history(&pool, None, None)
        .await
        .unwrap();
    assert_eq!(history.len(), 2);
}

#[tokio::test]
async fn list_all_shift_history_empty_db_returns_empty() {
    let pool = test_pool().await;
    let history = queries::list_all_shift_history(&pool, None, None)
        .await
        .unwrap();
    assert!(history.is_empty());
}

#[tokio::test]
async fn list_all_shift_history_date_range_filter() {
    let pool = test_pool().await;
    let (_rota_id, _shift_ids, _emp_ids) = setup_history(&pool).await;

    // Only Mon (23)
    let history = queries::list_all_shift_history(&pool, Some(date(23)), Some(date(24)))
        .await
        .unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].date, date(23));
}

#[tokio::test]
async fn list_all_shift_history_start_only_filter() {
    let pool = test_pool().await;
    let (_rota_id, _shift_ids, _emp_ids) = setup_history(&pool).await;

    // From Wed(25) onwards
    let history = queries::list_all_shift_history(&pool, Some(date(25)), None)
        .await
        .unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].date, date(25));
}

// ─── Sync ───────────────────────────────────────────────────

#[tokio::test]
async fn sync_metadata_roundtrip_and_upsert() {
    let pool = test_pool().await;

    // Missing key returns None
    let val = queries::get_sync_metadata(&pool, "my_key").await.unwrap();
    assert!(val.is_none());

    // Set and retrieve
    queries::set_sync_metadata(&pool, "my_key", "hello")
        .await
        .unwrap();
    let val = queries::get_sync_metadata(&pool, "my_key").await.unwrap();
    assert_eq!(val.as_deref(), Some("hello"));

    // Upsert (overwrite)
    queries::set_sync_metadata(&pool, "my_key", "world")
        .await
        .unwrap();
    let val = queries::get_sync_metadata(&pool, "my_key").await.unwrap();
    assert_eq!(val.as_deref(), Some("world"));
}

#[tokio::test]
async fn insert_tombstone_single_appears_in_pending() {
    let pool = test_pool().await;

    let ts_id = queries::insert_tombstone(&pool, "employees", 42)
        .await
        .unwrap();
    assert!(ts_id > 0);

    let pending = queries::get_pending_tombstones(&pool).await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].table_name, "employees");
    assert_eq!(pending[0].record_id, 42);
}

#[tokio::test]
async fn insert_tombstones_batch_all_present() {
    let pool = test_pool().await;

    let ids = vec![10, 20, 30];
    queries::insert_tombstones(&pool, "shifts", &ids)
        .await
        .unwrap();

    let pending = queries::get_pending_tombstones(&pool).await.unwrap();
    assert_eq!(pending.len(), 3);
    let record_ids: Vec<i64> = pending.iter().map(|t| t.record_id).collect();
    assert!(record_ids.contains(&10));
    assert!(record_ids.contains(&20));
    assert!(record_ids.contains(&30));
    assert!(pending.iter().all(|t| t.table_name == "shifts"));
}

#[tokio::test]
async fn insert_tombstones_empty_is_noop() {
    let pool = test_pool().await;

    queries::insert_tombstones(&pool, "shifts", &[])
        .await
        .unwrap();

    let pending = queries::get_pending_tombstones(&pool).await.unwrap();
    assert!(pending.is_empty());
}

#[tokio::test]
async fn get_base_snapshots_after_mark_synced() {
    let pool = test_pool().await;

    // Insert an employee so there's a row to mark synced
    let emp = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let ids = seed_employees(&pool, &[emp]).await;
    let emp_id = ids[0];

    // Mark as synced with a snapshot
    let snapshot_json = r#"{"first_name":"Alice"}"#;
    queries::mark_records_synced(&pool, "employees", &[emp_id], &[snapshot_json.to_string()])
        .await
        .unwrap();

    // Retrieve base snapshots
    let snapshots = queries::get_base_snapshots(&pool, "employees", &[emp_id])
        .await
        .unwrap();
    assert_eq!(snapshots.len(), 1);
    assert_eq!(snapshots[0].record_id, emp_id);
    assert_eq!(snapshots[0].snapshot, snapshot_json);
}

#[tokio::test]
async fn get_base_snapshots_empty_ids_returns_empty() {
    let pool = test_pool().await;

    let snapshots = queries::get_base_snapshots(&pool, "employees", &[])
        .await
        .unwrap();
    assert!(snapshots.is_empty());
}

#[tokio::test]
async fn get_base_snapshots_non_synced_rows_excluded() {
    let pool = test_pool().await;

    // Insert an employee but don't mark synced
    let emp = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let ids = seed_employees(&pool, &[emp]).await;

    // No snapshot set, so should return empty
    let snapshots = queries::get_base_snapshots(&pool, "employees", &[ids[0]])
        .await
        .unwrap();
    assert!(snapshots.is_empty());
}
