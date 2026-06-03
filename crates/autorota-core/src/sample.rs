//! Canonical sample dataset.
//!
//! Single source of truth for the cafe-themed example data shown in the app.
//! Used **only** by the PDF / CSV export preview path. Lives entirely in memory
//! and never touches the database.
//!
//! The fixed week is `2099-04-20` so generated rows can never be confused with
//! a real week the user has scheduled.

use chrono::{Duration, NaiveDate, NaiveTime, Weekday};

use crate::models::{
    assignment::{Assignment, AssignmentStatus},
    availability::Availability,
    employee::Employee,
    shift::{Shift, ShiftTemplate},
};

/// Monday of the canonical sample week.
pub const SAMPLE_WEEK_STR: &str = "2099-04-20";

/// Bundle returned by [`build_sample_week`].
pub struct SampleWeek {
    pub week_start: NaiveDate,
    pub employees: Vec<Employee>,
    pub templates: Vec<ShiftTemplate>,
    pub shifts: Vec<Shift>,
    pub assignments: Vec<Assignment>,
}

/// Parse the hard-coded sample week.
pub fn sample_week_start() -> NaiveDate {
    SAMPLE_WEEK_STR
        .parse()
        .expect("hard-coded sample date parses")
}

/// Five cafe employees with realistic role + wage spread.
pub fn sample_employees() -> Vec<Employee> {
    vec![
        emp(1, "Alice", "Chen", None, &["Barista"], 12.0, "gbp"),
        emp(2, "Bob", "Sato", None, &["Barista"], 11.0, "gbp"),
        emp(
            3,
            "Cara",
            "Liu",
            Some("C"),
            &["Lead Barista", "Barista"],
            15.0,
            "gbp",
        ),
        emp(4, "Dan", "Park", None, &["Kitchen"], 13.0, "gbp"),
        emp(5, "Eve", "Mori", None, &["Kitchen", "Barista"], 14.0, "gbp"),
    ]
}

/// Five shift templates covering opening / midday / close / kitchen / lead.
pub fn sample_templates() -> Vec<ShiftTemplate> {
    vec![
        tmpl(1, "Opening", "Barista", 8, 12),
        tmpl(2, "Midday", "Barista", 12, 16),
        tmpl(3, "Close", "Barista", 16, 20),
        tmpl(4, "Kitchen", "Kitchen", 9, 15),
        tmpl(5, "Lead", "Lead Barista", 10, 18),
    ]
}

/// Build the full sample week (employees, templates, ~20 shifts, ~19
/// assignments — one shift intentionally unfilled).
pub fn build_sample_week() -> SampleWeek {
    let week_start = sample_week_start();
    let employees = sample_employees();
    let templates = sample_templates();

    // (date_offset, template_id, optional (employee_id, status)).
    let spec: &[(i64, i64, Option<(i64, AssignmentStatus)>)] = &[
        // Mon
        (0, 1, Some((1, AssignmentStatus::Confirmed))),
        (0, 2, Some((2, AssignmentStatus::Confirmed))),
        (0, 4, Some((4, AssignmentStatus::Confirmed))),
        (0, 5, Some((3, AssignmentStatus::Confirmed))),
        // Tue
        (1, 1, Some((2, AssignmentStatus::Confirmed))),
        (1, 2, Some((5, AssignmentStatus::Proposed))),
        (1, 4, Some((4, AssignmentStatus::Confirmed))),
        // Wed
        (2, 1, Some((1, AssignmentStatus::Confirmed))),
        (2, 3, Some((3, AssignmentStatus::Confirmed))),
        (2, 4, Some((4, AssignmentStatus::Proposed))),
        // Thu
        (3, 2, Some((1, AssignmentStatus::Confirmed))),
        (3, 3, Some((2, AssignmentStatus::Confirmed))),
        (3, 5, Some((3, AssignmentStatus::Confirmed))),
        // Fri
        (4, 1, Some((5, AssignmentStatus::Confirmed))),
        (4, 2, Some((1, AssignmentStatus::Confirmed))),
        (4, 3, None),
        (4, 4, Some((4, AssignmentStatus::Confirmed))),
        // Sat
        (5, 1, Some((2, AssignmentStatus::Confirmed))),
        (5, 5, Some((3, AssignmentStatus::Confirmed))),
        // Sun
        (6, 2, Some((5, AssignmentStatus::Confirmed))),
    ];

    let tmpl_by_id: std::collections::HashMap<i64, &ShiftTemplate> =
        templates.iter().map(|t| (t.id, t)).collect();

    let mut shifts = Vec::with_capacity(spec.len());
    let mut assignments = Vec::new();
    let mut next_shift_id: i64 = 1;
    let mut next_assignment_id: i64 = 1;

    for (offset, template_id, who) in spec {
        let tmpl = tmpl_by_id
            .get(template_id)
            .expect("BUG: sample.rs spec references template_id not in sample_templates()");
        let shift = Shift {
            id: next_shift_id,
            template_id: Some(tmpl.id),
            rota_id: 1,
            date: week_start + Duration::days(*offset),
            start_time: tmpl.start_time,
            end_time: tmpl.end_time,
            required_role: tmpl.required_role.clone(),
            min_employees: tmpl.min_employees,
            max_employees: tmpl.max_employees,
            role_requirements: tmpl.role_requirements.clone(),
        };

        if let Some((emp_id, status)) = who {
            let employee = employees
                .iter()
                .find(|e| e.id == *emp_id)
                .expect("BUG: sample.rs spec references emp_id not in sample_employees()");
            assignments.push(Assignment {
                id: next_assignment_id,
                rota_id: 1,
                shift_id: next_shift_id,
                employee_id: *emp_id,
                status: *status,
                employee_name: Some(employee.display_name()),
                hourly_wage: employee.hourly_wage,
            });
            next_assignment_id += 1;
        }

        shifts.push(shift);
        next_shift_id += 1;
    }

    SampleWeek {
        week_start,
        employees,
        templates,
        shifts,
        assignments,
    }
}

