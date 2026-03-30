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

    // Migration 004: add soft-delete flags and snapshot employee name in assignments.
    let has_deleted_col: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('employees') WHERE name = 'deleted'",
    )
    .fetch_one(pool)
    .await?;

    if !has_deleted_col {
        let m4 = include_str!("../../migrations/004_history_support.sql");
        sqlx::raw_sql(m4).execute(pool).await?;
    }

    // Migration 005: make template_id nullable on shifts to support ad-hoc shifts.
    let template_id_notnull: bool = sqlx::query_scalar(
        "SELECT \"notnull\" FROM pragma_table_info('shifts') WHERE name = 'template_id'",
    )
    .fetch_one(pool)
    .await?;

    if template_id_notnull {
        let m5 = include_str!("../../migrations/005_nullable_template_id.sql");
        sqlx::raw_sql(m5).execute(pool).await?;
    }

    // Migration 006: create roles master table and populate from existing data.
    let has_roles_table: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='roles'",
    )
    .fetch_one(pool)
    .await?;

    if !has_roles_table {
        let m6 = include_str!("../../migrations/006_roles_table.sql");
        sqlx::raw_sql(m6).execute(pool).await?;

        // Auto-populate from existing shift_templates.required_role values.
        sqlx::raw_sql(
            "INSERT OR IGNORE INTO roles (name)
             SELECT DISTINCT required_role FROM shift_templates WHERE required_role != '' AND deleted = 0",
        )
        .execute(pool)
        .await?;

        // Auto-populate from existing employees.roles JSON arrays.
        sqlx::raw_sql(
            "INSERT OR IGNORE INTO roles (name)
             SELECT DISTINCT j.value FROM employees, json_each(employees.roles) AS j
             WHERE j.value != '' AND employees.deleted = 0",
        )
        .execute(pool)
        .await?;
    }

    // Migration 007: split 'name' column into first_name, last_name, nickname.
    let has_first_name: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('employees') WHERE name = 'first_name'",
    )
    .fetch_one(pool)
    .await?;

    if !has_first_name {
        let m7 = include_str!("../../migrations/007_employee_name_split.sql");
        sqlx::raw_sql(m7).execute(pool).await?;
    }

    // Migration 008: employee availability overrides + shift template overrides.
    let has_overrides: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='employee_availability_overrides'",
    )
    .fetch_one(pool)
    .await?;

    if !has_overrides {
        let m8 = include_str!("../../migrations/008_overrides.sql");
        sqlx::raw_sql(m8).execute(pool).await?;
    }

    // Migration 009: add hourly_wage to employees and assignments.
    let has_hourly_wage: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('employees') WHERE name = 'hourly_wage'",
    )
    .fetch_one(pool)
    .await?;

    if !has_hourly_wage {
        let m9 = include_str!("../../migrations/009_employee_wages.sql");
        sqlx::raw_sql(m9).execute(pool).await?;
    }

    // Migration 010: add wage_currency to employees.
    let has_wage_currency: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('employees') WHERE name = 'wage_currency'",
    )
    .fetch_one(pool)
    .await?;

    if !has_wage_currency {
        let m10 = include_str!("../../migrations/010_employee_wage_currency.sql");
        sqlx::raw_sql(m10).execute(pool).await?;
    }

    // Migration 011: add sync tracking columns and tables.
    let has_sync_status: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('employees') WHERE name = 'sync_status'",
    )
    .fetch_one(pool)
    .await?;

    if !has_sync_status {
        let m11 = include_str!("../../migrations/011_sync_support.sql");
        sqlx::raw_sql(m11).execute(pool).await?;
    }

    Ok(())
}
