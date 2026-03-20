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
    pub template_id: i64,
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
        (end.saturating_sub(start)) as f32 / 3600.0
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
