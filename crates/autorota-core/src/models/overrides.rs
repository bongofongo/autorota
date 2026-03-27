use chrono::{NaiveDate, NaiveTime};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::models::availability::AvailabilityState;

/// Per-hour availability for a single specific calendar date.
///
/// Keyed by hour (0–23). Absent hours default to `Maybe`, exactly as in `Availability`.
/// Serialized as JSON: `{"8":"Yes","14":"No",...}` (string keys, no weekday prefix).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(try_from = "HashMap<String, String>", into = "HashMap<String, String>")]
pub struct DayAvailability(pub HashMap<u8, AvailabilityState>);

impl TryFrom<HashMap<String, String>> for DayAvailability {
    type Error = String;

    fn try_from(map: HashMap<String, String>) -> Result<Self, Self::Error> {
        let mut inner = HashMap::new();
        for (k, v) in map {
            let hour: u8 = k
                .parse()
                .map_err(|_| format!("invalid hour key: {k}"))?;
            let state: AvailabilityState = v
                .parse()
                .map_err(|e| format!("invalid state for hour {hour}: {e}"))?;
            inner.insert(hour, state);
        }
        Ok(DayAvailability(inner))
    }
}

impl From<DayAvailability> for HashMap<String, String> {
    fn from(d: DayAvailability) -> Self {
        d.0.into_iter()
            .map(|(h, s)| (h.to_string(), s.to_string()))
            .collect()
    }
}

impl DayAvailability {
    pub fn get(&self, hour: u8) -> AvailabilityState {
        self.0.get(&hour).copied().unwrap_or(AvailabilityState::Maybe)
    }

    pub fn set(&mut self, hour: u8, state: AvailabilityState) {
        self.0.insert(hour, state);
    }

    /// Returns the worst (minimum) availability state across all hours of a shift window.
    /// Handles overnight shifts where `end_hour < start_hour`.
    pub fn for_window(&self, start_hour: u8, end_hour: u8) -> AvailabilityState {
        let hours: Box<dyn Iterator<Item = u8>> = if end_hour > start_hour {
            Box::new(start_hour..end_hour)
        } else {
            Box::new((start_hour..24).chain(0..end_hour))
        };
        hours
            .map(|h| self.get(h))
            .min()
            .unwrap_or(AvailabilityState::No)
    }

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    pub fn from_json(s: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(s)
    }
}

/// Date-specific availability override for a single employee on a specific calendar date.
///
/// When the scheduler processes a shift on this date, it uses `availability` instead of
/// the employee's weekly `Availability` map.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmployeeAvailabilityOverride {
    pub id: i64,
    pub employee_id: i64,
    pub date: NaiveDate,
    pub availability: DayAvailability,
    pub notes: Option<String>,
}

/// Date-specific modification to a recurring shift template on a specific calendar date.
///
/// Applied during `materialise_shifts`: if `cancelled` is true the shift is skipped;
/// otherwise any non-`None` fields override the corresponding template fields.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShiftTemplateOverride {
    pub id: i64,
    pub template_id: i64,
    pub date: NaiveDate,
    pub cancelled: bool,
    pub start_time: Option<NaiveTime>,
    pub end_time: Option<NaiveTime>,
    pub min_employees: Option<u32>,
    pub max_employees: Option<u32>,
    pub notes: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn day_availability_get_missing_returns_maybe() {
        let d = DayAvailability::default();
        assert_eq!(d.get(8), AvailabilityState::Maybe);
    }

    #[test]
    fn day_availability_for_window_all_yes() {
        let mut d = DayAvailability::default();
        for h in 7..12 {
            d.set(h, AvailabilityState::Yes);
        }
        assert_eq!(d.for_window(7, 12), AvailabilityState::Yes);
    }

    #[test]
    fn day_availability_for_window_one_no_downgrades() {
        let mut d = DayAvailability::default();
        for h in 7..12 {
            d.set(h, AvailabilityState::Yes);
        }
        d.set(9, AvailabilityState::No);
        assert_eq!(d.for_window(7, 12), AvailabilityState::No);
    }

    #[test]
    fn day_availability_json_roundtrip() {
        let mut d = DayAvailability::default();
        d.set(8, AvailabilityState::Yes);
        d.set(14, AvailabilityState::No);
        let json = d.to_json().unwrap();
        let restored = DayAvailability::from_json(&json).unwrap();
        assert_eq!(restored.get(8), AvailabilityState::Yes);
        assert_eq!(restored.get(14), AvailabilityState::No);
        assert_eq!(restored.get(10), AvailabilityState::Maybe);
    }

    #[test]
    fn day_availability_for_window_overnight() {
        let mut d = DayAvailability::default();
        for h in [22u8, 23, 0, 1] {
            d.set(h, AvailabilityState::Yes);
        }
        assert_eq!(d.for_window(22, 2), AvailabilityState::Yes);
    }
}
