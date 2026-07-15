//! Debug-only sample dataset: the "default" sample.
//!
//! Seeds a throwaway database (swapped in by the Swift `SampleDataController`)
//! to look like a real manager has run a small coffee-and-food restaurant
//! through the app for 3+ months. Debug-only: the sole entry point is a
//! `#if DEBUG` button in Settings, so it never reaches users.
//!
//! What it seeds (all anchored on the `week_start` passed from the app — the
//! current Monday):
//! - 18 employees with plain first/last names (the *same* roster every week),
//!   across three roles: Barista, Kitchen, Supervisor. Each has a realistic
//!   weekly availability persona — full-timers with fixed days off, students
//!   on evenings/weekends, dedicated openers/closers, weekenders — chosen so
//!   every shift/role still has at least one fully-available candidate daily.
//!   Every persona is bounded to a personal daily working window (e.g. an
//!   early bird's 04:00–15:00, a closer's 15:00–22:00); hours outside the
//!   window are explicitly unavailable rather than left at `Maybe`.
//! - ~7 shift templates for a small restaurant open ~07:00–21:00, with per-role
//!   minimums and varied min/max headcount.
//! - A history of availability exceptions (sick days, holidays) scattered
//!   across the past ~3 months, plus a few upcoming ones.
//! - A few historical shift-template overrides (an early close, a cancelled
//!   brunch).
//! - 16 weekly rotas — 13 past weeks + the current week + 2 ahead — each
//!   materialised and scheduled. Past & current weeks are `Confirmed`; the two
//!   future weeks stay `Proposed` (draft). This populates the analytics
//!   dashboard over the whole range.
//! - Backdated saves: one per past/current week (dated the weekend before),
//!   with a second "edit" save on a handful of weeks so the Edit Log shows
//!   real diffs.

use chrono::{Duration, NaiveDate, NaiveTime, Weekday};
use sqlx::SqlitePool;

use crate::db::queries;
use crate::models::assignment::AssignmentStatus;
use crate::models::availability::{Availability, AvailabilityState};
use crate::models::employee::Employee;
use crate::models::overrides::{
    DayAvailability, EmployeeAvailabilityOverride, OverrideSource, ShiftTemplateOverride,
};
use crate::models::shift::{RoleRequirement, ShiftTemplate};

pub const ROLE_BARISTA: &str = "Barista";
pub const ROLE_KITCHEN: &str = "Kitchen";
pub const ROLE_SUPERVISOR: &str = "Supervisor";

const ROLES: [&str; 3] = [ROLE_BARISTA, ROLE_KITCHEN, ROLE_SUPERVISOR];

/// How far the fabricated history reaches, in weeks either side of the anchor.
const PAST_WEEKS: i64 = 13;
const FUTURE_WEEKS: i64 = 2;

/// Past-week offsets that get a second "edit" save (a staff drop), so the Edit
/// Log shows a real mid-week diff rather than only the initial creation.
const EDIT_WEEK_OFFSETS: [i64; 5] = [-11, -8, -5, -3, -1];

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

