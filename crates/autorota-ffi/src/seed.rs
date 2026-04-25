//! Sample-data seeder for fresh installs and onboarding "load demo" flow.
//!
//! Inserts a cafe-themed dataset (3 roles, 4 employees with realistic
//! availability, 5 weekly shift templates) inside a single transaction.
//!
//! Idempotency: refuses if the database already has employees, roles, or
//! shift templates unless `overwrite` is true. With `overwrite`, drops all
//! user-data tables in dependency order before re-inserting.

use autorota_core::db::queries;
use autorota_core::models::availability::{Availability, AvailabilityState};
use autorota_core::models::employee::Employee;
use autorota_core::models::shift::ShiftTemplate;
use chrono::{NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;

use crate::error::{ErrorCode, FfiError};
use crate::types::FfiSeedReport;

pub async fn seed_sample_data(
    pool: &SqlitePool,
    overwrite: bool,
) -> Result<FfiSeedReport, FfiError> {
    let employees_existing = queries::list_employees(pool).await?.len();
    let roles_existing = queries::list_roles(pool).await?.len();
    let templates_existing = queries::list_shift_templates(pool).await?.len();

    if employees_existing + roles_existing + templates_existing > 0 {
        if !overwrite {
            return Err(FfiError::InvalidArgument {
                code: ErrorCode::SeedAlreadyExists,
                msg: "database already has data; pass overwrite: true to replace".into(),
            });
        }
        clear_user_data(pool).await?;
    }

    let roles = sample_roles();
    let employees = sample_employees();
    let templates = sample_templates();

    let mut role_count = 0;
    for name in &roles {
        queries::insert_role(pool, name).await?;
        role_count += 1;
    }

    let mut employee_count = 0;
    let mut availability_slots = 0u32;
    for emp in &employees {
        availability_slots += emp.default_availability.0.len() as u32;
        queries::insert_employee(pool, emp).await?;
        employee_count += 1;
    }

    let mut template_count = 0;
    for tmpl in &templates {
        queries::insert_shift_template(pool, tmpl).await?;
        template_count += 1;
    }

    Ok(FfiSeedReport {
        employees: employee_count,
        roles: role_count,
        templates: template_count,
        availabilities: availability_slots,
    })
}

/// Hard-delete all user-owned rows in dependency-safe order. Cascades take
/// care of saves, save_tags, staged_shifts, overrides, and progress rows.
async fn clear_user_data(pool: &SqlitePool) -> Result<(), FfiError> {
    for stmt in [
        "DELETE FROM assignments",
        "DELETE FROM shifts",
        "DELETE FROM rotas",
        "DELETE FROM shift_templates",
        "DELETE FROM employees",
        "DELETE FROM roles",
    ] {
        sqlx::query(stmt).execute(pool).await?;
    }
    Ok(())
}

fn sample_roles() -> Vec<&'static str> {
    vec!["Barista", "Shift Lead", "Kitchen"]
}

fn sample_employees() -> Vec<Employee> {
    vec![
        build_employee(
            "Maya",
            "Patel",
            None,
            &["Barista"],
            32.0,
            6.0,
            8.0,
            Some(15.0),
            // Mon–Fri 06:00–18:00, weekends off
            &[
                (Weekday::Mon, 6..18),
                (Weekday::Tue, 6..18),
                (Weekday::Wed, 6..18),
                (Weekday::Thu, 6..18),
                (Weekday::Fri, 6..18),
            ],
        ),
        build_employee(
            "Jordan",
            "Kim",
            None,
            &["Barista", "Shift Lead"],
            24.0,
            6.0,
            10.0,
            Some(18.0),
            // Wed–Sun, mid-to-close
            &[
                (Weekday::Wed, 10..22),
                (Weekday::Thu, 10..22),
                (Weekday::Fri, 10..22),
                (Weekday::Sat, 8..22),
                (Weekday::Sun, 8..22),
            ],
        ),
        build_employee(
            "Sam",
            "Rivera",
            None,
            &["Kitchen"],
            30.0,
            5.0,
            9.0,
            Some(16.5),
            // Tue–Sat, prep into lunch
            &[
                (Weekday::Tue, 7..15),
                (Weekday::Wed, 7..15),
                (Weekday::Thu, 7..15),
                (Weekday::Fri, 7..15),
                (Weekday::Sat, 7..15),
            ],
        ),
        build_employee(
            "Alex",
            "Chen",
            Some("Al"),
            &["Barista"],
            16.0,
            4.0,
            6.0,
            Some(14.0),
            // Student: afternoons + weekends, no mornings
            &[
                (Weekday::Mon, 14..20),
                (Weekday::Wed, 14..20),
                (Weekday::Fri, 14..20),
                (Weekday::Sat, 10..20),
                (Weekday::Sun, 10..20),
            ],
        ),
    ]
}

