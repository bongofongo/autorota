#![allow(dead_code)]

use autorota_core::db;
use autorota_core::models::availability::{Availability, AvailabilityState};
use autorota_core::models::employee::Employee;
use autorota_core::models::shift::Shift;
use chrono::{NaiveDate, NaiveTime, Weekday};

/// Creates a NaiveDate in March 2026 (23=Mon, 24=Tue, ...).
pub fn date(d: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 3, d).unwrap()
}

/// Creates a NaiveTime at the given hour (minute 0).
pub fn time(h: u32) -> NaiveTime {
    NaiveTime::from_hms_opt(h, 0, 0).unwrap()
}

/// Returns Monday 2026-03-23 — a convenient week start for tests.
pub fn week_start() -> NaiveDate {
    date(23)
}

/// Build a test employee with uniform availability across weekdays 6–22h.
pub fn make_employee(id: i64, name: &str, role: &str, avail_state: AvailabilityState) -> Employee {
    let mut avail = Availability::default();
    for day in [
        Weekday::Mon,
        Weekday::Tue,
        Weekday::Wed,
        Weekday::Thu,
        Weekday::Fri,
    ] {
        for h in 6..22 {
            avail.set(day, h, avail_state);
        }
    }
    Employee {
        id,
        first_name: name.to_string(),
        last_name: String::new(),
        nickname: None,
        roles: vec![role.to_string()],
        start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        target_weekly_hours: 40.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 8.0,
        notes: None,
        bank_details: None,
        default_availability: avail.clone(),
        availability: avail,
        deleted: false,
    }
}

/// Build a test shift with the given parameters.
pub fn make_shift(id: i64, date: NaiveDate, start: u32, end: u32, role: &str) -> Shift {
    Shift {
        id,
        template_id: Some(1),
        rota_id: 1,
        date,
        start_time: time(start),
        end_time: time(end),
        required_role: role.to_string(),
        min_employees: 1,
        max_employees: 1,
    }
}

/// Create an in-memory SQLite pool with all migrations applied.
pub async fn test_pool() -> sqlx::SqlitePool {
    db::connect("sqlite::memory:").await.unwrap()
}
