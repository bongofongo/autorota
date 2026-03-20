use chrono::NaiveDate;
use std::hash::{DefaultHasher, Hash, Hasher};

/// Deterministic tiebreak using a hash of (employee_id, week_start).
/// Produces a pseudo-random but reproducible ordering that varies week to week,
/// so the same employee doesn't always win ties.
pub fn tiebreak_key(employee_id: i64, week_start: &NaiveDate) -> u64 {
    let mut hasher = DefaultHasher::new();
    employee_id.hash(&mut hasher);
    week_start.hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    #[test]
    fn same_inputs_produce_same_key() {
        let date = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
        assert_eq!(tiebreak_key(1, &date), tiebreak_key(1, &date));
    }

    #[test]
    fn different_employees_produce_different_keys() {
        let date = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
        assert_ne!(tiebreak_key(1, &date), tiebreak_key(2, &date));
    }

    #[test]
    fn different_weeks_produce_different_keys() {
        let w1 = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
        let w2 = NaiveDate::from_ymd_opt(2026, 3, 30).unwrap();
        assert_ne!(tiebreak_key(1, &w1), tiebreak_key(1, &w2));
    }
}
