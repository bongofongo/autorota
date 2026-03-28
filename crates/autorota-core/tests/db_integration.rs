mod helpers;

use autorota_core::db;
use autorota_core::db::queries;
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::{Availability, AvailabilityState};
use autorota_core::models::employee::Employee;
use autorota_core::models::shift::{Shift, ShiftTemplate};
use chrono::{NaiveDate, NaiveTime, Weekday};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use std::str::FromStr;

use helpers::test_pool;

/// The OLD schema (before weekdays migration) — uses `weekday` singular column
/// and no ON DELETE CASCADE.
const OLD_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS employees (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    roles TEXT NOT NULL DEFAULT '[]',
    max_daily_hours REAL NOT NULL DEFAULT 8.0,
    max_weekly_hours REAL NOT NULL DEFAULT 40.0,
    default_availability TEXT NOT NULL DEFAULT '{}',
    availability TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS shift_templates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    weekday TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    required_role TEXT NOT NULL,
    min_employees INTEGER NOT NULL DEFAULT 1,
    max_employees INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS rotas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    week_start TEXT NOT NULL,
    finalized INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS shifts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id INTEGER NOT NULL REFERENCES shift_templates(id),
    rota_id INTEGER NOT NULL REFERENCES rotas(id),
    date TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    required_role TEXT NOT NULL,
    min_employees INTEGER NOT NULL DEFAULT 1,
    max_employees INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS assignments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rota_id INTEGER NOT NULL REFERENCES rotas(id),
    shift_id INTEGER NOT NULL REFERENCES shifts(id),
    employee_id INTEGER NOT NULL REFERENCES employees(id),
    status TEXT NOT NULL DEFAULT 'Proposed' CHECK(status IN ('Proposed', 'Confirmed', 'Overridden'))
);
"#;

/// Create an in-memory database with the OLD schema and seed it with data
/// that has foreign key relationships (shift_templates -> shifts -> assignments).
/// Then call db::connect on the same database to trigger migration 002.
/// This reproduces the FK constraint error the user sees on app startup.
async fn create_old_schema_pool() -> sqlx::SqlitePool {
    let opts = SqliteConnectOptions::from_str("sqlite::memory:")
        .unwrap()
        .shared_cache(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(opts)
        .await
        .unwrap();

    sqlx::query("PRAGMA foreign_keys=ON;")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::raw_sql(OLD_SCHEMA).execute(&pool).await.unwrap();

    // Insert seed data with FK relationships
    sqlx::query("INSERT INTO employees (name, roles) VALUES ('Alice', '[\"barista\"]')")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO shift_templates (name, weekday, start_time, end_time, required_role)
         VALUES ('Morning', 'Mon', '07:00:00', '12:00:00', 'barista')",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("INSERT INTO rotas (week_start) VALUES ('2026-03-23')")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO shifts (template_id, rota_id, date, start_time, end_time, required_role)
         VALUES (1, 1, '2026-03-23', '07:00:00', '12:00:00', 'barista')",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO assignments (rota_id, shift_id, employee_id, status)
         VALUES (1, 1, 1, 'Proposed')",
    )
    .execute(&pool)
    .await
    .unwrap();

    pool
}

