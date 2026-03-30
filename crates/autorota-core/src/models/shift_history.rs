use chrono::{NaiveDate, NaiveTime, Timelike};

use crate::models::assignment::AssignmentStatus;

/// A denormalised record joining an assignment with its shift and rota,
/// used to display an employee's shift history.
#[derive(Debug, Clone)]
pub struct EmployeeShiftRecord {
    pub assignment_id: i64,
    pub rota_id: i64,
    pub shift_id: i64,
    pub employee_id: i64,
    pub status: AssignmentStatus,
    pub employee_name: Option<String>,
    /// Snapshot of the employee's hourly wage at assignment time.
    pub hourly_wage: Option<f32>,
    pub date: NaiveDate,
    pub start_time: NaiveTime,
    pub end_time: NaiveTime,
    pub required_role: String,
    pub week_start: NaiveDate,
    pub finalized: bool,
}

impl EmployeeShiftRecord {
    pub fn duration_hours(&self) -> f32 {
        let start = self.start_time.num_seconds_from_midnight();
        let end = self.end_time.num_seconds_from_midnight();
        let secs = if end >= start {
            end - start
        } else {
            86400 - start + end
        };
        secs as f32 / 3600.0
    }
}
