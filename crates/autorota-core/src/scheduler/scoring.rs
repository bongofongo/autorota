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
    // Clamp before casting: an `f32 → i32 as` cast on NaN or a value outside
    // `i32::MIN..=i32::MAX` yields an undefined-looking saturated result and
    // can break tiebreak ordering. We force `0` for non-finite inputs (i.e.
    // corrupted target_weekly_hours / daily caps) so scoring stays
    // deterministic.
    let remaining_to_target = employee.target_weekly_hours - weekly_hours;
    let fairness_rank = clamped_centi_score(remaining_to_target);

    let daily_remaining = employee.max_daily_hours - daily_hours - shift.duration_hours();
    let daily_budget_rank = clamped_centi_score(daily_remaining);

    (availability_rank, fairness_rank, daily_budget_rank)
}

/// Multiply by 100 (so we keep two decimal places of precision in an integer
/// rank) and saturate to the `i32` range. NaN collapses to 0; ±Inf saturate
/// to the corresponding `i32` extreme so a corrupted budget that "wants
/// infinite hours" still produces a stable, deterministic ordering.
fn clamped_centi_score(hours: f32) -> i32 {
    if hours.is_nan() {
        return 0;
    }
    if hours == f32::INFINITY {
        return i32::MAX;
    }
    if hours == f32::NEG_INFINITY {
        return i32::MIN;
    }
    let scaled = hours * 100.0;
    if scaled >= i32::MAX as f32 {
        i32::MAX
    } else if scaled <= i32::MIN as f32 {
        i32::MIN
    } else {
        scaled as i32
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::availability::{Availability, AvailabilityState};
    use crate::testutil::{EmployeeBuilder, ShiftBuilder};
    use chrono::Weekday;

    fn make_employee(max_daily: f32, target_weekly: f32) -> Employee {
        let mut avail = Availability::default();
        for h in 6..18 {
            avail.set(Weekday::Mon, h, AvailabilityState::Yes);
        }
        EmployeeBuilder::new("Test")
            .id(1)
            .max_daily(max_daily)
            .hours(target_weekly)
            .availability(avail)
            .build()
    }

    fn make_shift() -> Shift {
        ShiftBuilder::new().id(1).build()
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
    fn nan_inputs_do_not_panic_and_score_zero() {
        // Regression net for the `(f32 * 100) as i32` pipeline: NaN /
        // Infinity must not break tiebreak ordering or produce undefined
        // ranks.
        assert_eq!(clamped_centi_score(f32::NAN), 0);
        assert_eq!(clamped_centi_score(f32::INFINITY), i32::MAX);
        assert_eq!(clamped_centi_score(f32::NEG_INFINITY), i32::MIN);
        assert_eq!(clamped_centi_score(f32::MAX), i32::MAX);
        assert_eq!(clamped_centi_score(f32::MIN), i32::MIN);
        assert_eq!(clamped_centi_score(0.0), 0);
        assert_eq!(clamped_centi_score(2.5), 250);
        assert_eq!(clamped_centi_score(-2.5), -250);
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
