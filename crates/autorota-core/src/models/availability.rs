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

const HOURS_PER_DAY: usize = 24;
const DAYS_PER_WEEK: usize = 7;

/// Mon..Sun → 0..6, matching `weekday_to_str` / `str_to_weekday`.
fn weekday_index(wd: Weekday) -> usize {
    wd.num_days_from_monday() as usize
}

fn weekday_from_index(i: usize) -> Weekday {
    match i {
        0 => Weekday::Mon,
        1 => Weekday::Tue,
        2 => Weekday::Wed,
        3 => Weekday::Thu,
        4 => Weekday::Fri,
        5 => Weekday::Sat,
        _ => Weekday::Sun,
    }
}

/// Hour-by-hour availability for a single employee.
///
/// Backed by a dense `[[state; 24]; 7]` grid indexed by (weekday, hour_of_day)
/// where hour_of_day is 0–23. Every cell defaults to `Maybe`, so an unset grid
/// reads exactly like the old sparse map (missing key ⇒ `Maybe`). The dense
/// layout removes per-hour hashing and the boxed iterator from the scheduler's
/// hot `for_window` path, and makes out-of-range hours structurally impossible.
///
/// Custom serde serializes only the non-`Maybe` cells as
/// `{"Mon:8": "Yes", "Tue:14": "No", ...}` — a sparse, valid-JSON map that is
/// semantically equivalent to the legacy format (unlisted cells read as `Maybe`).
#[derive(Debug, Clone)]
pub struct Availability(pub [[AvailabilityState; HOURS_PER_DAY]; DAYS_PER_WEEK]);

impl Default for Availability {
    fn default() -> Self {
        Availability([[AvailabilityState::Maybe; HOURS_PER_DAY]; DAYS_PER_WEEK])
    }
}

impl Serialize for Availability {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        // Only cells that differ from the `Maybe` default are stored; unlisted
        // cells read back as `Maybe`. Deterministic (day, hour) order.
        let mut map = serializer.serialize_map(None)?;
        for (d, row) in self.0.iter().enumerate() {
            for (h, &state) in row.iter().enumerate() {
                if state != AvailabilityState::Maybe {
                    let key = format!("{}:{}", weekday_to_str(weekday_from_index(d)), h);
                    map.serialize_entry(&key, &state)?;
                }
            }
        }
        map.end()
    }
}

impl<'de> Deserialize<'de> for Availability {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw: HashMap<String, AvailabilityState> = HashMap::deserialize(deserializer)?;
        let mut grid = Availability::default();
        for (key, state) in raw {
            let (wd_str, hour_str) = key
                .split_once(':')
                .ok_or_else(|| serde::de::Error::custom(format!("invalid key: {key}")))?;
            let wd = str_to_weekday(wd_str).map_err(serde::de::Error::custom)?;
            let hour: u8 = hour_str.parse().map_err(serde::de::Error::custom)?;
            // Out-of-range hours are unrepresentable in the dense grid; drop them
            // (they were never schedulable — the scheduler only probes 0..23).
            if (hour as usize) < HOURS_PER_DAY {
                grid.0[weekday_index(wd)][hour as usize] = state;
            }
        }
        Ok(grid)
    }
}

impl Availability {
    pub fn get(&self, weekday: Weekday, hour: u8) -> AvailabilityState {
        if (hour as usize) >= HOURS_PER_DAY {
            return AvailabilityState::Maybe;
        }
        self.0[weekday_index(weekday)][hour as usize]
    }

    pub fn set(&mut self, weekday: Weekday, hour: u8, state: AvailabilityState) {
        if (hour as usize) < HOURS_PER_DAY {
            self.0[weekday_index(weekday)][hour as usize] = state;
        }
    }

    /// True when every cell is `Maybe` — i.e. a blank grid the manager never
    /// touched (equivalent to the old empty sparse map).
    pub fn is_blank(&self) -> bool {
        self.0
            .iter()
            .flatten()
            .all(|&s| s == AvailabilityState::Maybe)
    }