/// The sample crew — 18 employees. IDs are local ordinals; the seeder remaps
/// them to real row IDs.
pub fn sample_employees() -> Vec<Employee> {
    use AvailabilityState::{Maybe, No, Yes};
    use Weekday::{Fri, Mon, Sat, Sun, Thu, Tue, Wed};

    vec![
        // ── Supervisors (all double as barista or kitchen) ──────────────────
        // Alex: general manager pattern — long 06–22 window, works Tue–Sat,
        // off Sun/Mon.
        emp(
            1,
            "Alex",
            "Carter",
            &[ROLE_SUPERVISOR, ROLE_BARISTA],
            38.0,
            15.50,
            avail(
                (6, 22),
                &[
                    (&[Tue, Wed, Thu, Fri, Sat], 6, 22, Yes),
                    (&[Sun, Mon], 0, 24, No),
                ],
            ),
        ),
        // Morgan: 07–21 window on the Thu–Mon rotation, off Tue/Wed.
        emp(
            2,
            "Morgan",
            "Reed",
            &[ROLE_SUPERVISOR, ROLE_BARISTA],
            37.0,
            15.25,
            avail(
                (7, 21),
                &[
                    (&[Thu, Fri, Sat, Sun, Mon], 7, 21, Yes),
                    (&[Tue, Wed], 0, 24, No),
                ],
            ),
        ),
        // Jordan: 06–21 window, firm weekdays, weekends only tentatively.
        emp(
            3,
            "Jordan",
            "Ellis",
            &[ROLE_SUPERVISOR, ROLE_KITCHEN],
            40.0,
            16.00,
            avail(
                (6, 21),
                &[(&WEEKDAYS, 6, 20, Yes), (&WEEKEND, 8, 18, Maybe)],
            ),
        ),
        // ── Baristas ────────────────────────────────────────────────────────
        // Sam: dependable full-timer — 07–19 window, six days, Sundays off.
        emp(
            4,
            "Sam",
            "Patel",
            &[ROLE_BARISTA],
            38.0,
            12.75,
            avail(
                (7, 19),
                &[
                    (&[Mon, Tue, Wed, Thu, Fri, Sat], 7, 19, Yes),
                    (&[Sun], 0, 24, No),
                ],
            ),
        ),
        // Riley: student — 08–22 window; weekday evenings, a free Tuesday
        // afternoon, plus full weekends.
        emp(
            5,
            "Riley",
            "Chen",
            &[ROLE_BARISTA],
            16.0,
            11.40,
            avail(
                (8, 22),
                &[
                    (&WEEKDAYS, 8, 17, No),
                    (&WEEKDAYS, 17, 22, Yes),
                    (&[Tue], 14, 22, Yes),
                    (&WEEKEND, 8, 22, Yes),
                ],
            ),
        ),
        // Casey: true early bird — 04–15 window, mornings only, Sundays off.
        emp(
            6,
            "Casey",
            "Nguyen",
            &[ROLE_BARISTA],
            20.0,
            12.10,
            avail(
                (4, 15),
                &[
                    (&WEEKDAYS, 6, 12, Yes),
                    (&WEEKDAYS, 12, 15, Maybe),
                    (&[Sat], 6, 12, Yes),
                    (&[Sun], 0, 24, No),
                ],
            ),
        ),
        // Jamie: full-timer — 07–20 window on the Wed–Sun rotation.
        emp(
            7,
            "Jamie",
            "Foster",
            &[ROLE_BARISTA],
            36.0,
            13.20,
            avail(
                (7, 20),
                &[
                    (&[Wed, Thu, Fri, Sat, Sun], 7, 20, Yes),
                    (&[Mon, Tue], 0, 24, No),
                ],
            ),
        ),
        // Avery: weekender — 08–22 window, plus Friday nights.
        emp(
            8,
            "Avery",
            "Bennett",
            &[ROLE_BARISTA],
            18.0,
            11.60,
            avail(
                (8, 22),
                &[
                    (&[Fri], 16, 22, Yes),
                    (&WEEKEND, 8, 22, Yes),
                    (&[Mon, Tue, Wed, Thu], 0, 24, No),
                ],
            ),
        ),
        // Quinn: dedicated closer — 14–22 window, six afternoons-to-close,
        // Sundays only if pressed.
        emp(
            9,
            "Quinn",
            "Murphy",
            &[ROLE_BARISTA],
            18.0,
            11.90,
            avail(
                (14, 22),
                &[
                    (&[Mon, Tue, Wed, Thu, Fri, Sat], 14, 22, Yes),
                    (&[Sun], 14, 22, Maybe),
                ],
            ),
        ),
        // Harper: student — 08–22 window; two fixed evenings plus Sundays.
        emp(
            10,
            "Harper",
            "Diaz",
            &[ROLE_BARISTA],
            16.0,
            11.30,
            avail(
                (8, 22),
                &[
                    (&[Mon, Wed], 18, 22, Yes),
                    (&[Sun], 8, 20, Yes),
                    (&[Tue, Thu, Fri, Sat], 0, 24, No),
                ],
            ),
        ),
        // Rowan: early riser — 05–13 window; firm early week, tentative later.
        emp(
            11,
            "Rowan",
            "Price",
            &[ROLE_BARISTA],
            20.0,
            12.00,
            avail(
                (5, 13),
                &[
                    (&[Mon, Tue, Wed], 6, 13, Yes),
                    (&[Thu, Fri], 6, 13, Maybe),
                    (&WEEKEND, 0, 24, No),
                ],
            ),
        ),
        // ── Kitchen ─────────────────────────────────────────────────────────
        // Dana: full-time weekday cook — 06–18 window; Saturday at a pinch,
        // never Sunday.
        emp(
            12,
            "Dana",
            "Rivera",
            &[ROLE_KITCHEN],
            40.0,
            14.00,
            avail(
                (6, 18),
                &[
                    (&WEEKDAYS, 6, 18, Yes),
                    (&[Sat], 7, 15, Maybe),
                    (&[Sun], 0, 24, No),
                ],
            ),
        ),
        // Elliot: 07–21 window — Mon–Thu plus Saturday, Fridays off, Sunday
        // only tentatively.
        emp(
            13,
            "Elliot",
            "Grant",
            &[ROLE_KITCHEN],
            37.0,
            13.75,
            avail(
                (7, 21),
                &[
                    (&[Mon, Tue, Wed, Thu], 7, 19, Yes),
                    (&[Sat], 8, 16, Yes),
                    (&[Sun], 8, 16, Maybe),
                    (&[Fri], 0, 24, No),
                ],
            ),
        ),
        // Frankie: kitchen opener — 05–14 window, Fri–Sun mornings (the busy
        // end of the week), Mon–Thu off.
        emp(
            14,
            "Frankie",
            "Long",
            &[ROLE_KITCHEN],
            18.0,
            12.20,
            avail(
                (5, 14),
                &[
                    (&[Fri, Sat, Sun], 7, 14, Yes),
                    (&[Mon, Tue, Wed, Thu], 0, 24, No),
                ],
            ),
        ),
        // Gabriel: mid-shifts — 10–18 window Mon–Thu plus Sundays; second job
        // takes Fridays tentative and Saturdays entirely.
        emp(
            15,
            "Gabriel",
            "Ortiz",
            &[ROLE_KITCHEN],
            22.0,
            12.40,
            avail(
                (10, 18),
                &[
                    (&[Mon, Tue, Wed, Thu, Sun], 10, 18, Yes),
                    (&[Fri], 10, 18, Maybe),
                    (&[Sat], 0, 24, No),
                ],
            ),
        ),
        // Kai: kitchen closer — 14–22 window, six evenings, Mondays only
        // reluctantly.
        emp(
            16,
            "Kai",
            "Watson",
            &[ROLE_KITCHEN],
            36.0,
            13.60,
            avail(
                (14, 22),
                &[
                    (&[Tue, Wed, Thu, Fri, Sat, Sun], 14, 22, Yes),
                    (&[Mon], 14, 22, Maybe),
                ],
            ),
        ),
        // Lena: weekender — 08–20 window, weekend days only.
        emp(
            17,
            "Lena",
            "Fisher",
            &[ROLE_KITCHEN],
            20.0,
            11.80,
            avail((8, 20), &[(&WEEKEND, 8, 20, Yes), (&WEEKDAYS, 0, 24, No)]),
        ),
        // Reese: flexes across both coffee and food — 07–19 window, weekdays,
        // Saturday at a push.
        emp(
            18,
            "Reese",
            "Coleman",
            &[ROLE_BARISTA, ROLE_KITCHEN],
            37.0,
            13.50,
            avail(
                (7, 19),
                &[
                    (&WEEKDAYS, 7, 19, Yes),
                    (&[Sat], 8, 18, Maybe),
                    (&[Sun], 0, 24, No),
                ],
            ),
        ),
    ]
}