#[allow(clippy::too_many_arguments)]
fn build_employee(
    first: &str,
    last: &str,
    nickname: Option<&str>,
    roles: &[&str],
    target_weekly_hours: f32,
    weekly_hours_deviation: f32,
    max_daily_hours: f32,
    hourly_wage: Option<f32>,
    yes_windows: &[(Weekday, std::ops::Range<u8>)],
) -> Employee {
    let mut avail = Availability::default();
    for (wd, range) in yes_windows {
        for hour in range.clone() {
            avail.set(*wd, hour, AvailabilityState::Yes);
        }
    }

    Employee {
        id: 0,
        first_name: first.to_string(),
        last_name: last.to_string(),
        nickname: nickname.map(str::to_string),
        roles: roles.iter().map(|r| r.to_string()).collect(),
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours,
        weekly_hours_deviation,
        max_daily_hours,
        notes: None,
        bank_details: None,
        phone: None,
        email: None,
        preferred_contact: None,
        hourly_wage,
        wage_currency: hourly_wage.map(|_| "usd".to_string()),
        default_availability: avail.clone(),
        availability: avail,
        deleted: false,
    }
}

fn sample_templates() -> Vec<ShiftTemplate> {
    vec![
        build_template(
            "Opening",
            &[
                Weekday::Mon,
                Weekday::Tue,
                Weekday::Wed,
                Weekday::Thu,
                Weekday::Fri,
            ],
            (6, 0),
            (14, 0),
            "Barista",
            1,
            2,
        ),
        build_template(
            "Mid",
            &[
                Weekday::Mon,
                Weekday::Tue,
                Weekday::Wed,
                Weekday::Thu,
                Weekday::Fri,
                Weekday::Sat,
                Weekday::Sun,
            ],
            (10, 0),
            (18, 0),
            "Barista",
            1,
            1,
        ),
        build_template(
            "Closing",
            &[
                Weekday::Mon,
                Weekday::Tue,
                Weekday::Wed,
                Weekday::Thu,
                Weekday::Fri,
                Weekday::Sat,
                Weekday::Sun,
            ],
            (14, 0),
            (22, 0),
            "Shift Lead",
            1,
            2,
        ),
        build_template(
            "Kitchen Prep",
            &[
                Weekday::Tue,
                Weekday::Wed,
                Weekday::Thu,
                Weekday::Fri,
                Weekday::Sat,
            ],
            (7, 0),
            (15, 0),
            "Kitchen",
            1,
            1,
        ),
        build_template(
            "Weekend Brunch",
            &[Weekday::Sat, Weekday::Sun],
            (8, 0),
            (13, 0),
            "Barista",
            1,
            2,
        ),
    ]
}

fn build_template(
    name: &str,
    weekdays: &[Weekday],
    start: (u32, u32),
    end: (u32, u32),
    role: &str,
    min_employees: u32,
    max_employees: u32,
) -> ShiftTemplate {
    ShiftTemplate {
        id: 0,
        name: name.to_string(),
        weekdays: weekdays.to_vec(),
        start_time: NaiveTime::from_hms_opt(start.0, start.1, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(end.0, end.1, 0).unwrap(),
        required_role: role.to_string(),
        min_employees,
        max_employees,
        deleted: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use autorota_core::db;

    async fn fresh_pool() -> SqlitePool {
        db::connect("sqlite::memory:").await.unwrap()
    }

    #[tokio::test]
    async fn seeds_into_empty_db() {
        let pool = fresh_pool().await;
        let report = seed_sample_data(&pool, false).await.unwrap();
        assert_eq!(report.roles, 3);
        assert_eq!(report.employees, 4);
        assert_eq!(report.templates, 5);
        assert!(report.availabilities > 0);

        let employees = queries::list_employees(&pool).await.unwrap();
        assert_eq!(employees.len(), 4);
        let roles = queries::list_roles(&pool).await.unwrap();
        assert_eq!(roles.len(), 3);
        let tmpls = queries::list_shift_templates(&pool).await.unwrap();
        assert_eq!(tmpls.len(), 5);
    }

    #[tokio::test]
    async fn refuses_when_db_non_empty_without_overwrite() {
        let pool = fresh_pool().await;
        seed_sample_data(&pool, false).await.unwrap();

        let err = seed_sample_data(&pool, false).await.unwrap_err();
        assert_eq!(err.code(), ErrorCode::SeedAlreadyExists);
    }

    #[tokio::test]
    async fn overwrite_replaces_existing_data() {
        let pool = fresh_pool().await;
        seed_sample_data(&pool, false).await.unwrap();
        let report = seed_sample_data(&pool, true).await.unwrap();
        assert_eq!(report.employees, 4);

        let employees = queries::list_employees(&pool).await.unwrap();
        // After overwrite, exactly the seeded set — no duplicates.
        assert_eq!(employees.len(), 4);
    }

    #[tokio::test]
    async fn refuses_when_only_roles_present() {
        let pool = fresh_pool().await;
        queries::insert_role(&pool, "Custom Role").await.unwrap();

        let err = seed_sample_data(&pool, false).await.unwrap_err();
        assert_eq!(err.code(), ErrorCode::SeedAlreadyExists);
    }

    #[tokio::test]
    async fn employees_have_realistic_availability() {
        let pool = fresh_pool().await;
        seed_sample_data(&pool, false).await.unwrap();
        let employees = queries::list_employees(&pool).await.unwrap();
        let alex = employees.iter().find(|e| e.first_name == "Alex").unwrap();
        // Alex has no morning availability (student).
        assert_eq!(
            alex.default_availability.get(Weekday::Mon, 8),
            AvailabilityState::Maybe
        );
        assert_eq!(
            alex.default_availability.get(Weekday::Mon, 15),
            AvailabilityState::Yes
        );
    }
}
