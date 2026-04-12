#![allow(dead_code)]
//! Re-exports from `autorota_core::testutil` plus backward-compatible wrappers
//! for existing integration tests.

pub use autorota_core::testutil::*;

use autorota_core::models::availability::AvailabilityState;
use autorota_core::models::employee::Employee;
use autorota_core::models::shift::Shift;
use chrono::NaiveDate;

/// Backward-compatible wrapper: builds a test employee with uniform weekday availability.
pub fn make_employee(id: i64, name: &str, role: &str, avail_state: AvailabilityState) -> Employee {
    EmployeeBuilder::new(name)
        .id(id)
        .role(role)
        .available(avail_state)
        .build()
}

/// Backward-compatible wrapper: builds a test shift from whole-hour times.
pub fn make_shift(id: i64, date: NaiveDate, start: u32, end: u32, role: &str) -> Shift {
    ShiftBuilder::new()
        .id(id)
        .date(date)
        .times(start, end)
        .role(role)
        .build()
}
