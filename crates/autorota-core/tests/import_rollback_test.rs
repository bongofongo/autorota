//! Regression tests for `import::roster::apply_import` transaction handling.
//!
//! Pre-fix behaviour: `apply_import` opened a transaction but the inner
//! `queries::*_employee` calls passed `&pool` instead of `&mut *tx`, so writes
//! committed immediately and `tx.commit()` was a no-op. Mid-batch failures
//! could not roll back. The fix threads `&mut *tx` through; these tests pin
//! that invariant.

use autorota_core::db::queries;
use autorota_core::import::{ParsedEmployeeRow, roster};
use autorota_core::models::availability::AvailabilityState;
use autorota_core::testutil::*;

fn parsed_row(first: &str, last: &str) -> ParsedEmployeeRow {
    ParsedEmployeeRow {
        first_name: first.into(),
        last_name: last.into(),
        nickname: None,
        phone: None,
        email: None,
        preferred_contact: None,
        roles: vec!["barista".into()],
        target_weekly_hours: Some(20.0),
        weekly_hours_deviation: Some(4.0),
        max_daily_hours: Some(8.0),
        hourly_wage: None,
        wage_currency: None,
        notes: None,
        bank_details: None,
        match_existing_id: None,
        diff_summary: "NEW".into(),
        include: true,
    }
}

#[tokio::test]
async fn apply_import_commits_all_rows_on_success() {
    let pool = test_pool().await;
    let rows = vec![
        parsed_row("Alice", "Smith"),
        parsed_row("Bob", "Lee"),
        parsed_row("Carol", "Jones"),
    ];

    let summary = roster::apply_import(&pool, &rows).await.unwrap();
    assert_eq!(summary.inserted, 3);
    assert_eq!(summary.updated, 0);
    assert_eq!(summary.skipped, 0);

    let all = queries::list_all_employees(&pool).await.unwrap();
    assert_eq!(all.len(), 3);
}

/// White-box guard: prove the new query signatures honour an enclosing
/// transaction. If `insert_employee` ever regresses to using `&pool`
/// internally, the dropped tx would leave rows committed and this asserts
/// would fail.
#[tokio::test]
async fn insert_employee_respects_transaction_drop() {
    let pool = test_pool().await;

    let alice = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let bob = EmployeeBuilder::new("Bob")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();

    {
        let mut tx = pool.begin().await.unwrap();
        queries::insert_employee(&mut *tx, &alice).await.unwrap();
        queries::insert_employee(&mut *tx, &bob).await.unwrap();
        // drop without commit → rollback
    }

    let all = queries::list_all_employees(&pool).await.unwrap();
    assert!(
        all.is_empty(),
        "tx should have rolled back, found {} rows",
        all.len()
    );
}

#[tokio::test]
async fn update_employee_respects_transaction_drop() {
    let pool = test_pool().await;
    let alice = EmployeeBuilder::new("Alice")
        .role("barista")
        .available(AvailabilityState::Yes)
        .build();
    let ids = seed_employees(&pool, &[alice]).await;

    {
        let mut tx = pool.begin().await.unwrap();
        let mut emp = queries::get_employee(&mut *tx, ids[0])
            .await
            .unwrap()
            .unwrap();
        emp.first_name = "Mutated".into();
        queries::update_employee(&mut *tx, &emp).await.unwrap();
        // drop without commit → rollback
    }

    let reloaded = queries::get_employee(&pool, ids[0]).await.unwrap().unwrap();
    assert_eq!(reloaded.first_name, "Alice");
}
