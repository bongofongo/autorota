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

    // Migration 012: add staged_shifts and commits tables for git-like staging/commit workflow.
    let has_commits_table: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='commits'",
    )
    .fetch_one(pool)
    .await?;

    if !has_commits_table {
        // The migration SQL references r.finalized, which only exists on
        // schemas created by migration 001. Guard against old schemas where
        // the column was never added (e.g. very old DBs migrated forward).
        let has_finalized_col: bool = sqlx::query_scalar(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('rotas') WHERE name = 'finalized'",
        )
        .fetch_one(pool)
        .await?;

        if has_finalized_col {
            let m12 = include_str!("../../migrations/012_staging_commits.sql");
            sqlx::raw_sql(m12).execute(pool).await?;
        } else {
            // Just create the commits table without migrating finalized rotas.
            sqlx::raw_sql(
                "CREATE TABLE IF NOT EXISTS commits (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    rota_id         INTEGER NOT NULL REFERENCES rotas(id) ON DELETE CASCADE,
                    committed_at    TEXT    NOT NULL,
                    summary         TEXT    NOT NULL,
                    snapshot_json   TEXT    NOT NULL
                );",
            )
            .execute(pool)
            .await?;
        }
    }

    // Migration 013: performance indexes (all use IF NOT EXISTS, safe to run unconditionally).
    let m13 = include_str!("../../migrations/013_perf_indexes.sql");
    sqlx::raw_sql(m13).execute(pool).await?;

    // Migration 014: availability progress tracking for carousel workflow.
    let has_availability_progress: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='availability_progress'",
    )
    .fetch_one(pool)
    .await?;

    if !has_availability_progress {
        let m14 = include_str!("../../migrations/014_availability_progress.sql");
        sqlx::raw_sql(m14).execute(pool).await?;
    }

    // Migration 015: drop staged_shifts table (staging replaced by UI-only selection).
    // The finalized column is left in the DB schema but ignored by code.
    let has_staged_shifts: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='staged_shifts'",
    )
    .fetch_one(pool)
    .await?;

    if has_staged_shifts {
        let m15 = include_str!("../../migrations/015_remove_finalized_staging.sql");
        sqlx::raw_sql(m15).execute(pool).await?;
    }

    // Migration 016: rename commits → saves, add label column.
    // Guard: only run if `commits` exists AND `saves` does not (avoids conflict
    // when migration 012's CREATE TABLE IF NOT EXISTS re-creates `commits` after
    // a previous run already renamed it).
    let has_commits_table: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='commits'",
    )
    .fetch_one(pool)
    .await?;
    let has_saves_table: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='saves'",
    )
    .fetch_one(pool)
    .await?;

    if has_commits_table && !has_saves_table {
        let m16 = include_str!("../../migrations/016_rename_commits_to_saves.sql");
        sqlx::raw_sql(m16).execute(pool).await?;
    } else if has_commits_table && has_saves_table {
        // Both exist (migration 012 re-created `commits` after a previous rename).
        // Drop the stale `commits` table and ensure `saves` has the label column.
        sqlx::raw_sql("DROP TABLE commits").execute(pool).await?;
        let has_label: bool = sqlx::query_scalar(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('saves') WHERE name = 'label'",
        )
        .fetch_one(pool)
        .await?;
        if !has_label {
            sqlx::raw_sql("ALTER TABLE saves ADD COLUMN label TEXT")
                .execute(pool)
                .await?;
        }
    }

    // Migration 017: rename committed_at → saved_at in saves table.
    let has_committed_at: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('saves') WHERE name = 'committed_at'",
    )
    .fetch_one(pool)
    .await?;

    if has_committed_at {
        let m17 = include_str!("../../migrations/017_rename_committed_at_to_saved_at.sql");
        sqlx::raw_sql(m17).execute(pool).await?;
    }

    // Migration 018: per-save tag table (replaces single `label` column — label
    // is left in place as a dead column so we don't need a table rebuild).
    let has_save_tags: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='save_tags'",
    )
    .fetch_one(pool)
    .await?;

    if !has_save_tags {
        let m18 = include_str!("../../migrations/018_save_tags.sql");
        sqlx::raw_sql(m18).execute(pool).await?;
    }

    // Migration 019: per-save `restored_at` timestamp — promotes a restored
    // save to the top of its week and drives the red "Restored" badge.
    let has_restored_at: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('saves') WHERE name = 'restored_at'",
    )
    .fetch_one(pool)
    .await?;

    if !has_restored_at {
        let m19 = include_str!("../../migrations/019_save_restored_at.sql");
        sqlx::raw_sql(m19).execute(pool).await?;
    }

    // Migration 020: per-row `source` on employee_availability_overrides —
    // distinguishes `exception` (created via Exceptions UI) from `manual`
    // (normal per-date edit through the availability grid).
    let has_ovr_source: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('employee_availability_overrides') WHERE name = 'source'",
    )
    .fetch_one(pool)
    .await?;

    if !has_ovr_source {
        let m20 = include_str!("../../migrations/020_override_source.sql");
        sqlx::raw_sql(m20).execute(pool).await?;
    }

    Ok(())
}
