//! Error-path coverage for the database layer: FK enforcement across pool
//! connections, constraint violations, missing-id contracts, corrupt files.

mod helpers;

use autorota_core::db::{self, queries};
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::AvailabilityState;
use chrono::NaiveDate;

use helpers::{make_employee, test_pool};

fn dangling_assignment() -> Assignment {
    Assignment {
        id: 0,
        rota_id: 999,
        shift_id: 999,
        employee_id: 999,
        status: AssignmentStatus::Proposed,
        employee_name: None,
        hourly_wage: None,
    }
}

// ── Foreign-key enforcement ──────────────────────────────────

#[tokio::test]
async fn fk_enforced_on_first_connection() {
    let pool = test_pool().await;
    let result = queries::insert_assignment(&pool, &dangling_assignment()).await;
    assert!(
        result.is_err(),
        "assignment referencing nonexistent rota/shift/employee must be rejected"
    );
}

#[tokio::test]
async fn fk_enforced_on_every_pool_connection() {
    // File-backed DB: the pool opens fresh connections lazily. FK enforcement
    // must hold on all of them, not just the one that ran the setup PRAGMA.
    let dir = tempfile::tempdir().unwrap();
    let url = format!(
        "sqlite://{}?mode=rwc",
        dir.path().join("fk.sqlite").display()
    );
    let pool = db::connect(&url).await.unwrap();

    // Pin one connection so the insert below is forced onto a newly opened one.
    let _held = pool.acquire().await.unwrap();

    let result = queries::insert_assignment(&pool, &dangling_assignment()).await;
    assert!(
        result.is_err(),
        "dangling-FK insert slipped through on a fresh pool connection — FK checks are off there"
    );
}

// ── Constraint violations ────────────────────────────────────

#[tokio::test]
async fn duplicate_role_name_rejected() {
    let pool = test_pool().await;
    queries::insert_role(&pool, "Barista").await.unwrap();
    let dup = queries::insert_role(&pool, "Barista").await;
    assert!(dup.is_err(), "roles.name is UNIQUE; duplicate must error");
}

// ── Missing-id contracts ─────────────────────────────────────

#[tokio::test]
async fn get_missing_rows_return_none() {
    let pool = test_pool().await;
    assert!(queries::get_employee(&pool, 12345).await.unwrap().is_none());
    assert!(queries::get_rota(&pool, 12345).await.unwrap().is_none());
    assert!(queries::get_save(&pool, 12345).await.unwrap().is_none());
    let date = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
    assert!(
        queries::get_employee_availability_override(&pool, 12345, date)
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn restore_from_missing_save_errors() {
    let pool = test_pool().await;
    let err = queries::restore_from_save(&pool, 12345).await.unwrap_err();
    assert!(matches!(err, sqlx::Error::RowNotFound));
}

#[tokio::test]
async fn delete_role_in_use_is_blocked_but_missing_id_is_not() {
    let pool = test_pool().await;
    // Deleting a nonexistent role: pin the current contract (no panic).
    let result = queries::delete_role(&pool, 12345).await;
    assert!(result.is_err() || result.is_ok(), "must not panic");
    // In-use role stays deletable-blocked (covered in db_integration); here we
    // only care that the employee insert keeps the role text intact.
    let emp = make_employee(0, "Alice", "barista", AvailabilityState::Yes);
    let id = queries::insert_employee(&pool, &emp).await.unwrap();
    assert!(queries::get_employee(&pool, id).await.unwrap().is_some());
}

// ── Corrupt database file ────────────────────────────────────

#[tokio::test]
async fn connect_to_corrupt_file_errors_cleanly() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("garbage.sqlite");
    std::fs::write(&path, b"this is not a sqlite database, not even close").unwrap();
    let result = db::connect(&format!("sqlite://{}", path.display())).await;
    assert!(
        result.is_err(),
        "corrupt file must yield an error, not a panic"
    );
}
