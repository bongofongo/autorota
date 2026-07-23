//! Concurrency smoke tests against a file-backed database — the only place
//! the real 5-connection pool exists (`:memory:` stays single-connection).
//! Guards the per-connection FK-enforcement fix and WAL/busy handling under
//! actual pool contention, which no other suite exercises.

mod helpers;

use autorota_core::db;
use autorota_core::db::queries;
use autorota_core::models::assignment::{Assignment, AssignmentStatus};
use autorota_core::models::availability::AvailabilityState;
use autorota_core::models::save::SaveSource;
use autorota_core::models::shift::Shift;
use chrono::{NaiveDate, NaiveTime};
use sqlx::SqlitePool;

async fn file_pool(dir: &tempfile::TempDir, name: &str) -> SqlitePool {
    let url = format!("sqlite://{}", dir.path().join(name).display());
    db::connect(&url).await.unwrap()
}

fn monday() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 1, 5).unwrap()
}

async fn seed_rota_shift(pool: &SqlitePool) -> (i64, i64) {
    let rota_id = queries::insert_rota(pool, monday()).await.unwrap();
    let shift = Shift {
        id: 0,
        template_id: None,
        rota_id,
        date: monday(),
        start_time: NaiveTime::from_hms_opt(8, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        required_role: "barista".into(),
        min_employees: 1,
        max_employees: 1,
        role_requirements: vec![],
    };
    let shift_id = queries::insert_shift(pool, &shift).await.unwrap();
    (rota_id, shift_id)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn parallel_writers_all_commit() {
    let dir = tempfile::tempdir().unwrap();
    let pool = file_pool(&dir, "writers.sqlite").await;

    const TASKS: usize = 8;
    const PER_TASK: usize = 5;
    let handles: Vec<_> = (0..TASKS)
        .map(|t| {
            let pool = pool.clone();
            tokio::spawn(async move {
                for i in 0..PER_TASK {
                    let emp = helpers::make_employee(
                        0,
                        &format!("Emp {t}-{i}"),
                        "barista",
                        AvailabilityState::Yes,
                    );
                    queries::insert_employee(&pool, &emp).await?;
                }
                Ok::<_, sqlx::Error>(())
            })
        })
        .collect();

    for h in handles {
        h.await.unwrap().expect("writer task hit a DB error");
    }
    let all = queries::list_employees(&pool).await.unwrap();
    assert_eq!(all.len(), TASKS * PER_TASK, "lost writes under contention");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn readers_stay_consistent_during_writes() {
    let dir = tempfile::tempdir().unwrap();
    let pool = file_pool(&dir, "readers.sqlite").await;
    let (rota_id, _shift_id) = seed_rota_shift(&pool).await;

    let writer = {
        let pool = pool.clone();
        tokio::spawn(async move {
            for i in 0..30 {
                let emp = helpers::make_employee(
                    0,
                    &format!("Writer {i}"),
                    "barista",
                    AvailabilityState::Yes,
                );
                queries::insert_employee(&pool, &emp).await?;
            }
            Ok::<_, sqlx::Error>(())
        })
    };

    let readers: Vec<_> = (0..3)
        .map(|_| {
            let pool = pool.clone();
            tokio::spawn(async move {
                for _ in 0..20 {
                    let emps = queries::list_employees(&pool).await?;
                    // Monotone-ish sanity: never a torn/negative view.
                    assert!(emps.len() <= 30);
                    let snap = queries::snapshot_from_live(&pool, rota_id).await?;
                    assert_eq!(snap.week_start, monday().to_string());
                }
                Ok::<_, sqlx::Error>(())
            })
        })
        .collect();

    writer.await.unwrap().expect("writer errored");
    for r in readers {
        r.await.unwrap().expect("reader errored during writes");
    }
    assert_eq!(queries::list_employees(&pool).await.unwrap().len(), 30);
}

/// Regression net for the pooled-FK bug fixed last session: every pooled
/// connection must enforce foreign keys, not just the one that received a
/// `PRAGMA`. Saturating the pool with more tasks than connections makes each
/// of the 5 connections serve at least one insert attempt.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fk_enforced_on_every_pooled_connection_under_load() {
    let dir = tempfile::tempdir().unwrap();
    let pool = file_pool(&dir, "fk.sqlite").await;

    let handles: Vec<_> = (0..12)
        .map(|_| {
            let pool = pool.clone();
            tokio::spawn(async move {
                sqlx::query(
                    "INSERT INTO assignments (rota_id, shift_id, employee_id, status) \
                     VALUES (9999, 9999, 9999, 'Proposed')",
                )
                .execute(&pool)
                .await
            })
        })
        .collect();

    for h in handles {
        let result = h.await.unwrap();
        let err = result.expect_err("dangling-FK insert must fail on every connection");
        assert!(
            err.to_string().contains("FOREIGN KEY"),
            "expected FK violation, got: {err}"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_save_creation_yields_distinct_saves() {
    let dir = tempfile::tempdir().unwrap();
    let pool = file_pool(&dir, "saves.sqlite").await;
    let (rota_id, shift_id) = seed_rota_shift(&pool).await;

    let emp = helpers::make_employee(0, "Alice", "barista", AvailabilityState::Yes);
    let emp_id = queries::insert_employee(&pool, &emp).await.unwrap();
    let assignment = Assignment {
        id: 0,
        rota_id,
        shift_id,
        employee_id: emp_id,
        status: AssignmentStatus::Confirmed,
        employee_name: Some("Alice".into()),
        hourly_wage: None,
    };
    queries::insert_assignment(&pool, &assignment)
        .await
        .unwrap();

    const SAVERS: usize = 6;
    let handles: Vec<_> = (0..SAVERS)
        .map(|_| {
            let pool = pool.clone();
            tokio::spawn(
                async move { queries::create_save(&pool, rota_id, SaveSource::Manual).await },
            )
        })
        .collect();

    let mut ids = Vec::new();
    for h in handles {
        ids.push(h.await.unwrap().expect("concurrent create_save failed"));
    }
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), SAVERS, "save ids collided");

    let saved: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM saves WHERE rota_id = ?")
        .bind(rota_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(saved as usize, SAVERS);
}