/// Seven templates for a small coffee-and-food restaurant (open ~07:00–21:00),
/// with per-role minimums and modest headcount so most weeks staff cleanly.
pub fn sample_templates() -> Vec<ShiftTemplate> {
    vec![
        tmpl(
            1,
            "Opening",
            7,
            11,
            &ALL_WEEK,
            2,
            3,
            &[(ROLE_SUPERVISOR, 1), (ROLE_BARISTA, 1)],
        ),
        // Weekdays only — on weekends the Brunch crew covers the morning
        // kitchen instead.
        tmpl(
            2,
            "Kitchen AM",
            8,
            14,
            &WEEKDAYS,
            1,
            2,
            &[(ROLE_KITCHEN, 1)],
        ),
        tmpl(
            3,
            "Lunch",
            11,
            15,
            &ALL_WEEK,
            3,
            4,
            &[(ROLE_BARISTA, 2), (ROLE_KITCHEN, 1)],
        ),
        tmpl(
            4,
            "Afternoon",
            14,
            18,
            &ALL_WEEK,
            1,
            2,
            &[(ROLE_BARISTA, 1)],
        ),
        tmpl(
            5,
            "Kitchen PM",
            16,
            21,
            &ALL_WEEK,
            1,
            2,
            &[(ROLE_KITCHEN, 1)],
        ),
        tmpl(
            6,
            "Close",
            17,
            21,
            &ALL_WEEK,
            2,
            3,
            &[(ROLE_SUPERVISOR, 1), (ROLE_BARISTA, 1)],
        ),
        tmpl(
            7,
            "Weekend Brunch",
            9,
            14,
            &WEEKEND,
            3,
            4,
            &[(ROLE_BARISTA, 2), (ROLE_KITCHEN, 1)],
        ),
    ]
}

