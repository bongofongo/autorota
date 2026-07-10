//! Demo-mode dataset: the planet crew.
//!
//! Seeds a throwaway database for the guided pre-purchase demo. Unlike
//! [`crate::sample`] (in-memory, export-preview only) this writes real rows so
//! the whole app — scheduler included — runs against it. Unlike
//! `testutil::corpus` it ships in release builds.
//!
//! Dataset shape is part of the demo script:
//! - 12 employees nicknamed after solar bodies (the eight planets plus Luna,
//!   Titan, Pluto, and Ceres), mixing full- and part-time
//! - two roles (Barista, Kitchen), several employees holding both
//! - Mercury's availability is deliberately left unset — the tour's first
//!   hands-on step has the user fill it in
//! - Neptune carries pre-seeded `Exception` overrides (two days off in the
//!   demo week); the tour has the user create one for Mars
//! - no rota / shifts / assignments — generating the rota is a tour step

use chrono::{Duration, NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;

use crate::db::queries;
use crate::models::availability::{Availability, AvailabilityState};
use crate::models::employee::Employee;
use crate::models::overrides::{DayAvailability, EmployeeAvailabilityOverride, OverrideSource};
use crate::models::shift::{RoleRequirement, ShiftTemplate};

pub const ROLE_BARISTA: &str = "Barista";
pub const ROLE_KITCHEN: &str = "Kitchen";

/// Nickname of the employee whose availability the tour has the user fill in.
pub const TOUR_AVAILABILITY_NICKNAME: &str = "Mercury";
/// Nickname of the employee the tour has the user create an exception for.
pub const TOUR_EXCEPTION_NICKNAME: &str = "Mars";
/// Nickname of the employee seeded with ready-made exception overrides.
pub const SEEDED_EXCEPTION_NICKNAME: &str = "Neptune";

const ALL_WEEK: [Weekday; 7] = [
    Weekday::Mon,
    Weekday::Tue,
    Weekday::Wed,
    Weekday::Thu,
    Weekday::Fri,
    Weekday::Sat,
    Weekday::Sun,
];

const WEEKDAYS: [Weekday; 5] = [
    Weekday::Mon,
    Weekday::Tue,
    Weekday::Wed,
    Weekday::Thu,
    Weekday::Fri,
];

const WEEKEND: [Weekday; 2] = [Weekday::Sat, Weekday::Sun];

/// The planet crew. IDs are local ordinals; the seeder remaps to real row IDs.
pub fn demo_employees() -> Vec<Employee> {
    vec![
        // Mercury: availability intentionally unset — tour step fills it.
        emp(
            1,
            "May",
            "Herrera",
            "Mercury",
            &[ROLE_BARISTA],
            12.0,
            11.50,
            Availability::default(),
        ),
        emp(
            2,
            "Vera",
            "Nguyen",
            "Venus",
            &[ROLE_BARISTA],
            38.0,
            12.25,
            {
                let mut a = Availability::default();
                set_hours(
                    &mut a,
                    &[
                        Weekday::Mon,
                        Weekday::Tue,
                        Weekday::Wed,
                        Weekday::Thu,
                        Weekday::Fri,
                        Weekday::Sat,
                    ],
                    7,
                    20,
                    AvailabilityState::Yes,
                );
                set_hours(&mut a, &[Weekday::Sun], 6, 22, AvailabilityState::No);
                a
            },
        ),
        emp(
            3,
            "Earl",
            "Thompson",
            "Earth",
            &[ROLE_BARISTA, ROLE_KITCHEN],
            40.0,
            13.75,
            {
                let mut a = Availability::default();
                set_hours(&mut a, &ALL_WEEK, 6, 22, AvailabilityState::Yes);
                a
            },
        ),
        // Mars: works a short weekday pattern — tour step gives him a day off.
        emp(4, "Marcus", "Reid", "Mars", &[ROLE_KITCHEN], 16.0, 12.00, {
            let mut a = Availability::default();
            set_hours(
                &mut a,
                &[Weekday::Mon, Weekday::Wed, Weekday::Fri],
                8,
                16,
                AvailabilityState::Yes,
            );
            set_hours(
                &mut a,
                &[Weekday::Tue, Weekday::Thu],
                6,
                22,
                AvailabilityState::No,
            );
            a
        }),
        emp(5, "Jun", "Osei", "Jupiter", &[ROLE_KITCHEN], 38.0, 13.50, {
            let mut a = Availability::default();
            set_hours(&mut a, &WEEKDAYS, 6, 20, AvailabilityState::Yes);
            set_hours(&mut a, &WEEKEND, 6, 22, AvailabilityState::No);
            a
        }),
        emp(
            6,
            "Sadie",
            "Turner",
            "Saturn",
            &[ROLE_BARISTA, ROLE_KITCHEN],
            14.0,
            12.50,
            {
                let mut a = Availability::default();
                set_hours(&mut a, &WEEKEND, 8, 21, AvailabilityState::Yes);
                set_hours(&mut a, &WEEKDAYS, 6, 22, AvailabilityState::No);
                a
            },
        ),
        emp(7, "Uma", "Novak", "Uranus", &[ROLE_BARISTA], 20.0, 11.75, {
            let mut a = Availability::default();
            set_hours(&mut a, &ALL_WEEK, 16, 22, AvailabilityState::Yes);
            set_hours(&mut a, &ALL_WEEK, 6, 16, AvailabilityState::Maybe);
            a
        }),
        emp(
            8,
            "Nadia",
            "Petrov",
            "Neptune",
            &[ROLE_BARISTA],
            35.0,
            13.00,
            {
                let mut a = Availability::default();
                set_hours(
                    &mut a,
                    &[
                        Weekday::Tue,
                        Weekday::Wed,
                        Weekday::Thu,
                        Weekday::Fri,
                        Weekday::Sat,
                        Weekday::Sun,
                    ],
                    8,
                    20,
                    AvailabilityState::Yes,
                );
                set_hours(&mut a, &[Weekday::Mon], 6, 22, AvailabilityState::No);
                a
            },
        ),
        // Beyond the planets: moons and dwarf planets round out the crew.
        emp(
            9,
            "Lucy",
            "Nakamura",
            "Luna",
            &[ROLE_BARISTA],
            10.0,
            11.25,
            {
                let mut a = Availability::default();
                set_hours(&mut a, &WEEKEND, 7, 16, AvailabilityState::Yes);
                set_hours(&mut a, &WEEKDAYS, 6, 22, AvailabilityState::No);
                a
            },
        ),
        emp(
            10,
            "Tiana",
            "Okafor",
            "Titan",
            &[ROLE_BARISTA, ROLE_KITCHEN],
            36.0,
            13.25,
            {
                let mut a = Availability::default();
                set_hours(&mut a, &ALL_WEEK, 8, 20, AvailabilityState::Yes);
                a
            },
        ),
        emp(
            11,
            "Paul",
            "Larsen",
            "Pluto",
            &[ROLE_KITCHEN],
            8.0,
            11.00,
            {
                // Smallest contract on the roster — fitting for a dwarf planet.
                let mut a = Availability::default();
                set_hours(
                    &mut a,
                    &[Weekday::Tue, Weekday::Thu],
                    8,
                    14,
                    AvailabilityState::Yes,
                );
                set_hours(&mut a, &WEEKEND, 6, 22, AvailabilityState::No);
                a
            },
        ),
        emp(
            12,
            "Cesar",
            "Ibarra",
            "Ceres",
            &[ROLE_KITCHEN],
            18.0,
            12.10,
            {
                let mut a = Availability::default();
                set_hours(
                    &mut a,
                    &[Weekday::Mon, Weekday::Tue, Weekday::Wed],
                    8,
                    18,
                    AvailabilityState::Yes,
                );
                set_hours(&mut a, &WEEKEND, 6, 22, AvailabilityState::Maybe);
                a
            },
        ),
    ]
}

/// Five templates spanning both roles; min 1 / max 2 staff each.
pub fn demo_templates() -> Vec<ShiftTemplate> {
    vec![
        tmpl(1, "Opening", ROLE_BARISTA, 7, 12, &ALL_WEEK),
        tmpl(2, "Midday", ROLE_BARISTA, 11, 16, &ALL_WEEK),
        tmpl(3, "Close", ROLE_BARISTA, 16, 21, &ALL_WEEK),
        tmpl(4, "Kitchen AM", ROLE_KITCHEN, 8, 14, &ALL_WEEK),
        tmpl(5, "Kitchen PM", ROLE_KITCHEN, 14, 20, &WEEKDAYS),
    ]
}

/// Neptune's ready-made exceptions: off Wednesday + Thursday of the demo week.
/// `employee_id` is the local ordinal (8); the seeder remaps it.
pub fn demo_exceptions(week_start: NaiveDate) -> Vec<EmployeeAvailabilityOverride> {
    [2i64, 3]
        .into_iter()
        .enumerate()
        .map(|(i, day_offset)| {
            let mut day = DayAvailability::default();
            for h in 6..22u8 {
                day.set(h, AvailabilityState::No);
            }
            EmployeeAvailabilityOverride {
                id: (i as i64) + 1,
                employee_id: 8, // Neptune
                date: week_start + Duration::days(day_offset),
                availability: day,
                notes: Some("Away at a conference".to_string()),
                source: OverrideSource::Exception,
            }
        })
        .collect()
}

/// Seed the planet-crew dataset into `pool`. Expects an empty (freshly
/// migrated) database; running twice creates duplicates.
pub async fn seed_demo_data(pool: &SqlitePool, week_start: NaiveDate) -> Result<(), sqlx::Error> {
    for role in [ROLE_BARISTA, ROLE_KITCHEN] {
        queries::insert_role(pool, role).await?;
    }

    let mut emp_id_map = std::collections::HashMap::new();
    for emp in demo_employees() {
        let new_id = queries::insert_employee(pool, &emp).await?;
        emp_id_map.insert(emp.id, new_id);
    }

    for tmpl in demo_templates() {
        queries::insert_shift_template(pool, &tmpl).await?;
    }

    for mut ovr in demo_exceptions(week_start) {
        ovr.employee_id = emp_id_map[&ovr.employee_id];
        queries::upsert_employee_availability_override(pool, &ovr).await?;
    }

    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn emp(
    id: i64,
    first: &str,
    last: &str,
    nickname: &str,
    roles: &[&str],
    target_hours: f32,
    wage: f32,
    availability: Availability,
) -> Employee {
    let part_time = target_hours < 30.0;
    Employee {
        id,
        first_name: first.to_string(),
        last_name: last.to_string(),
        nickname: Some(nickname.to_string()),
        roles: roles.iter().map(|r| r.to_string()).collect(),
        start_date: NaiveDate::from_ymd_opt(2025, 1, 6).unwrap(),
        target_weekly_hours: target_hours,
        weekly_hours_deviation: if part_time { 4.0 } else { 6.0 },
        max_daily_hours: if part_time { 8.0 } else { 10.0 },
        notes: None,
        bank_details: None,
        phone: None,
        email: None,
        preferred_contact: None,
        hourly_wage: Some(wage),
        wage_currency: Some("gbp".to_string()),
        default_availability: availability.clone(),
        availability,
        deleted: false,
    }
}

fn set_hours(
    a: &mut Availability,
    days: &[Weekday],
    start_h: u8,
    end_h: u8,
    state: AvailabilityState,
) {
    for &wd in days {
        for h in start_h..end_h {
            a.set(wd, h, state);
        }
    }
}

fn tmpl(
    id: i64,
    name: &str,
    role: &str,
    start_h: u32,
    end_h: u32,
    weekdays: &[Weekday],
) -> ShiftTemplate {
    ShiftTemplate {
        id,
        name: name.to_string(),
        weekdays: weekdays.to_vec(),
        start_time: NaiveTime::from_hms_opt(start_h, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(end_h, 0, 0).unwrap(),
        required_role: role.to_string(),
        min_employees: 1,
        max_employees: 2,
        role_requirements: vec![RoleRequirement {
            role: role.to_string(),
            min_count: 1,
        }],
        deleted: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::shift::Shift;
    use crate::scheduler;
    use chrono::Datelike;

    async fn seeded_pool(week_start: NaiveDate) -> SqlitePool {
        let pool = crate::db::connect("sqlite::memory:").await.unwrap();
        seed_demo_data(&pool, week_start).await.unwrap();
        pool
    }

    fn demo_week() -> NaiveDate {
        NaiveDate::from_ymd_opt(2099, 4, 20).unwrap() // a Monday
    }

    #[tokio::test]
    async fn seeds_full_planet_crew() {
        let pool = seeded_pool(demo_week()).await;
        let employees = queries::list_employees(&pool).await.unwrap();
        assert_eq!(employees.len(), 12);

        let nicknames: Vec<&str> = employees
            .iter()
            .filter_map(|e| e.nickname.as_deref())
            .collect();
        for body in [
            "Mercury", "Venus", "Earth", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune", "Luna",
            "Titan", "Pluto", "Ceres",
        ] {
            assert!(nicknames.contains(&body), "{body} missing");
        }

        let roles = queries::list_roles(&pool).await.unwrap();
        assert!(roles.len() >= 2);

        let templates = queries::list_shift_templates(&pool).await.unwrap();
        assert_eq!(templates.len(), 5);
        assert!(templates.iter().any(|t| t.required_role == ROLE_KITCHEN));
    }

    #[tokio::test]
    async fn mercury_availability_is_unset() {
        let pool = seeded_pool(demo_week()).await;
        let employees = queries::list_employees(&pool).await.unwrap();
        let mercury = employees
            .iter()
            .find(|e| e.nickname.as_deref() == Some(TOUR_AVAILABILITY_NICKNAME))
            .unwrap();
        assert!(
            mercury.default_availability.0.is_empty(),
            "Mercury must start with a blank availability grid for the tour"
        );
    }

    #[tokio::test]
    async fn neptune_has_seeded_exceptions_in_week() {
        let week = demo_week();
        let pool = seeded_pool(week).await;
        let employees = queries::list_employees(&pool).await.unwrap();
        let neptune_id = employees
            .iter()
            .find(|e| e.nickname.as_deref() == Some(SEEDED_EXCEPTION_NICKNAME))
            .unwrap()
            .id;
        let overrides = queries::list_employee_availability_overrides_in_range(
            &pool,
            week,
            week + Duration::days(7),
        )
        .await
        .unwrap();
        let neptune_exceptions: Vec<_> = overrides
            .iter()
            .filter(|o| o.employee_id == neptune_id && o.source == OverrideSource::Exception)
            .collect();
        assert_eq!(neptune_exceptions.len(), 2);
    }

    #[tokio::test]
    async fn fulltime_and_parttime_mix() {
        let employees = demo_employees();
        let ft = employees
            .iter()
            .filter(|e| e.target_weekly_hours >= 30.0)
            .count();
        let pt = employees
            .iter()
            .filter(|e| e.target_weekly_hours < 30.0)
            .count();
        assert!(ft >= 3, "want several full-timers, got {ft}");
        assert!(pt >= 3, "want several part-timers, got {pt}");
    }

    #[tokio::test]
    async fn scheduler_fills_demo_week() {
        let week = demo_week();
        assert_eq!(week.weekday(), Weekday::Mon);
        let pool = seeded_pool(week).await;

        // Materialise the week's shifts from templates, mirroring what the
        // app's run-schedule flow does before scheduling.
        let rota_id = queries::insert_rota(&pool, week).await.unwrap();
        let templates = queries::list_shift_templates(&pool).await.unwrap();
        for tmpl in &templates {
            for d in 0..7 {
                let date = week + Duration::days(d);
                if !tmpl.weekdays.contains(&date.weekday()) {
                    continue;
                }
                let shift = Shift {
                    id: 0,
                    template_id: Some(tmpl.id),
                    rota_id,
                    date,
                    start_time: tmpl.start_time,
                    end_time: tmpl.end_time,
                    required_role: tmpl.required_role.clone(),
                    min_employees: tmpl.min_employees,
                    max_employees: tmpl.max_employees,
                    role_requirements: tmpl.role_requirements.clone(),
                };
                queries::insert_shift(&pool, &shift).await.unwrap();
            }
        }

        let result = scheduler::schedule(&pool, rota_id).await.unwrap();
        assert!(
            !result.assignments.is_empty(),
            "scheduler produced no assignments for the demo week"
        );
    }
}
