//! Debug-only sample dataset: the "default" sample.
//!
//! A larger, generically-named sibling of [`crate::demo`], meant for manual
//! testing in debug builds. Like `demo` it writes real rows so the whole app —
//! scheduler included — runs against it, and it is loaded onto a throwaway
//! database that the app swaps in and back out (see the Swift
//! `SampleDataController`). Unlike `demo` there is no guided tour, and the only
//! entry point is a `#if DEBUG` button in Settings, so it never reaches users.
//!
//! Dataset shape:
//! - 30 employees with plain first/last names, no nicknames, spread across
//!   four roles and realistic availability archetypes (openers, closers,
//!   students on evenings/weekends, school-hours staff, weekenders, on-call
//!   flex), mixing full- and part-time
//! - four roles: Barista, Kitchen, Front (cashier / front-of-house), Supervisor
//! - eight shift templates spanning a plausible cafe week, each with meaningful
//!   min/max headcount and per-role minimums (`role_requirements`)
//! - no rota / shifts / assignments — the tester presses Generate to build one

use chrono::{NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;

use crate::db::queries;
use crate::models::availability::{Availability, AvailabilityState};
use crate::models::employee::Employee;
use crate::models::shift::{RoleRequirement, ShiftTemplate};

pub const ROLE_BARISTA: &str = "Barista";
pub const ROLE_KITCHEN: &str = "Kitchen";
pub const ROLE_FRONT: &str = "Front";
pub const ROLE_SUPERVISOR: &str = "Supervisor";

const ROLES: [&str; 4] = [ROLE_BARISTA, ROLE_KITCHEN, ROLE_FRONT, ROLE_SUPERVISOR];

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

/// The sample crew. IDs are local ordinals; the seeder remaps to real row IDs.
pub fn sample_employees() -> Vec<Employee> {
    use AvailabilityState::{Maybe, No, Yes};
    use Weekday::{Fri, Mon, Sat, Sun, Thu, Tue, Wed};

    vec![
        // ── Supervisors (some double as barista / kitchen) ──────────────────
        emp(
            1,
            "Alex",
            "Carter",
            &[ROLE_SUPERVISOR, ROLE_BARISTA],
            38.0,
            15.50,
            avail(&[(&ALL_WEEK, 6, 22, Yes)]),
        ),
        emp(
            2,
            "Jordan",
            "Ellis",
            &[ROLE_SUPERVISOR, ROLE_KITCHEN],
            40.0,
            16.00,
            avail(&[(&WEEKDAYS, 6, 20, Yes), (&WEEKEND, 8, 18, Maybe)]),
        ),
        emp(
            3,
            "Morgan",
            "Reed",
            &[ROLE_SUPERVISOR, ROLE_BARISTA],
            37.0,
            15.25,
            avail(&[
                (&[Thu, Fri, Sat, Sun, Mon], 7, 21, Yes),
                (&[Tue, Wed], 6, 22, No),
            ]),
        ),
        emp(
            4,
            "Taylor",
            "Brooks",
            &[ROLE_SUPERVISOR, ROLE_FRONT],
            24.0,
            14.75,
            avail(&[(&[Fri, Sat, Sun], 8, 22, Yes), (&WEEKDAYS, 16, 22, Maybe)]),
        ),
        // ── Baristas ────────────────────────────────────────────────────────
        emp(
            5,
            "Sam",
            "Patel",
            &[ROLE_BARISTA],
            38.0,
            12.75,
            avail(&[(&ALL_WEEK, 6, 20, Yes)]),
        ),
        // Riley: student — weekday evenings plus full weekends.
        emp(
            6,
            "Riley",
            "Chen",
            &[ROLE_BARISTA],
            16.0,
            11.40,
            avail(&[
                (&WEEKDAYS, 17, 22, Yes),
                (&WEEKDAYS, 6, 17, No),
                (&WEEKEND, 8, 22, Yes),
            ]),
        ),
        // Casey: early-bird opener — mornings only.
        emp(
            7,
            "Casey",
            "Nguyen",
            &[ROLE_BARISTA],
            20.0,
            12.10,
            avail(&[
                (&WEEKDAYS, 6, 12, Yes),
                (&WEEKDAYS, 12, 15, Maybe),
                (&[Sat], 6, 12, Yes),
                (&[Sun], 6, 22, No),
            ]),
        ),
        emp(
            8,
            "Jamie",
            "Foster",
            &[ROLE_BARISTA],
            36.0,
            13.20,
            avail(&[(&ALL_WEEK, 8, 20, Yes)]),
        ),
        // Avery: weekender who also covers Friday nights.
        emp(
            9,
            "Avery",
            "Bennett",
            &[ROLE_BARISTA],
            14.0,
            11.60,
            avail(&[
                (&[Fri], 16, 22, Yes),
                (&WEEKEND, 8, 22, Yes),
                (&[Mon, Tue, Wed, Thu], 6, 22, No),
            ]),
        ),
        // Quinn: dedicated closer.
        emp(
            10,
            "Quinn",
            "Murphy",
            &[ROLE_BARISTA],
            18.0,
            11.90,
            avail(&[(&ALL_WEEK, 15, 22, Yes), (&ALL_WEEK, 6, 15, No)]),
        ),
        emp(
            11,
            "Drew",
            "Sullivan",
            &[ROLE_BARISTA, ROLE_FRONT],
            35.0,
            13.00,
            avail(&[
                (&WEEKDAYS, 9, 17, Yes),
                (&[Sat], 9, 15, Maybe),
                (&[Sun], 6, 22, No),
            ]),
        ),
        // Harper: student — two fixed evenings plus Sundays.
        emp(
            12,
            "Harper",
            "Diaz",
            &[ROLE_BARISTA],
            12.0,
            11.30,
            avail(&[
                (&[Mon, Wed], 18, 22, Yes),
                (&[Sun], 8, 20, Yes),
                (&[Tue, Thu, Fri, Sat], 6, 22, No),
            ]),
        ),
        // Emerson: school-hours — weekdays inside the school run.
        emp(
            13,
            "Emerson",
            "Walsh",
            &[ROLE_BARISTA],
            22.0,
            12.30,
            avail(&[
                (&WEEKDAYS, 9, 15, Yes),
                (&WEEKDAYS, 15, 22, No),
                (&WEEKEND, 6, 22, No),
            ]),
        ),
        emp(
            14,
            "Reese",
            "Coleman",
            &[ROLE_BARISTA, ROLE_KITCHEN],
            37.0,
            13.50,
            avail(&[(&ALL_WEEK, 7, 19, Yes)]),
        ),
        // Skylar: flexible on-call — will take anything, commits to nothing.
        emp(
            15,
            "Skylar",
            "Flores",
            &[ROLE_BARISTA],
            15.0,
            11.20,
            avail(&[(&ALL_WEEK, 6, 22, Maybe)]),
        ),
        // Rowan: mornings, firm early week, tentative later.
        emp(
            16,
            "Rowan",
            "Price",
            &[ROLE_BARISTA],
            20.0,
            12.00,
            avail(&[
                (&[Mon, Tue, Wed], 6, 13, Yes),
                (&[Thu, Fri], 6, 13, Maybe),
                (&WEEKEND, 6, 22, No),
            ]),
        ),
        emp(
            17,
            "Micah",
            "Hughes",
            &[ROLE_BARISTA],
            38.0,
            13.10,
            avail(&[(&ALL_WEEK, 13, 22, Yes), (&ALL_WEEK, 6, 13, No)]),
        ),
        // ── Kitchen ─────────────────────────────────────────────────────────
        emp(
            18,
            "Dana",
            "Rivera",
            &[ROLE_KITCHEN],
            40.0,
            14.00,
            avail(&[(&ALL_WEEK, 6, 20, Yes)]),
        ),
        emp(
            19,
            "Elliot",
            "Grant",
            &[ROLE_KITCHEN],
            37.0,
            13.75,
            avail(&[(&WEEKDAYS, 7, 19, Yes), (&WEEKEND, 8, 16, Maybe)]),
        ),
        // Frankie: kitchen opener — mornings.
        emp(
            20,
            "Frankie",
            "Long",
            &[ROLE_KITCHEN],
            18.0,
            12.20,
            avail(&[(&ALL_WEEK, 7, 14, Yes), (&ALL_WEEK, 14, 22, No)]),
        ),
        emp(
            21,
            "Gabriel",
            "Ortiz",
            &[ROLE_KITCHEN],
            22.0,
            12.40,
            avail(&[
                (&[Mon, Tue, Wed, Thu], 10, 18, Yes),
                (&[Fri], 10, 18, Maybe),
            ]),
        ),
        emp(
            22,
            "Noa",
            "Bishop",
            &[ROLE_KITCHEN, ROLE_FRONT],
            20.0,
            12.10,
            avail(&[
                (&[Wed, Thu, Fri, Sat], 9, 20, Yes),
                (&[Sun, Mon, Tue], 6, 22, No),
            ]),
        ),
        // Kai: kitchen closer.
        emp(
            23,
            "Kai",
            "Watson",
            &[ROLE_KITCHEN],
            36.0,
            13.60,
            avail(&[(&ALL_WEEK, 14, 22, Yes), (&ALL_WEEK, 6, 14, No)]),
        ),
        // Lena: weekender.
        emp(
            24,
            "Lena",
            "Fisher",
            &[ROLE_KITCHEN],
            16.0,
            11.80,
            avail(&[(&WEEKEND, 8, 20, Yes), (&WEEKDAYS, 6, 22, No)]),
        ),
        // ── Front (cashier / front-of-house) ────────────────────────────────
        emp(
            25,
            "Priya",
            "Shah",
            &[ROLE_FRONT],
            20.0,
            11.75,
            avail(&[
                (&WEEKDAYS, 8, 16, Yes),
                (&[Sat], 9, 15, Maybe),
                (&[Sun], 6, 22, No),
            ]),
        ),
        emp(
            26,
            "Oscar",
            "Dunn",
            &[ROLE_FRONT],
            35.0,
            12.50,
            avail(&[(&ALL_WEEK, 8, 20, Yes)]),
        ),
        // Ivy: student — evenings and weekends.
        emp(
            27,
            "Ivy",
            "Barrett",
            &[ROLE_FRONT],
            14.0,
            11.30,
            avail(&[
                (&[Tue, Thu], 17, 22, Yes),
                (&WEEKEND, 9, 21, Yes),
                (&[Mon, Wed, Fri], 6, 22, No),
            ]),
        ),
        emp(
            28,
            "Theo",
            "Marsh",
            &[ROLE_FRONT],
            18.0,
            11.70,
            avail(&[
                (&[Mon, Tue, Wed], 11, 19, Yes),
                (&[Thu, Fri], 11, 19, Maybe),
            ]),
        ),
        emp(
            29,
            "Nadia",
            "Khan",
            &[ROLE_FRONT, ROLE_BARISTA],
            22.0,
            12.20,
            avail(&[
                (&[Thu, Fri, Sat, Sun], 10, 21, Yes),
                (&[Mon, Tue, Wed], 6, 22, No),
            ]),
        ),
        // Leo: weekender.
        emp(
            30,
            "Leo",
            "Vance",
            &[ROLE_FRONT],
            16.0,
            11.60,
            avail(&[
                (&WEEKEND, 8, 22, Yes),
                (&[Fri], 16, 22, Maybe),
                (&[Mon, Tue, Wed, Thu], 6, 22, No),
            ]),
        ),
    ]
}

/// Eight templates spanning a plausible cafe week, with per-role minimums.
pub fn sample_templates() -> Vec<ShiftTemplate> {
    vec![
        tmpl(
            1,
            "Opening",
            7,
            11,
            &ALL_WEEK,
            2,
            4,
            &[(ROLE_SUPERVISOR, 1), (ROLE_BARISTA, 2)],
        ),
        tmpl(
            2,
            "Morning Peak",
            8,
            12,
            &ALL_WEEK,
            3,
            5,
            &[(ROLE_BARISTA, 3), (ROLE_FRONT, 1)],
        ),
        tmpl(
            3,
            "Kitchen AM",
            8,
            14,
            &ALL_WEEK,
            2,
            3,
            &[(ROLE_KITCHEN, 2)],
        ),
        tmpl(
            4,
            "Lunch Rush",
            11,
            15,
            &ALL_WEEK,
            3,
            5,
            &[(ROLE_BARISTA, 2), (ROLE_FRONT, 2)],
        ),
        tmpl(
            5,
            "Afternoon",
            14,
            18,
            &ALL_WEEK,
            2,
            3,
            &[(ROLE_BARISTA, 2)],
        ),
        tmpl(
            6,
            "Kitchen PM",
            14,
            20,
            &WEEKDAYS,
            1,
            2,
            &[(ROLE_KITCHEN, 1)],
        ),
        tmpl(
            7,
            "Close",
            17,
            21,
            &ALL_WEEK,
            2,
            3,
            &[(ROLE_SUPERVISOR, 1), (ROLE_BARISTA, 1)],
        ),
        tmpl(
            8,
            "Weekend Brunch",
            9,
            14,
            &WEEKEND,
            4,
            6,
            &[(ROLE_BARISTA, 3), (ROLE_KITCHEN, 2), (ROLE_FRONT, 1)],
        ),
    ]
}

/// Seed the sample dataset into `pool`. Expects an empty (freshly migrated)
/// database; running twice creates duplicates.
pub async fn seed_sample_debug_data(
    pool: &SqlitePool,
    _week_start: NaiveDate,
) -> Result<(), sqlx::Error> {
    for role in ROLES {
        queries::insert_role(pool, role).await?;
    }

    for emp in sample_employees() {
        queries::insert_employee(pool, &emp).await?;
    }

    for tmpl in sample_templates() {
        queries::insert_shift_template(pool, &tmpl).await?;
    }

    Ok(())
}

fn emp(
    id: i64,
    first: &str,
    last: &str,
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
        nickname: None,
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

/// Build an `Availability` from `(days, start-hour, end-hour, state)` spans,
/// applied in order.
fn avail(spans: &[(&[Weekday], u8, u8, AvailabilityState)]) -> Availability {
    let mut a = Availability::default();
    for &(days, start_h, end_h, state) in spans {
        for &wd in days {
            for h in start_h..end_h {
                a.set(wd, h, state);
            }
        }
    }
    a
}

#[allow(clippy::too_many_arguments)]
fn tmpl(
    id: i64,
    name: &str,
    start_h: u32,
    end_h: u32,
    weekdays: &[Weekday],
    min_employees: u32,
    max_employees: u32,
    role_reqs: &[(&str, u32)],
) -> ShiftTemplate {
    // The denormalized primary role is the first (highest-min) requirement.
    let required_role = role_reqs
        .first()
        .map(|(r, _)| r.to_string())
        .unwrap_or_default();
    ShiftTemplate {
        id,
        name: name.to_string(),
        weekdays: weekdays.to_vec(),
        start_time: NaiveTime::from_hms_opt(start_h, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(end_h, 0, 0).unwrap(),
        required_role,
        min_employees,
        max_employees,
        role_requirements: role_reqs
            .iter()
            .map(|&(role, min_count)| RoleRequirement {
                role: role.to_string(),
                min_count,
            })
            .collect(),
        deleted: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::shift::Shift;
    use crate::scheduler;
    use chrono::{Datelike, Duration};

    async fn seeded_pool() -> SqlitePool {
        let pool = crate::db::connect("sqlite::memory:").await.unwrap();
        seed_sample_debug_data(&pool, sample_week()).await.unwrap();
        pool
    }

    fn sample_week() -> NaiveDate {
        NaiveDate::from_ymd_opt(2099, 4, 20).unwrap() // a Monday
    }

    #[tokio::test]
    async fn seeds_thirty_employees_four_roles_eight_templates() {
        let pool = seeded_pool().await;

        let employees = queries::list_employees(&pool).await.unwrap();
        assert_eq!(employees.len(), 30);
        // Generic names only — no nicknames.
        assert!(employees.iter().all(|e| e.nickname.is_none()));

        let roles = queries::list_roles(&pool).await.unwrap();
        for r in ROLES {
            assert!(roles.iter().any(|role| role.name == r), "{r} missing");
        }

        let templates = queries::list_shift_templates(&pool).await.unwrap();
        assert_eq!(templates.len(), 8);
        // At least one template carries multiple per-role requirements.
        assert!(templates.iter().any(|t| t.role_requirements.len() >= 2));
    }

    #[tokio::test]
    async fn fulltime_and_parttime_mix() {
        let employees = sample_employees();
        let ft = employees
            .iter()
            .filter(|e| e.target_weekly_hours >= 30.0)
            .count();
        let pt = employees
            .iter()
            .filter(|e| e.target_weekly_hours < 30.0)
            .count();
        assert!(ft >= 5, "want several full-timers, got {ft}");
        assert!(pt >= 5, "want several part-timers, got {pt}");
    }

    #[tokio::test]
    async fn scheduler_fills_sample_week() {
        let week = sample_week();
        assert_eq!(week.weekday(), Weekday::Mon);
        let pool = seeded_pool().await;

        // Materialise the week's shifts from templates, mirroring the app's
        // run-schedule flow before scheduling.
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
            "scheduler produced no assignments for the sample week"
        );
    }
}
