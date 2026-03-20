use autorota_core::db;
use autorota_core::db::queries;
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::{Availability, AvailabilityState};
use autorota_core::models::employee::Employee;
use autorota_core::models::shift::{Shift, ShiftTemplate};
use chrono::{NaiveDate, NaiveTime, Weekday};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use std::str::FromStr;

async fn test_pool() -> sqlx::SqlitePool {
    db::connect("sqlite::memory:").await.unwrap()
}

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
    assert_eq!(employees[0].name, "Alice");

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
        name: "Alice".to_string(),
        roles: vec!["barista".to_string(), "cashier".to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 40.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: avail.clone(),
        availability: avail,
    };

    let id = queries::insert_employee(&pool, &emp).await.unwrap();
    assert!(id > 0);

    let fetched = queries::get_employee(&pool, id).await.unwrap().unwrap();
    assert_eq!(fetched.name, "Alice");
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
    let deleted = queries::get_employee(&pool, id).await.unwrap();
    assert!(deleted.is_none());
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
        name: "Bob".to_string(),
        roles: vec!["barista".to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 40.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: Availability::default(),
        availability: Availability::default(),
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
    };
    let tmpl_id = queries::insert_shift_template(&pool, &tmpl).await.unwrap();

    // Create rota for a week
    let week_start = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
    let rota_id = queries::insert_rota(&pool, week_start).await.unwrap();

    // Create a concrete shift from the template
    let shift = Shift {
        id: 0,
        template_id: tmpl_id,
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