/// Availability exceptions (day-off overrides), each anchored on `anchor` by a
/// `(week_offset, day_offset)` pair. `employee_id` is a local ordinal — the
/// seeder remaps it. Negative week offsets are the past history; positive ones
/// are upcoming.
fn sample_exceptions(anchor: NaiveDate) -> Vec<EmployeeAvailabilityOverride> {
    // (employee ordinal, week offset, day-of-week offset, note)
    const HISTORY: [(i64, i64, i64, &str); 19] = [
        // Past ~3 months.
        (5, -12, 1, "Sick day"),
        (17, -11, 6, "Sick day"),
        (7, -10, 5, "Family event"),
        (18, -9, 5, "Holiday — away"),
        (4, -8, 2, "Personal day"),
        (14, -7, 4, "Holiday"),
        (6, -6, 1, "Dentist"),
        (15, -6, 3, "Sick day"),
        (16, -5, 6, "Sick day"),
        (8, -4, 5, "Away"),
        (3, -4, 1, "Conference"),
        (11, -3, 2, "Sick day"),
        (13, -2, 3, "Holiday — away"),
        (10, -1, 4, "Personal day"),
        (9, -9, 0, "Sick day"),
        (12, -11, 3, "Holiday — away"),
        // Upcoming.
        (5, 1, 2, "Booked holiday"),
        (4, 1, 4, "Dentist appointment"),
        (12, 2, 3, "Holiday — away"),
    ];

    HISTORY
        .iter()
        .enumerate()
        .map(|(i, &(emp, wk, day, note))| {
            let date = anchor + Duration::days(wk * 7 + day);
            off_day((i as i64) + 1, emp, date, note)
        })
        .collect()
}

/// A few historical shift-template overrides (early closes / cancellations).
/// `template_id` is a local ordinal — the seeder remaps it.
fn sample_template_overrides(anchor: NaiveDate) -> Vec<ShiftTemplateOverride> {
    let mk = |id: i64,
              template: i64,
              wk: i64,
              day: i64,
              cancelled: bool,
              max: Option<u32>,
              note: &str| {
        ShiftTemplateOverride {
            id,
            template_id: template,
            date: anchor + Duration::days(wk * 7 + day),
            cancelled,
            start_time: None,
            end_time: None,
            min_employees: None,
            max_employees: max,
            notes: Some(note.to_string()),
        }
    };
    vec![
        // Close cancelled on a bank-holiday Monday (early close).
        mk(1, 6, -6, 0, true, None, "Bank holiday — closed early"),
        // Weekend brunch cancelled for a private event.
        mk(2, 7, -8, 6, true, None, "Private event"),
        // Quiet Saturday lunch — capped smaller.
        mk(3, 3, -3, 5, false, Some(2), "Quiet Saturday"),
    ]
}

