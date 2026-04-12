//! Custom assertion helpers for scheduler results.

use crate::scheduler::ScheduleResult;

/// Assert that a shift was assigned to a specific employee.
pub fn assert_assigned(result: &ScheduleResult, shift_id: i64, employee_id: i64) {
    let found = result
        .assignments
        .iter()
        .any(|a| a.shift_id == shift_id && a.employee_id == employee_id);
    assert!(
        found,
        "Expected shift {shift_id} assigned to employee {employee_id}, \
         but assignments were: {:?}",
        result.assignments
    );
}

/// Assert that an employee was NOT assigned to any shift.
pub fn assert_not_assigned(result: &ScheduleResult, employee_id: i64) {
    let found = result
        .assignments
        .iter()
        .any(|a| a.employee_id == employee_id);
    assert!(
        !found,
        "Expected employee {employee_id} to have no assignments, \
         but found: {:?}",
        result
            .assignments
            .iter()
            .filter(|a| a.employee_id == employee_id)
            .collect::<Vec<_>>()
    );
}

/// Assert that a ScheduleResult has a shortfall warning for the given shift.
pub fn assert_warning_for(result: &ScheduleResult, shift_id: i64) {
    let found = result.warnings.iter().any(|w| w.shift_id == shift_id);
    assert!(
        found,
        "Expected warning for shift {shift_id}, but warnings were: {:?}",
        result.warnings
    );
}

/// Assert that a ScheduleResult has no warnings.
pub fn assert_no_warnings(result: &ScheduleResult) {
    assert!(
        result.warnings.is_empty(),
        "Expected no warnings, but got: {:?}",
        result.warnings
    );
}

/// Assert the total number of assignments.
pub fn assert_assignment_count(result: &ScheduleResult, expected: usize) {
    assert_eq!(
        result.assignments.len(),
        expected,
        "Expected {expected} assignments, got {}: {:?}",
        result.assignments.len(),
        result.assignments
    );
}
