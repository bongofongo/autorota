//! Migration upgrade-path spine: start a database at the original 001 schema
//! with representative data, run the full migration chain via `db::connect`,
//! and require (a) the resulting schema to be identical to a fresh database's
//! and (b) the seeded data to survive with the expected backfills applied.
//!
//! This covers all 26 migrations transitively without per-migration fixture
//! DBs. Pre-001 shapes (the singular-`weekday` era) are covered separately by
//! `migration_from_old_schema_with_data` in db_integration.rs.

use autorota_core::db;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};
use std::collections::BTreeSet;
use std::str::FromStr;

const M001: &str = include_str!("../migrations/001_initial.sql");

/// Open a bare pool on `path` (no migrations, FKs off) — simulates a database
/// created by the very first release.
async fn bare_pool(path: &str) -> SqlitePool {
    let opts = SqliteConnectOptions::from_str(path)
        .unwrap()
        .create_if_missing(true)
        .foreign_keys(false);
    SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(opts)
        .await
        .unwrap()
}

/// (type, name, normalized SQL) for every user table/index/trigger/view.
async fn schema_signature(pool: &SqlitePool) -> BTreeSet<(String, String, String)> {
    let rows = sqlx::query(
        "SELECT type, name, COALESCE(sql, '') AS sql FROM sqlite_master \
         WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    rows.iter()
        .map(|r| {
            let sql: String = r.get("sql");
            (
                r.get("type"),
                r.get("name"),
                sql.split_whitespace().collect::<Vec<_>>().join(" "),
            )
        })
        .collect()
}

async fn count(pool: &SqlitePool, sql: &str) -> i64 {
    sqlx::query_scalar(sql).fetch_one(pool).await.unwrap()
}

/// Seed a 001-era database with one of everything the early app could hold,
/// chosen to trip every data-transforming migration downstream:
/// - employees.name → 007 split, 006 roles backfill from the JSON array
/// - finalized rota → 012 synthetic commit → 016 rename to saves
/// - template/shift required_role → 024 role-requirement child rows,
///   025 JSON mirror backfill
async fn seed_001(pool: &SqlitePool) {
    sqlx::raw_sql(M001).execute(pool).await.unwrap();
    sqlx::raw_sql(
        r#"
        INSERT INTO employees (name, roles, max_daily_hours, max_weekly_hours,
                               default_availability, availability, notes)
        VALUES ('Alice Smith', '["barista"]', 8.0, 40.0, '{"Mon:8":"Yes"}', '{}', 'senior'),
               ('Bob Jones', '["kitchen","barista"]', 6.0, 30.0, '{}', '{}', NULL);

        INSERT INTO shift_templates (name, weekdays, start_time, end_time,
                                     required_role, min_employees, max_employees)
        VALUES ('Morning', 'Mon,Wed,Fri', '08:00:00', '12:00:00', 'barista', 1, 2);

        INSERT INTO rotas (week_start, finalized) VALUES ('2026-01-05', 1);

        INSERT INTO shifts (template_id, rota_id, date, start_time, end_time,
                            required_role, min_employees, max_employees)
        VALUES (1, 1, '2026-01-05', '08:00:00', '12:00:00', 'barista', 1, 2);

        INSERT INTO assignments (rota_id, shift_id, employee_id, status)
        VALUES (1, 1, 1, 'Confirmed');
        "#,
    )
    .execute(pool)
    .await
    .unwrap();
}

#[tokio::test]
async fn migrated_from_001_matches_fresh_schema_and_keeps_data() {
    let dir = tempfile::tempdir().unwrap();
    let old_path = format!("sqlite://{}", dir.path().join("old.sqlite").display());
    let fresh_path = format!("sqlite://{}", dir.path().join("fresh.sqlite").display());

    let bare = bare_pool(&old_path).await;
    seed_001(&bare).await;
    bare.close().await;

    // Full chain (connect also runs PRAGMA foreign_key_check and errors on
    // any dangling reference, so FK integrity is asserted implicitly).
    let migrated = db::connect(&old_path).await.unwrap();
    let fresh = db::connect(&fresh_path).await.unwrap();

    let migrated_schema = schema_signature(&migrated).await;
    let fresh_schema = schema_signature(&fresh).await;
    let only_migrated: Vec<_> = migrated_schema.difference(&fresh_schema).collect();
    let only_fresh: Vec<_> = fresh_schema.difference(&migrated_schema).collect();
    assert!(
        only_migrated.is_empty() && only_fresh.is_empty(),
        "schema divergence after migrating from 001 —\nonly in migrated: {only_migrated:#?}\nonly in fresh: {only_fresh:#?}"
    );

    // Data survived.
    assert_eq!(count(&migrated, "SELECT COUNT(*) FROM employees").await, 2);
    assert_eq!(count(&migrated, "SELECT COUNT(*) FROM shifts").await, 1);
    assert_eq!(
        count(&migrated, "SELECT COUNT(*) FROM assignments").await,
        1
    );

    // 007: name split — the whole legacy name lands in first_name.
    let (first, last): (String, String) =
        sqlx::query_as("SELECT first_name, last_name FROM employees WHERE notes = 'senior'")
            .fetch_one(&migrated)
            .await
            .unwrap();
    assert_eq!(first, "Alice Smith");
    assert_eq!(last, "");

    // 006: roles table backfilled from the employees' JSON role arrays.
    let roles: Vec<String> = sqlx::query_scalar("SELECT name FROM roles ORDER BY name")
        .fetch_all(&migrated)
        .await
        .unwrap();
    assert!(
        roles.contains(&"barista".to_string()) && roles.contains(&"kitchen".to_string()),
        "roles backfill incomplete: {roles:?}"
    );

    // 012 → 016: the finalized rota became a save with a snapshot.
    let saves = count(&migrated, "SELECT COUNT(*) FROM saves WHERE rota_id = 1").await;
    assert_eq!(saves, 1, "finalized rota should have produced one save");

    // 024: primary-role requirements mirrored into child rows.
    let template_reqs = count(
        &migrated,
        "SELECT COUNT(*) FROM template_role_requirements WHERE role = 'barista'",
    )
    .await;
    assert_eq!(template_reqs, 1);
    let shift_reqs = count(
        &migrated,
        "SELECT COUNT(*) FROM shift_role_requirements WHERE role = 'barista'",
    )
    .await;
    assert_eq!(shift_reqs, 1);
}

#[tokio::test]
async fn rerunning_migrations_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let path = format!("sqlite://{}", dir.path().join("idem.sqlite").display());

    let bare = bare_pool(&path).await;
    seed_001(&bare).await;
    bare.close().await;

    let first = db::connect(&path).await.unwrap();
    let schema_first = schema_signature(&first).await;
    let saves_first = count(&first, "SELECT COUNT(*) FROM saves").await;
    let employees_first = count(&first, "SELECT COUNT(*) FROM employees").await;
    first.close().await;

    let second = db::connect(&path).await.unwrap();
    let schema_second = schema_signature(&second).await;
    assert_eq!(
        schema_first, schema_second,
        "schema changed on second migration run"
    );
    assert_eq!(
        count(&second, "SELECT COUNT(*) FROM saves").await,
        saves_first,
        "re-running migrations duplicated the migrated-finalized-rota save"
    );
    assert_eq!(
        count(&second, "SELECT COUNT(*) FROM employees").await,
        employees_first
    );
}
