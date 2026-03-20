pub mod queries;

use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use std::str::FromStr;

/// Create a connection pool and run migrations.
pub async fn connect(database_url: &str) -> Result<SqlitePool, sqlx::Error> {
    // Use foreign_keys(false) on the connect options so every connection
    // in the pool starts with FK checks disabled during setup.
    let opts = SqliteConnectOptions::from_str(database_url)?
        .create_if_missing(true)
        .foreign_keys(false);

    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(opts)
        .await?;

    sqlx::query("PRAGMA journal_mode=WAL;")
        .execute(&pool)
        .await?;

    run_migrations(&pool).await?;

    // Enable foreign keys for all future operations.
    sqlx::query("PRAGMA foreign_keys=ON;")
        .execute(&pool)
        .await?;

    Ok(pool)
}

async fn run_migrations(pool: &SqlitePool) -> Result<(), sqlx::Error> {
    let m1 = include_str!("../../migrations/001_initial.sql");
    sqlx::raw_sql(m1).execute(pool).await?;

    // Migration 002: only run if the old 'weekday' column exists (pre-migration schema).
    let has_old_column: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('shift_templates') WHERE name = 'weekday'",
    )
    .fetch_one(pool)
    .await?;

    if has_old_column {
        let m2 = include_str!("../../migrations/002_weekdays_and_cascade.sql");
        sqlx::raw_sql(m2).execute(pool).await?;
    }

    // Migration 003: add employee work preference fields if they don't exist yet.
    let has_target_weekly: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('employees') WHERE name = 'target_weekly_hours'",
    )
    .fetch_one(pool)
    .await?;

    if !has_target_weekly {
        let m3 = include_str!("../../migrations/003_employee_work_prefs.sql");
        sqlx::raw_sql(m3).execute(pool).await?;
    }

    Ok(())
}
