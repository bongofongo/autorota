//! Boundary validation for user-supplied model data.
//!
//! These checks run at FFI insert/update entry points and at roster import,
//! catching malformed input before it reaches the database. Internal callers
//! (scheduler, query layer, builder helpers in tests) bypass validation —
//! they trust their own data.

use crate::models::availability::Availability;
use crate::models::employee::Employee;
use crate::models::shift::{Shift, ShiftTemplate};

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum ValidationError {
    #[error("first_name must not be empty")]
    EmptyFirstName,
    #[error("hourly_wage must be non-negative and finite ({0})")]
    InvalidWage(String),
    #[error("min_employees ({min}) must not exceed max_employees ({max})")]
    MinExceedsMax { min: u32, max: u32 },
    #[error("shift start_time must differ from end_time (zero-duration window)")]
    ZeroDurationShift,
    #[error("availability hour {0} out of range 0..=23")]
    HourOutOfRange(u32),
    #[error("max_daily_hours must be in range 0..=24, got {0}")]
    InvalidMaxDailyHours(f32),
    #[error("target_weekly_hours must be in range 0..=168, got {0}")]
    InvalidTargetWeeklyHours(f32),
}

pub fn validate_employee(emp: &Employee) -> Result<(), ValidationError> {
    if emp.first_name.trim().is_empty() {
        return Err(ValidationError::EmptyFirstName);
    }
    if let Some(w) = emp.hourly_wage
        && (!w.is_finite() || w < 0.0)
    {
        return Err(ValidationError::InvalidWage(format!("{w}")));
    }
    if !(0.0..=24.0).contains(&emp.max_daily_hours) {
        return Err(ValidationError::InvalidMaxDailyHours(emp.max_daily_hours));
    }
    if !(0.0..=168.0).contains(&emp.target_weekly_hours) {
        return Err(ValidationError::InvalidTargetWeeklyHours(
            emp.target_weekly_hours,
        ));
    }
    validate_availability(&emp.default_availability)?;
    validate_availability(&emp.availability)?;
    Ok(())
}

pub fn validate_shift_template(t: &ShiftTemplate) -> Result<(), ValidationError> {
    if t.min_employees > t.max_employees {
        return Err(ValidationError::MinExceedsMax {
            min: t.min_employees,
            max: t.max_employees,
        });
    }
    if t.start_time == t.end_time {
        return Err(ValidationError::ZeroDurationShift);
    }
    Ok(())
}

pub fn validate_shift(s: &Shift) -> Result<(), ValidationError> {
    if s.min_employees > s.max_employees {
        return Err(ValidationError::MinExceedsMax {
            min: s.min_employees,
            max: s.max_employees,
        });
    }
    if s.start_time == s.end_time {
        return Err(ValidationError::ZeroDurationShift);
    }
    Ok(())
}

pub fn validate_availability(_a: &Availability) -> Result<(), ValidationError> {
    // The dense `[[state; 24]; 7]` grid makes an out-of-range hour
    // unrepresentable — `set`/deserialize drop anything ≥ 24 — so there is
    // nothing left to reject here. Kept as a call site for symmetry with the
    // other validators and in case future fields need per-cell checks.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::availability::AvailabilityState;
    use crate::testutil::{EmployeeBuilder, ShiftBuilder, ShiftTemplateBuilder};
    use chrono::{NaiveDate, NaiveTime, Weekday};

    fn ok_employee() -> Employee {
        EmployeeBuilder::new("Alice")
            .role("barista")
            .available(AvailabilityState::Yes)
            .build()
    }

    #[test]
    fn employee_ok() {
        assert!(validate_employee(&ok_employee()).is_ok());
    }

    #[test]
    fn employee_rejects_empty_first_name() {
        let mut e = ok_employee();
        e.first_name = "   ".into();
        assert_eq!(
            validate_employee(&e).unwrap_err(),
            ValidationError::EmptyFirstName
        );
    }

    #[test]
    fn employee_rejects_negative_wage() {
        let mut e = ok_employee();
        e.hourly_wage = Some(-1.0);
        match validate_employee(&e).unwrap_err() {
            ValidationError::InvalidWage(_) => {}
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn employee_rejects_nan_wage() {
        let mut e = ok_employee();
        e.hourly_wage = Some(f32::NAN);
        assert!(matches!(
            validate_employee(&e).unwrap_err(),
            ValidationError::InvalidWage(_)
        ));
    }

    #[test]
    fn employee_rejects_infinite_wage() {
        let mut e = ok_employee();
        e.hourly_wage = Some(f32::INFINITY);
        assert!(matches!(
            validate_employee(&e).unwrap_err(),
            ValidationError::InvalidWage(_)
        ));
    }

    #[test]
    fn employee_rejects_out_of_range_max_daily_hours() {
        let mut e = ok_employee();
        e.max_daily_hours = 25.0;
        assert!(matches!(
            validate_employee(&e).unwrap_err(),
            ValidationError::InvalidMaxDailyHours(_)
        ));
    }

    #[test]
    fn shift_template_rejects_min_exceeds_max() {
        let t = ShiftTemplateBuilder::new("Morning")
            .weekdays(&[Weekday::Mon])
            .times(7, 12)
            .role("barista")
            .capacity(5, 2)
            .build();
        assert_eq!(
            validate_shift_template(&t).unwrap_err(),
            ValidationError::MinExceedsMax { min: 5, max: 2 }
        );
    }

    #[test]
    fn shift_template_rejects_zero_duration() {
        let mut t = ShiftTemplateBuilder::new("X")
            .weekdays(&[Weekday::Mon])
            .times(7, 12)
            .role("barista")
            .capacity(1, 1)
            .build();
        t.end_time = t.start_time;
        assert_eq!(
            validate_shift_template(&t).unwrap_err(),
            ValidationError::ZeroDurationShift
        );
    }

    #[test]
    fn shift_overnight_wrap_is_allowed() {
        // Overnight: end (06:00) < start (22:00) is valid; only equality is rejected.
        let s = ShiftBuilder::new()
            .id(1)
            .date(NaiveDate::from_ymd_opt(2026, 4, 27).unwrap())
            .times_hm((22, 0), (6, 0))
            .role("barista")
            .build();
        assert!(validate_shift(&s).is_ok());
    }

    #[test]
    fn availability_out_of_range_hour_is_unrepresentable() {
        // The dense grid cannot store hour ≥ 24: `set` drops it, so the grid
        // stays blank and validation trivially passes. Out-of-range availability
        // is now structurally impossible rather than caught after the fact.
        let mut a = Availability::default();
        a.set(Weekday::Mon, 25, AvailabilityState::Yes);
        assert!(a.is_blank());
        assert!(validate_availability(&a).is_ok());
    }

    #[test]
    fn availability_accepts_hour_23() {
        let mut a = Availability::default();
        a.set(Weekday::Mon, 23, AvailabilityState::Yes);
        assert!(validate_availability(&a).is_ok());
    }

    // Defensively exercise NaiveTime equality for the zero-duration check.
    #[test]
    fn naive_time_equality_used_by_zero_duration_check() {
        let t = NaiveTime::from_hms_opt(8, 0, 0).unwrap();
        assert_eq!(t, NaiveTime::from_hms_opt(8, 0, 0).unwrap());
    }
}
