use crate::models::availability::AvailabilityState;
use crate::models::employee::Employee;
use crate::models::overrides::DayAvailability;
use crate::models::shift::Shift;

/// Composite score for ranking an employee against a shift.
/// Returned as a tuple so lexicographic Ord gives the correct priority:
///   1. Availability quality (Yes=2 > Maybe=1; No is filtered by eligibility)
///   2. Fairness — distance below target weekly hours (more remaining = higher rank)
///   3. Daily budget remaining — more slack ranks higher
///
/// Higher tuple value = better candidate.
///
/// `day_avail_override` — when `Some`, uses the date-specific `DayAvailability` instead of
/// the employee's weekly availability map for the availability rank.
pub fn score_employee(
    employee: &Employee,
    shift: &Shift,
    weekly_hours: f32,
    daily_hours: f32,
    day_avail_override: Option<&DayAvailability>,
) -> (u8, i32, i32) {
    let avail = if let Some(day_avail) = day_avail_override {
        day_avail.for_window(shift.start_hour(), shift.end_hour())
    } else {
        employee
            .availability
            .for_window(shift.weekday(), shift.start_hour(), shift.end_hour())
    };

    let availability_rank = match avail {
        AvailabilityState::Yes => 2,
        AvailabilityState::Maybe => 1,
        AvailabilityState::No => 0,
    };

    // Prefer employees who are furthest below their target weekly hours.
    let remaining_to_target = employee.target_weekly_hours - weekly_hours;
    let fairness_rank = (remaining_to_target * 100.0) as i32;

    let daily_remaining = employee.max_daily_hours - daily_hours - shift.duration_hours();
    let daily_budget_rank = (daily_remaining * 100.0) as i32;

    (availability_rank, fairness_rank, daily_budget_rank)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::availability::Availability;
    use chrono::{NaiveDate, NaiveTime, Weekday};

    fn make_employee(max_daily: f32, target_weekly: f32) -> Employee {
        let mut avail = Availability::default();
        for h in 6..18 {
            avail.set(Weekday::Mon, h, AvailabilityState::Yes);
        }
        Employee {
            id: 1,
            first_name: "Test".to_string(),
            last_name: String::new(),
            nickname: None,
            roles: vec!["barista".to_string()],
            start_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
            target_weekly_hours: target_weekly,
            weekly_hours_deviation: 6.0,
            max_daily_hours: max_daily,
            notes: None,
            bank_details: None,
            hourly_wage: None,
            wage_currency: None,
            default_availability: Availability::default(),
            availability: avail,
            deleted: false,
        }
    }

    fn make_shift() -> Shift {
        Shift {
            id: 1,
            template_id: Some(1),
            rota_id: 1,
            date: NaiveDate::from_ymd_opt(2026, 3, 23).unwrap(),
            start_time: NaiveTime::from_hms_opt(7, 0, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
            required_role: "barista".to_string(),
            min_employees: 1,
            max_employees: 1,
        }
    }

    #[test]
    fn yes_ranks_higher_than_maybe() {
        let mut emp = make_employee(8.0, 40.0);
        let shift = make_shift();

        let score_yes = score_employee(&emp, &shift, 0.0, 0.0, None);

        // Change availability to Maybe
        for h in 6..18 {
            emp.availability
                .set(Weekday::Mon, h, AvailabilityState::Maybe);
        }
        let score_maybe = score_employee(&emp, &shift, 0.0, 0.0, None);

        assert!(score_yes > score_maybe);
    }

    #[test]
    fn fewer_weekly_hours_ranks_higher() {
        let emp = make_employee(8.0, 40.0);
        let shift = make_shift();

        let score_fresh = score_employee(&emp, &shift, 0.0, 0.0, None);
        let score_busy = score_employee(&emp, &shift, 20.0, 0.0, None);

        assert!(score_fresh > score_busy);
    }
}
