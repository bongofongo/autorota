//! Database test utilities: in-memory pool, sync status queries, seeding helpers.

use crate::db;
use crate::db::queries;
use crate::models::employee::Employee;
use crate::models::shift::ShiftTemplate;

/// Create an in-memory SQLite pool with all migrations applied.
pub async fn test_pool() -> sqlx::SqlitePool {
    db::connect("sqlite::memory:").await.unwrap()
}

/// Query the sync-tracking columns for a row directly (models don't expose these).
/// Returns (sync_status, last_modified, sync_base_snapshot).
pub async fn query_sync_status(
    pool: &sqlx::SqlitePool,
    table_name: &str,
    id: i64,
) -> (i64, String, Option<String>) {
    let sql = format!(
        "SELECT sync_status, last_modified, sync_base_snapshot FROM {} WHERE id = ?",
        table_name
    );
    sqlx::query_as::<_, (i64, String, Option<String>)>(&sql)
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap()
}

/// Insert employees into the database and return their assigned IDs.
pub async fn seed_employees(pool: &sqlx::SqlitePool, employees: &[Employee]) -> Vec<i64> {
    let mut ids = Vec::new();
    for emp in employees {
        ids.push(queries::insert_employee(pool, emp).await.unwrap());
    }
    ids
}

/// Insert shift templates into the database and return their assigned IDs.
pub async fn seed_templates(pool: &sqlx::SqlitePool, templates: &[ShiftTemplate]) -> Vec<i64> {
    let mut ids = Vec::new();
    for tmpl in templates {
        ids.push(queries::insert_shift_template(pool, tmpl).await.unwrap());
    }
    ids
}

/// Insert roles by name and return their assigned IDs.
pub async fn seed_roles(pool: &sqlx::SqlitePool, roles: &[&str]) -> Vec<i64> {
    let mut ids = Vec::new();
    for name in roles {
        ids.push(queries::insert_role(pool, name).await.unwrap());
    }
    ids
}