/// Seed the full sample dataset (roster + 3-month history) into `pool`.
/// Expects an empty (freshly migrated) database; running twice creates
/// duplicates. `anchor` is the current-week Monday the history centres on.
pub async fn seed_sample_debug_data(
    pool: &SqlitePool,
    anchor: NaiveDate,
) -> Result<(), sqlx::Error> {
    use std::collections::HashMap;

    // Roles, employees, templates — remembering the real IDs so overrides can
    // reference them.
    for role in ROLES {
        queries::insert_role(pool, role).await?;
    }

    let mut emp_id_map: HashMap<i64, i64> = HashMap::new();
    for emp in sample_employees() {
        let new_id = queries::insert_employee(pool, &emp).await?;
        emp_id_map.insert(emp.id, new_id);
    }

    let mut tmpl_id_map: HashMap<i64, i64> = HashMap::new();
    for tmpl in sample_templates() {
        let new_id = queries::insert_shift_template(pool, &tmpl).await?;
        tmpl_id_map.insert(tmpl.id, new_id);
    }

    // Exceptions & template overrides up front — they're date-keyed, so they're
    // in place before each week is materialised/scheduled and thus bake into
    // that week's assignments.
    for mut ovr in sample_exceptions(anchor) {
        ovr.employee_id = emp_id_map[&ovr.employee_id];
        queries::upsert_employee_availability_override(pool, &ovr).await?;
    }
    for mut ovr in sample_template_overrides(anchor) {
        ovr.template_id = tmpl_id_map[&ovr.template_id];
        queries::upsert_shift_template_override(pool, &ovr).await?;
    }

    // Generate every week: 13 past + current + 2 future.
    for offset in -PAST_WEEKS..=FUTURE_WEEKS {
        let week = anchor + Duration::days(offset * 7);
        let is_history = offset <= 0; // past + current

        let rota_id = queries::insert_rota(pool, week).await?;
        queries::materialise_shifts(pool, rota_id, week).await?;
        crate::scheduler::schedule(pool, rota_id)
            .await
            .map_err(|e| sqlx::Error::Protocol(e.to_string()))?;

        if !is_history {
            continue; // future weeks stay Proposed drafts, unsaved
        }

        queries::set_rota_assignments_status(pool, rota_id, AssignmentStatus::Confirmed).await?;

        // Save dated the weekend before (the "built next week's rota" moment).
        let first_saved_at = rfc3339_at(week - Duration::days(2), 18);
        queries::create_save_at(pool, rota_id, &first_saved_at).await?;

        // On a handful of weeks, simulate a mid-week edit (a staff drop) and
        // save again so the Edit Log shows a real diff.
        if EDIT_WEEK_OFFSETS.contains(&offset) {
            let assignments = queries::list_assignments_for_rota(pool, rota_id).await?;
            if let Some(first) = assignments.first() {
                queries::delete_assignment(pool, first.id).await?;
                let second_saved_at = rfc3339_at(week - Duration::days(1), 12);
                queries::create_save_at(pool, rota_id, &second_saved_at).await?;
            }
        }
    }

    Ok(())
}

/// Build an RFC3339 UTC timestamp for `date` at the given hour.
fn rfc3339_at(date: NaiveDate, hour: u32) -> String {
    date.and_hms_opt(hour, 0, 0).unwrap().and_utc().to_rfc3339()
}