#[tokio::test]
async fn migration_from_old_schema_with_data() {
    // Build an in-memory DB with the old schema and populated data
    let old_pool = create_old_schema_pool().await;

    // Verify old schema has 'weekday' column
    let has_weekday: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('shift_templates') WHERE name = 'weekday'",
    )
    .fetch_one(&old_pool)
    .await
    .unwrap();
    assert!(has_weekday, "old schema should have 'weekday' column");

    // Now run db::connect which triggers migrations — this is what fails on app startup
    // We can't reuse the in-memory pool directly since connect() creates its own,
    // so we use a temp file instead.
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("test_migrate.db");
    let url = format!("sqlite:{}", db_path.display());

    // Create the file-based DB with old schema + data
    {
        let opts = SqliteConnectOptions::from_str(&url)
            .unwrap()
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(opts)
            .await
            .unwrap();
        sqlx::query("PRAGMA foreign_keys=ON;")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::raw_sql(OLD_SCHEMA).execute(&pool).await.unwrap();

        // Seed data
        sqlx::query("INSERT INTO employees (name, roles) VALUES ('Alice', '[\"barista\"]')")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO shift_templates (name, weekday, start_time, end_time, required_role)
             VALUES ('Morning', 'Mon', '07:00:00', '12:00:00', 'barista')",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO rotas (week_start) VALUES ('2026-03-23')")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO shifts (template_id, rota_id, date, start_time, end_time, required_role)
             VALUES (1, 1, '2026-03-23', '07:00:00', '12:00:00', 'barista')",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO assignments (rota_id, shift_id, employee_id, status)
             VALUES (1, 1, 1, 'Proposed')",
        )
        .execute(&pool)
        .await
        .unwrap();

        pool.close().await;
    }

    // Now connect via db::connect — this must not fail with FK constraint error
    let pool = db::connect(&url)
        .await
        .expect("db::connect should succeed on old-schema DB with existing data (migration 002)");

    // Verify migration worked: 'weekdays' column should exist, 'weekday' should not
    let has_weekdays: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('shift_templates') WHERE name = 'weekdays'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(
        has_weekdays,
        "migrated schema should have 'weekdays' column"
    );

    let still_has_weekday: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('shift_templates') WHERE name = 'weekday'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(
        !still_has_weekday,
        "migrated schema should not have old 'weekday' column"
    );

    // Verify data survived the migration
    let templates = queries::list_shift_templates(&pool).await.unwrap();
    assert_eq!(templates.len(), 1);
    assert_eq!(templates[0].name, "Morning");
    assert_eq!(templates[0].weekdays, vec![Weekday::Mon]);

    let employees = queries::list_employees(&pool).await.unwrap();
    assert_eq!(employees.len(), 1);
    assert_eq!(employees[0].first_name, "Alice");

    pool.close().await;
    drop(dir);
}

#[tokio::test]
async fn employee_crud() {
    let pool = test_pool().await;

    let mut avail = Availability::default();
    avail.set(Weekday::Mon, 8, AvailabilityState::Yes);
    avail.set(Weekday::Mon, 9, AvailabilityState::Maybe);
    avail.set(Weekday::Tue, 10, AvailabilityState::No);

    let emp = Employee {
        id: 0,
        first_name: "Alice".to_string(),
        last_name: "Smith".to_string(),
        nickname: None,
        roles: vec!["barista".to_string(), "cashier".to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 40.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: avail.clone(),
        availability: avail,
        deleted: false,
    };

    let id = queries::insert_employee(&pool, &emp).await.unwrap();
    assert!(id > 0);

    let fetched = queries::get_employee(&pool, id).await.unwrap().unwrap();
    assert_eq!(fetched.first_name, "Alice");
    assert_eq!(fetched.last_name, "Smith");
    assert_eq!(fetched.display_name(), "Alice Smith");
    assert_eq!(fetched.roles, vec!["barista", "cashier"]);
    assert_eq!(
        fetched.default_availability.get(Weekday::Mon, 8),
        AvailabilityState::Yes
    );
    assert_eq!(
        fetched.default_availability.get(Weekday::Mon, 9),
        AvailabilityState::Maybe
    );
    assert_eq!(
        fetched.default_availability.get(Weekday::Tue, 10),
        AvailabilityState::No
    );

    let all = queries::list_employees(&pool).await.unwrap();
    assert_eq!(all.len(), 1);

    queries::delete_employee(&pool, id).await.unwrap();
    // Soft-delete: get_employee still returns the row, but with deleted=true
    let soft_deleted = queries::get_employee(&pool, id).await.unwrap().unwrap();
    assert!(soft_deleted.deleted);
    // list_employees filters out soft-deleted
    let active = queries::list_employees(&pool).await.unwrap();
    assert!(active.is_empty());
}

#[tokio::test]
async fn shift_template_crud() {
    let pool = test_pool().await;

    let tmpl = ShiftTemplate {
        id: 0,
        name: "Morning Barista".to_string(),
        weekdays: vec![Weekday::Mon],
        start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 2,
        deleted: false,
    };

    let id = queries::insert_shift_template(&pool, &tmpl).await.unwrap();
    assert!(id > 0);

    let all = queries::list_shift_templates(&pool).await.unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].name, "Morning Barista");
    assert_eq!(all[0].weekdays, vec![Weekday::Mon]);
}