fn emp(
    id: i64,
    first: &str,
    last: &str,
    nickname: Option<&str>,
    roles: &[&str],
    wage: f32,
    currency: &str,
) -> Employee {
    Employee {
        id,
        first_name: first.to_string(),
        last_name: last.to_string(),
        nickname: nickname.map(str::to_string),
        roles: roles.iter().map(|r| r.to_string()).collect(),
        start_date: NaiveDate::from_ymd_opt(2099, 1, 1).unwrap(),
        target_weekly_hours: 30.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 9.0,
        notes: None,
        bank_details: None,
        phone: None,
        email: None,
        preferred_contact: None,
        hourly_wage: Some(wage),
        wage_currency: Some(currency.to_string()),
        default_availability: Availability::default(),
        availability: Availability::default(),
        deleted: false,
    }
}

fn tmpl(id: i64, name: &str, role: &str, start_h: u32, end_h: u32) -> ShiftTemplate {
    ShiftTemplate {
        id,
        name: name.to_string(),
        weekdays: vec![
            Weekday::Mon,
            Weekday::Tue,
            Weekday::Wed,
            Weekday::Thu,
            Weekday::Fri,
            Weekday::Sat,
            Weekday::Sun,
        ],
        start_time: NaiveTime::from_hms_opt(start_h, 0, 0).unwrap(),
        end_time: NaiveTime::from_hms_opt(end_h, 0, 0).unwrap(),
        required_role: role.to_string(),
        min_employees: 1,
        max_employees: 2,
        role_requirements: if role.is_empty() {
            vec![]
        } else {
            vec![crate::models::shift::RoleRequirement {
                role: role.to_string(),
                min_count: 1,
            }]
        },
        deleted: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Datelike;

    #[test]
    fn week_start_is_2099_04_20_monday() {
        let d = sample_week_start();
        assert_eq!(d.format("%Y-%m-%d").to_string(), "2099-04-20");
        assert_eq!(d.weekday(), Weekday::Mon);
    }

    #[test]
    fn employees_have_wages() {
        for e in sample_employees() {
            assert!(e.hourly_wage.is_some(), "{} missing wage", e.first_name);
            assert_eq!(e.wage_currency.as_deref(), Some("gbp"));
        }
    }

    #[test]
    fn assignments_reference_real_employees_and_shifts() {
        let week = build_sample_week();
        let emp_ids: std::collections::HashSet<i64> = week.employees.iter().map(|e| e.id).collect();
        let shift_ids: std::collections::HashSet<i64> = week.shifts.iter().map(|s| s.id).collect();
        for a in &week.assignments {
            assert!(emp_ids.contains(&a.employee_id));
            assert!(shift_ids.contains(&a.shift_id));
        }
    }

    #[test]
    fn one_shift_is_intentionally_unfilled() {
        let week = build_sample_week();
        let assigned: std::collections::HashSet<i64> =
            week.assignments.iter().map(|a| a.shift_id).collect();
        let unfilled: Vec<&Shift> = week
            .shifts
            .iter()
            .filter(|s| !assigned.contains(&s.id))
            .collect();
        assert_eq!(unfilled.len(), 1, "expected exactly one unfilled shift");
    }
}
