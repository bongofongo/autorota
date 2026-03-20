use chrono::Weekday;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum AvailabilityState {
    No,
    Maybe,
    Yes,
}

impl fmt::Display for AvailabilityState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::No => write!(f, "No"),
            Self::Maybe => write!(f, "Maybe"),
            Self::Yes => write!(f, "Yes"),
        }
    }
}

impl FromStr for AvailabilityState {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "No" => Ok(Self::No),
            "Maybe" => Ok(Self::Maybe),
            "Yes" => Ok(Self::Yes),
            other => Err(format!("invalid availability state: {other}")),
        }
    }
}

fn weekday_to_str(wd: Weekday) -> &'static str {
    match wd {
        Weekday::Mon => "Mon",
        Weekday::Tue => "Tue",
        Weekday::Wed => "Wed",
        Weekday::Thu => "Thu",
        Weekday::Fri => "Fri",
        Weekday::Sat => "Sat",
        Weekday::Sun => "Sun",
    }
}

fn str_to_weekday(s: &str) -> Result<Weekday, String> {
    match s {
        "Mon" => Ok(Weekday::Mon),
        "Tue" => Ok(Weekday::Tue),
        "Wed" => Ok(Weekday::Wed),
        "Thu" => Ok(Weekday::Thu),
        "Fri" => Ok(Weekday::Fri),
        "Sat" => Ok(Weekday::Sat),
        "Sun" => Ok(Weekday::Sun),
        other => Err(format!("invalid weekday: {other}")),
    }
}

/// Hour-by-hour availability for a single employee.
/// Keyed by (weekday, hour_of_day) where hour_of_day is 0–23.
///
/// Custom serde serializes as `{"Mon:8": "Yes", "Tue:14": "Maybe", ...}`
/// so the map is valid JSON (JSON object keys must be strings).
#[derive(Debug, Clone, Default)]
pub struct Availability(pub HashMap<(Weekday, u8), AvailabilityState>);

impl Serialize for Availability {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut map = serializer.serialize_map(Some(self.0.len()))?;
        for (&(wd, hour), &state) in &self.0 {
            let key = format!("{}:{}", weekday_to_str(wd), hour);
            map.serialize_entry(&key, &state)?;
        }
        map.end()
    }
}

impl<'de> Deserialize<'de> for Availability {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw: HashMap<String, AvailabilityState> = HashMap::deserialize(deserializer)?;
        let mut inner = HashMap::new();
        for (key, state) in raw {
            let (wd_str, hour_str) = key
                .split_once(':')
                .ok_or_else(|| serde::de::Error::custom(format!("invalid key: {key}")))?;
            let wd = str_to_weekday(wd_str).map_err(serde::de::Error::custom)?;
            let hour: u8 = hour_str.parse().map_err(serde::de::Error::custom)?;
            inner.insert((wd, hour), state);
        }
        Ok(Availability(inner))
    }
}

impl Availability {
    pub fn get(&self, weekday: Weekday, hour: u8) -> AvailabilityState {
        self.0
            .get(&(weekday, hour))
            .copied()
            .unwrap_or(AvailabilityState::Maybe)
    }

    pub fn set(&mut self, weekday: Weekday, hour: u8, state: AvailabilityState) {
        self.0.insert((weekday, hour), state);
    }

    /// Returns the worst (minimum) availability state across all hours of a shift window.
    pub fn for_window(&self, weekday: Weekday, start_hour: u8, end_hour: u8) -> AvailabilityState {
        (start_hour..end_hour)
            .map(|h| self.get(weekday, h))
            .min()
            .unwrap_or(AvailabilityState::No)
    }

    /// Serialize to a JSON string for database storage.
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    /// Deserialize from a JSON string (as stored in the database).
    pub fn from_json(s: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(s)
    }
}