/// An all-day "unavailable" exception for one employee on one date.
fn off_day(id: i64, employee_id: i64, date: NaiveDate, note: &str) -> EmployeeAvailabilityOverride {
    let mut day = DayAvailability::default();
    for h in 0..24u8 {
        day.set(h, AvailabilityState::No);
    }
    EmployeeAvailabilityOverride {
        id,
        employee_id,
        date,
        availability: day,
        notes: Some(note.to_string()),
        source: OverrideSource::Exception,
    }
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

/// Build an `Availability` bounded to a personal working `window`
/// (start-hour..end-hour): hours outside it are explicitly `No` on every day —
/// real employees have a daily band they'll work within — then the
/// `(days, start-hour, end-hour, state)` spans apply in order inside it.
/// Unspanned hours inside the window stay `Maybe`.
fn avail(window: (u8, u8), spans: &[(&[Weekday], u8, u8, AvailabilityState)]) -> Availability {
    let mut a = Availability::default();
    for &wd in &ALL_WEEK {
        for h in 0..24u8 {
            if h < window.0 || h >= window.1 {
                a.set(wd, h, AvailabilityState::No);
            }
        }
    }
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
    use chrono::Datelike;

    async fn seeded_pool() -> (SqlitePool, NaiveDate) {
        let pool = crate::db::connect("sqlite::memory:").await.unwrap();
        let anchor = anchor_week();
        seed_sample_debug_data(&pool, anchor).await.unwrap();
        (pool, anchor)
    }

    fn anchor_week() -> NaiveDate {
        NaiveDate::from_ymd_opt(2099, 4, 20).unwrap() // a Monday
    }

    #[tokio::test]
    async fn seeds_roster_and_templates() {
        let (pool, _) = seeded_pool().await;

        let employees = queries::list_employees(&pool).await.unwrap();
        assert_eq!(employees.len(), 18);
        assert!(employees.iter().all(|e| e.nickname.is_none()));

        let roles = queries::list_roles(&pool).await.unwrap();
        for r in ROLES {
            assert!(roles.iter().any(|role| role.name == r), "{r} missing");
        }

        let templates = queries::list_shift_templates(&pool).await.unwrap();
        assert_eq!(templates.len(), 7);
        assert!(templates.iter().any(|t| t.role_requirements.len() >= 2));
    }

    #[tokio::test]
    async fn generates_sixteen_weeks_of_rotas_with_assignments() {
        let (pool, anchor) = seeded_pool().await;

        let mut populated = 0;
        for offset in -PAST_WEEKS..=FUTURE_WEEKS {
            let week = anchor + Duration::days(offset * 7);
            let rota = queries::get_rota_by_week(&pool, week)
                .await
                .unwrap()
                .expect("rota should exist for every week");
            let assignments = queries::list_assignments_for_rota(&pool, rota.id)
                .await
                .unwrap();
            if !assignments.is_empty() {
                populated += 1;
            }
        }
        assert_eq!(populated as i64, PAST_WEEKS + 1 + FUTURE_WEEKS);
    }

    #[tokio::test]
    async fn past_confirmed_future_proposed() {
        let (pool, anchor) = seeded_pool().await;

        // Current week (offset 0) → Confirmed.
        let current = week_statuses(&pool, anchor).await;
        assert!(!current.is_empty());
        assert!(current.iter().all(|s| *s == AssignmentStatus::Confirmed));

        // A future week → Proposed.
        let future = week_statuses(&pool, anchor + Duration::days(7)).await;
        assert!(!future.is_empty());
        assert!(future.iter().all(|s| *s == AssignmentStatus::Proposed));
    }

    async fn week_statuses(pool: &SqlitePool, week: NaiveDate) -> Vec<AssignmentStatus> {
        let rota = queries::get_rota_by_week(pool, week)
            .await
            .unwrap()
            .unwrap();
        queries::list_assignments_for_rota(pool, rota.id)
            .await
            .unwrap()
            .into_iter()
            .map(|a| a.status)
            .collect()
    }

    #[tokio::test]
    async fn exceptions_span_past_and_future() {
        let (pool, anchor) = seeded_pool().await;

        let past = queries::list_employee_availability_overrides_in_range(
            &pool,
            anchor - Duration::days(PAST_WEEKS * 7),
            anchor,
        )
        .await
        .unwrap();
        assert!(
            past.len() >= 10,
            "want many historical exceptions, got {}",
            past.len()
        );
        assert!(past.iter().all(|o| o.source == OverrideSource::Exception));

        let future = queries::list_employee_availability_overrides_in_range(
            &pool,
            anchor,
            anchor + Duration::days((FUTURE_WEEKS + 1) * 7),
        )
        .await
        .unwrap();
        assert!(!future.is_empty(), "want upcoming exceptions too");
    }

    #[tokio::test]
    async fn backdated_saves_with_a_real_diff() {
        let (pool, anchor) = seeded_pool().await;

        let saves = queries::list_saves(&pool, None).await.unwrap();
        // At least one save per past/current week.
        assert!(saves.len() as i64 >= PAST_WEEKS + 1);

        // Saves span roughly three months of backdated timestamps.
        let oldest = saves.iter().map(|s| s.saved_at.as_str()).min().unwrap();
        let anchor_ts = rfc3339_at(anchor, 0);
        assert!(
            oldest < anchor_ts.as_str(),
            "oldest save should predate the anchor"
        );

        // An edit week has ≥2 saves for its rota and a non-empty diff.
        let edit_week = anchor + Duration::days(EDIT_WEEK_OFFSETS[0] * 7);
        let rota = queries::get_rota_by_week(&pool, edit_week)
            .await
            .unwrap()
            .unwrap();
        let week_saves = queries::list_saves(&pool, Some(rota.id)).await.unwrap();
        assert!(week_saves.len() >= 2, "edit week should have two saves");
        let newest = week_saves.first().unwrap(); // list_saves is DESC
        let diff = queries::diff_save_vs_previous(&pool, newest.id)
            .await
            .unwrap();
        assert!(!diff.is_empty(), "the edit save should produce a diff");
    }

    #[tokio::test]
    async fn analytics_range_is_populated() {
        let (pool, anchor) = seeded_pool().await;
        let start = anchor - Duration::days(PAST_WEEKS * 7);
        let end = anchor + Duration::days(7);
        let history = queries::list_all_shift_history(&pool, Some(start), Some(end))
            .await
            .unwrap();
        assert!(!history.is_empty(), "analytics source should be non-empty");
        assert!(history.iter().any(|r| r.hourly_wage.is_some()));
    }

    #[tokio::test]
    async fn anchor_is_a_monday() {
        assert_eq!(anchor_week().weekday(), Weekday::Mon);
    }
}
