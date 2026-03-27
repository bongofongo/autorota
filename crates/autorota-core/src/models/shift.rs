use chrono::{Datelike, NaiveDate, NaiveTime, Timelike, Weekday};
use serde::{Deserialize, Serialize};

/// A reusable weekly pattern that generates concrete Shifts.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShiftTemplate {
    pub id: i64,
    pub name: String,
    pub weekdays: Vec<Weekday>,
    pub start_time: NaiveTime,
    pub end_time: NaiveTime,
    pub required_role: String,
    pub min_employees: u32,
    pub max_employees: u32,
    /// Soft-delete flag: true if the template has been removed.
    #[serde(default)]
    pub deleted: bool,
}

/// A concrete shift instance for a specific date, materialised from a ShiftTemplate.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Shift {
    pub id: i64,
    pub template_id: Option<i64>,
    pub rota_id: i64,
    pub date: NaiveDate,
    pub start_time: NaiveTime,
    pub end_time: NaiveTime,
    pub required_role: String,
    pub min_employees: u32,
    pub max_employees: u32,
}

impl Shift {
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

    pub fn weekday(&self) -> Weekday {
        self.date.weekday()
    }

    pub fn start_hour(&self) -> u8 {
        self.start_time.hour() as u8
    }

    pub fn end_hour(&self) -> u8 {
        self.end_time.hour() as u8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_shift(start: (u32, u32), end: (u32, u32), date: (i32, u32, u32)) -> Shift {
        Shift {
            id: 1,
            template_id: Some(1),
            rota_id: 1,
            date: NaiveDate::from_ymd_opt(date.0, date.1, date.2).unwrap(),
            start_time: NaiveTime::from_hms_opt(start.0, start.1, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(end.0, end.1, 0).unwrap(),
            required_role: "Barista".into(),
            min_employees: 1,
            max_employees: 1,
        }
    }

    #[test]
    fn duration_hours_normal() {
        let s = make_shift((7, 0), (12, 0), (2026, 3, 23));
        assert_eq!(s.duration_hours(), 5.0);
    }

    #[test]
    fn duration_hours_overnight() {
        let s = make_shift((22, 0), (6, 0), (2026, 3, 23));
        assert_eq!(s.duration_hours(), 8.0);
    }

    #[test]
    fn duration_hours_half() {
        let s = make_shift((9, 0), (13, 30), (2026, 3, 23));
        assert_eq!(s.duration_hours(), 4.5);
    }

    #[test]
    fn weekday_returns_correct_day() {
        // 2026-03-23 is a Monday
        let s = make_shift((7, 0), (12, 0), (2026, 3, 23));
        assert_eq!(s.weekday(), Weekday::Mon);
    }

    #[test]
    fn start_and_end_hour() {
        let s = make_shift((7, 0), (15, 0), (2026, 3, 23));
        assert_eq!(s.start_hour(), 7);
        assert_eq!(s.end_hour(), 15);
    }
}