#[tokio::test]
async fn full_scheduling_flow() {
    let pool = test_pool().await;

    // Create employee
    let emp = Employee {
        id: 0,
        first_name: "Bob".to_string(),
        last_name: String::new(),
        nickname: None,
        roles: vec!["barista".to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 40.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: Availability::default(),
        availability: Availability::default(),
        deleted: false,
    };
    let emp_id = queries::insert_employee(&pool, &emp).await.unwrap();

    // Create shift template
    let tmpl = ShiftTemplate {
        id: 0,
        name: "Opener".to_string(),
        weekdays: vec![Weekday::Mon],
        start_time: NaiveTime::from_hms_opt(6, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
        deleted: false,
    };
    let tmpl_id = queries::insert_shift_template(&pool, &tmpl).await.unwrap();

    // Create rota for a week
    let week_start = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
    let rota_id = queries::insert_rota(&pool, week_start).await.unwrap();

    // Create a concrete shift from the template
    let shift = Shift {
        id: 0,
        template_id: Some(tmpl_id),
        rota_id,
        date: week_start,
        start_time: NaiveTime::from_hms_opt(6, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
    };
    let shift_id = queries::insert_shift(&pool, &shift).await.unwrap();

    // Assign employee to shift
    let assignment = Assignment {
        id: 0,
        rota_id,
        shift_id,
        employee_id: emp_id,
        status: AssignmentStatus::Proposed,
        employee_name: Some("Bob".to_string()),
    };
    let assign_id = queries::insert_assignment(&pool, &assignment)
        .await
        .unwrap();

    // Confirm the assignment
    queries::update_assignment_status(&pool, assign_id, AssignmentStatus::Confirmed)
        .await
        .unwrap();

    // Finalize the rota
    queries::finalize_rota(&pool, rota_id).await.unwrap();

    // Fetch the rota and verify everything is there
    let rota = queries::get_rota(&pool, rota_id).await.unwrap().unwrap();
    assert!(rota.finalized);
    assert_eq!(rota.week_start, week_start);
    assert_eq!(rota.assignments.len(), 1);
    assert_eq!(rota.assignments[0].status, AssignmentStatus::Confirmed);

    // Also test lookup by week
    let by_week = queries::get_rota_by_week(&pool, week_start)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(by_week.id, rota_id);
}

// ─── Role tests ─────────────────────────────────────────────

#[tokio::test]
async fn role_crud() {
    let pool = test_pool().await;

    // Insert roles
    let id1 = queries::insert_role(&pool, "Barista").await.unwrap();
    let id2 = queries::insert_role(&pool, "Cashier").await.unwrap();
    assert!(id1 > 0);
    assert!(id2 > 0);

    // List roles
    let all = queries::list_roles(&pool).await.unwrap();
    assert_eq!(all.len(), 2);
    // Sorted by name: Barista, Cashier
    assert_eq!(all[0].name, "Barista");
    assert_eq!(all[1].name, "Cashier");

    // Delete a role that's not in use
    queries::delete_role(&pool, id2).await.unwrap();
    let all = queries::list_roles(&pool).await.unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].name, "Barista");
}

#[tokio::test]
async fn role_rename_cascades() {
    let pool = test_pool().await;

    // Create a role
    let role_id = queries::insert_role(&pool, "Barista").await.unwrap();

    // Create an employee with that role
    let emp = Employee {
        id: 0,
        first_name: "Alice".to_string(),
        last_name: String::new(),
        nickname: None,
        roles: vec!["Barista".to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 30.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: Availability::default(),
        availability: Availability::default(),
        deleted: false,
    };
    queries::insert_employee(&pool, &emp).await.unwrap();

    // Create a shift template with that role
    let tmpl = ShiftTemplate {
        id: 0,
        name: "Morning".to_string(),
        weekdays: vec![Weekday::Mon],
        start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "Barista".to_string(),
        min_employees: 1,
        max_employees: 1,
        deleted: false,
    };
    queries::insert_shift_template(&pool, &tmpl).await.unwrap();

    // Rename the role
    queries::update_role(&pool, role_id, "Coffee Maker").await.unwrap();

    // Verify cascade to employee
    let employees = queries::list_employees(&pool).await.unwrap();
    assert_eq!(employees[0].roles, vec!["Coffee Maker"]);

    // Verify cascade to shift template
    let templates = queries::list_shift_templates(&pool).await.unwrap();
    assert_eq!(templates[0].required_role, "Coffee Maker");

    // Verify role table itself
    let roles = queries::list_roles(&pool).await.unwrap();
    assert_eq!(roles.len(), 1);
    assert_eq!(roles[0].name, "Coffee Maker");
}

#[tokio::test]
async fn role_delete_blocked_when_in_use() {
    let pool = test_pool().await;

    let role_id = queries::insert_role(&pool, "Barista").await.unwrap();

    // Create an employee using the role
    let emp = Employee {
        id: 0,
        first_name: "Alice".to_string(),
        last_name: String::new(),
        nickname: None,
        roles: vec!["Barista".to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 30.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: Availability::default(),
        availability: Availability::default(),
        deleted: false,
    };
    queries::insert_employee(&pool, &emp).await.unwrap();

    // Attempt to delete the role — should fail
    let result = queries::delete_role(&pool, role_id).await;
    assert!(result.is_err());
    let err_msg = result.unwrap_err().to_string();
    assert!(err_msg.contains("still assigned to"), "Expected 'still assigned to' error, got: {err_msg}");
}

#[tokio::test]
async fn migration_populates_roles_from_existing_data() {
    let pool = test_pool().await;

    let emp = Employee {
        id: 0,
        first_name: "Alice".to_string(),
        last_name: String::new(),
        nickname: None,
        roles: vec!["Barista".to_string(), "Manager".to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 30.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: Availability::default(),
        availability: Availability::default(),
        deleted: false,
    };
    queries::insert_employee(&pool, &emp).await.unwrap();

    // Roles table starts empty on a fresh DB
    let roles = queries::list_roles(&pool).await.unwrap();
    // Fresh DB — no auto-populated roles (there was no data before migration ran)
    assert!(roles.is_empty());

    // Now create roles manually
    queries::insert_role(&pool, "Barista").await.unwrap();
    queries::insert_role(&pool, "Manager").await.unwrap();

    let roles = queries::list_roles(&pool).await.unwrap();
    assert_eq!(roles.len(), 2);
}

// ─── New DB tests ───────────────────────────────────────────

#[tokio::test]
async fn materialise_shifts_creates_correct_dates() {
    let pool = test_pool().await;

    let tmpl = ShiftTemplate {
        id: 0,
        name: "Multi-day".to_string(),
        weekdays: vec![Weekday::Mon, Weekday::Wed, Weekday::Fri],
        start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
        deleted: false,
    };
    queries::insert_shift_template(&pool, &tmpl).await.unwrap();

    let week_start = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap(); // Monday
    let rota_id = queries::insert_rota(&pool, week_start).await.unwrap();

    let shifts = queries::materialise_shifts(&pool, rota_id, week_start)
        .await
        .unwrap();

    assert_eq!(shifts.len(), 3);

    let dates: Vec<NaiveDate> = shifts.iter().map(|s| s.date).collect();
    assert!(dates.contains(&NaiveDate::from_ymd_opt(2026, 3, 23).unwrap())); // Mon
    assert!(dates.contains(&NaiveDate::from_ymd_opt(2026, 3, 25).unwrap())); // Wed
    assert!(dates.contains(&NaiveDate::from_ymd_opt(2026, 3, 27).unwrap())); // Fri

    // All shifts should reference the rota and template
    for s in &shifts {
        assert_eq!(s.rota_id, rota_id);
        assert!(s.template_id.is_some());
        assert!(s.id > 0);
    }
}

#[tokio::test]
async fn soft_deleted_employee_assignments_survive() {
    let pool = test_pool().await;

    let emp = Employee {
        id: 0,
        first_name: "Alice".to_string(),
        last_name: String::new(),
        nickname: None,
        roles: vec!["barista".to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 40.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: Availability::default(),
        availability: Availability::default(),
        deleted: false,
    };
    let emp_id = queries::insert_employee(&pool, &emp).await.unwrap();

    // Create rota + shift + assignment
    let week_start = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
    let rota_id = queries::insert_rota(&pool, week_start).await.unwrap();
    let shift = Shift {
        id: 0,
        template_id: None,
        rota_id,
        date: week_start,
        start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
    };
    let shift_id = queries::insert_shift(&pool, &shift).await.unwrap();
    let assignment = Assignment {
        id: 0,
        rota_id,
        shift_id,
        employee_id: emp_id,
        status: AssignmentStatus::Confirmed,
        employee_name: Some("Alice".to_string()),
    };
    queries::insert_assignment(&pool, &assignment).await.unwrap();

    // Soft-delete the employee
    queries::delete_employee(&pool, emp_id).await.unwrap();

    // Assignment should still exist
    let assignments = queries::list_assignments_for_rota(&pool, rota_id).await.unwrap();
    assert_eq!(assignments.len(), 1);
    assert_eq!(assignments[0].employee_id, emp_id);
    assert_eq!(assignments[0].employee_name, Some("Alice".to_string()));
}

#[tokio::test]
async fn swap_assignment_shifts_exchanges_shift_ids() {
    let pool = test_pool().await;

    let week_start = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
    let rota_id = queries::insert_rota(&pool, week_start).await.unwrap();

    // Create two shifts
    let s1 = Shift {
        id: 0,
        template_id: None,
        rota_id,
        date: week_start,
        start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
    };
    let s2 = Shift {
        id: 0,
        template_id: None,
        rota_id,
        date: week_start,
        start_time: NaiveTime::from_hms_opt(13, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(18, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
    };
    let shift_id_1 = queries::insert_shift(&pool, &s1).await.unwrap();
    let shift_id_2 = queries::insert_shift(&pool, &s2).await.unwrap();

    // Create two employees
    let emp1 = Employee {
        id: 0,
        first_name: "Alice".to_string(),
        last_name: String::new(),
        nickname: None,
        roles: vec!["barista".to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 40.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: Availability::default(),
        availability: Availability::default(),
        deleted: false,
    };
    let emp2 = Employee { first_name: "Bob".to_string(), ..emp1.clone() };
    let emp_id_1 = queries::insert_employee(&pool, &emp1).await.unwrap();
    let emp_id_2 = queries::insert_employee(&pool, &emp2).await.unwrap();

    // Assign: Alice→shift1, Bob→shift2
    let a1 = Assignment {
        id: 0,
        rota_id,
        shift_id: shift_id_1,
        employee_id: emp_id_1,
        status: AssignmentStatus::Confirmed,
        employee_name: Some("Alice".to_string()),
    };
    let a2 = Assignment {
        id: 0,
        rota_id,
        shift_id: shift_id_2,
        employee_id: emp_id_2,
        status: AssignmentStatus::Confirmed,
        employee_name: Some("Bob".to_string()),
    };
    let a1_id = queries::insert_assignment(&pool, &a1).await.unwrap();
    let a2_id = queries::insert_assignment(&pool, &a2).await.unwrap();

    // Swap
    queries::swap_assignment_shifts(&pool, a1_id, shift_id_1, a2_id, shift_id_2)
        .await
        .unwrap();

    // Verify: Alice→shift2, Bob→shift1
    let assignments = queries::list_assignments_for_rota(&pool, rota_id).await.unwrap();
    let alice_assign = assignments.iter().find(|a| a.employee_id == emp_id_1).unwrap();
    let bob_assign = assignments.iter().find(|a| a.employee_id == emp_id_2).unwrap();
    assert_eq!(alice_assign.shift_id, shift_id_2);
    assert_eq!(bob_assign.shift_id, shift_id_1);
}

#[tokio::test]
async fn update_shift_times_persists() {
    let pool = test_pool().await;

    let week_start = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
    let rota_id = queries::insert_rota(&pool, week_start).await.unwrap();

    let shift = Shift {
        id: 0,
        template_id: None,
        rota_id,
        date: week_start,
        start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
    };
    let shift_id = queries::insert_shift(&pool, &shift).await.unwrap();

    // Update times
    let new_start = NaiveTime::from_hms_opt(8, 30, 0).unwrap();
    let new_end = NaiveTime::from_hms_opt(14, 0, 0).unwrap();
    queries::update_shift_times(&pool, shift_id, new_start, new_end)
        .await
        .unwrap();

    // Verify
    let shifts = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    assert_eq!(shifts.len(), 1);
    assert_eq!(shifts[0].start_time, new_start);
    assert_eq!(shifts[0].end_time, new_end);
}

#[tokio::test]
async fn delete_shifts_for_rota_preserves_adhoc() {
    let pool = test_pool().await;

    let week_start = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
    let rota_id = queries::insert_rota(&pool, week_start).await.unwrap();

    // Insert a template so we can create a template-based shift
    let tmpl = ShiftTemplate {
        id: 0,
        name: "Morning".to_string(),
        weekdays: vec![Weekday::Mon],
        start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
        deleted: false,
    };
    let tmpl_id = queries::insert_shift_template(&pool, &tmpl).await.unwrap();

    // Template-based shift
    let template_shift = Shift {
        id: 0,
        template_id: Some(tmpl_id),
        rota_id,
        date: week_start,
        start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
    };
    queries::insert_shift(&pool, &template_shift).await.unwrap();

    // Ad-hoc shift (no template)
    let adhoc_shift = Shift {
        id: 0,
        template_id: None,
        rota_id,
        date: week_start,
        start_time: NaiveTime::from_hms_opt(14, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(18, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
    };
    queries::insert_shift(&pool, &adhoc_shift).await.unwrap();

    // Should have 2 shifts
    let before = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    assert_eq!(before.len(), 2);

    // Delete template-based shifts only
    queries::delete_shifts_for_rota(&pool, rota_id).await.unwrap();

    // Ad-hoc shift should survive
    let after = queries::list_shifts_for_rota(&pool, rota_id).await.unwrap();
    assert_eq!(after.len(), 1);
    assert!(after[0].template_id.is_none());
}

#[tokio::test]
async fn list_employee_shift_history_returns_joined_records() {
    let pool = test_pool().await;

    // Create an employee
    let emp = helpers::make_employee(0, "Alice", "barista", AvailabilityState::Yes);
    let emp_id = queries::insert_employee(&pool, &emp).await.unwrap();

    // Create a rota for the test week
    let week = helpers::week_start();
    let rota_id = queries::insert_rota(&pool, week).await.unwrap();

    // Insert a shift
    let shift = Shift {
        id: 0,
        template_id: None,
        rota_id,
        date: helpers::date(23), // Monday
        start_time: NaiveTime::from_hms_opt(9, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(17, 0, 0).unwrap(),
        required_role: "barista".to_string(),
        min_employees: 1,
        max_employees: 1,
    };
    let shift_id = queries::insert_shift(&pool, &shift).await.unwrap();

    // Create an assignment
    let assignment = Assignment {
        id: 0,
        rota_id,
        shift_id,
        employee_id: emp_id,
        status: AssignmentStatus::Confirmed,
        employee_name: Some("Alice".to_string()),
    };
    queries::insert_assignment(&pool, &assignment).await.unwrap();

    // Query shift history
    let history = queries::list_employee_shift_history(&pool, emp_id).await.unwrap();
    assert_eq!(history.len(), 1);

    let rec = &history[0];
    assert_eq!(rec.employee_id, emp_id);
    assert_eq!(rec.shift_id, shift_id);
    assert_eq!(rec.rota_id, rota_id);
    assert_eq!(rec.status, AssignmentStatus::Confirmed);
    assert_eq!(rec.date, helpers::date(23));
    assert_eq!(rec.required_role, "barista");
    assert_eq!(rec.week_start, week);
    assert!(!rec.finalized);
    assert!((rec.duration_hours() - 8.0).abs() < 0.01);

    // Employee with no assignments returns empty
    let emp2 = helpers::make_employee(0, "Bob", "barista", AvailabilityState::Yes);
    let emp2_id = queries::insert_employee(&pool, &emp2).await.unwrap();
    let empty = queries::list_employee_shift_history(&pool, emp2_id).await.unwrap();
    assert!(empty.is_empty());
}