    /// Returns the worst (minimum) availability state across all hours of a shift window.
    /// Handles overnight shifts where end_hour < start_hour.
    ///
    /// A tight scan over one weekday's dense row — no allocation, no hashing.
    /// `start_hour` is always ≤ 23 (a `NaiveTime` hour), so the window is never
    /// empty; `Yes` is the min-fold identity.
    pub fn for_window(&self, weekday: Weekday, start_hour: u8, end_hour: u8) -> AvailabilityState {
        let row = &self.0[weekday_index(weekday)];
        let mut worst = AvailabilityState::Yes;
        if end_hour > start_hour {
            for h in start_hour..end_hour {
                worst = worst.min(row[h as usize]);
            }
        } else {
            // Overnight: e.g. 22..24 then 0..02
            for h in start_hour..HOURS_PER_DAY as u8 {
                worst = worst.min(row[h as usize]);
            }
            for h in 0..end_hour {
                worst = worst.min(row[h as usize]);
            }
        }
        worst
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_missing_key_returns_maybe() {
        let avail = Availability::default();
        assert_eq!(avail.get(Weekday::Mon, 8), AvailabilityState::Maybe);
    }

    #[test]
    fn set_and_get() {
        let mut avail = Availability::default();
        avail.set(Weekday::Tue, 14, AvailabilityState::Yes);
        assert_eq!(avail.get(Weekday::Tue, 14), AvailabilityState::Yes);
    }

    #[test]
    fn for_window_all_yes() {
        let mut avail = Availability::default();
        for h in 7..12 {
            avail.set(Weekday::Mon, h, AvailabilityState::Yes);
        }
        assert_eq!(
            avail.for_window(Weekday::Mon, 7, 12),
            AvailabilityState::Yes
        );
    }

    #[test]
    fn for_window_one_maybe_downgrades() {
        let mut avail = Availability::default();
        for h in 7..12 {
            avail.set(Weekday::Mon, h, AvailabilityState::Yes);
        }
        avail.set(Weekday::Mon, 9, AvailabilityState::Maybe);
        assert_eq!(
            avail.for_window(Weekday::Mon, 7, 12),
            AvailabilityState::Maybe
        );
    }

    #[test]
    fn for_window_one_no_downgrades() {
        let mut avail = Availability::default();
        for h in 7..12 {
            avail.set(Weekday::Mon, h, AvailabilityState::Yes);
        }
        avail.set(Weekday::Mon, 10, AvailabilityState::No);
        assert_eq!(avail.for_window(Weekday::Mon, 7, 12), AvailabilityState::No);
    }

    #[test]
    fn for_window_overnight() {
        let mut avail = Availability::default();
        for h in 22..24 {
            avail.set(Weekday::Fri, h, AvailabilityState::Yes);
        }
        for h in 0..2 {
            avail.set(Weekday::Fri, h, AvailabilityState::Yes);
        }
        assert_eq!(
            avail.for_window(Weekday::Fri, 22, 2),
            AvailabilityState::Yes
        );
    }

    #[test]
    fn for_window_overnight_partial_no() {
        let mut avail = Availability::default();
        for h in 22..24 {
            avail.set(Weekday::Fri, h, AvailabilityState::Yes);
        }
        avail.set(Weekday::Fri, 0, AvailabilityState::No);
        avail.set(Weekday::Fri, 1, AvailabilityState::Yes);
        assert_eq!(avail.for_window(Weekday::Fri, 22, 2), AvailabilityState::No);
    }

    #[test]
    fn for_window_empty_availability_returns_maybe() {
        let avail = Availability::default();
        // All unset hours default to Maybe
        assert_eq!(
            avail.for_window(Weekday::Mon, 7, 12),
            AvailabilityState::Maybe
        );
    }

    #[test]
    fn json_serde_roundtrip() {
        let mut avail = Availability::default();
        avail.set(Weekday::Mon, 8, AvailabilityState::Yes);
        avail.set(Weekday::Wed, 14, AvailabilityState::No);
        avail.set(Weekday::Fri, 20, AvailabilityState::Maybe);

        let json = avail.to_json().unwrap();
        let restored = Availability::from_json(&json).unwrap();

        assert_eq!(restored.get(Weekday::Mon, 8), AvailabilityState::Yes);
        assert_eq!(restored.get(Weekday::Wed, 14), AvailabilityState::No);
        assert_eq!(restored.get(Weekday::Fri, 20), AvailabilityState::Maybe);
    }

    #[test]
    fn json_deserialize_invalid_key_format() {
        let bad_json = r#"{"Monday:8": "Yes"}"#;
        let result = Availability::from_json(bad_json);
        assert!(result.is_err());
    }

    #[test]
    fn json_deserialize_invalid_hour() {
        let bad_json = r#"{"Mon:abc": "Yes"}"#;
        let result = Availability::from_json(bad_json);
        assert!(result.is_err());
    }

    #[test]
    fn availability_state_display_roundtrip() {
        for state in [
            AvailabilityState::No,
            AvailabilityState::Maybe,
            AvailabilityState::Yes,
        ] {
            let s = state.to_string();
            let parsed: AvailabilityState = s.parse().unwrap();
            assert_eq!(parsed, state);
        }
    }

    #[test]
    fn availability_state_from_str_invalid() {
        let result: Result<AvailabilityState, _> = "Invalid".parse();
        assert!(result.is_err());
    }

    #[test]
    fn availability_state_ordering() {
        assert!(AvailabilityState::No < AvailabilityState::Maybe);
        assert!(AvailabilityState::Maybe < AvailabilityState::Yes);
    }
}
