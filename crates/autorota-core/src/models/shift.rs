use chrono::{Datelike, NaiveDate, NaiveTime, Timelike, Weekday};
use serde::{Deserialize, Serialize};

/// A single per-role staffing requirement on a shift or template: at least
/// `min_count` assigned employees must hold `role`. One employee who holds
/// several required roles satisfies one unit of each simultaneously.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoleRequirement {
    pub role: String,
    pub min_count: u32,
}

/// A reusable weekly pattern that generates concrete Shifts.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShiftTemplate {
    pub id: i64,
    pub name: String,
    pub weekdays: Vec<Weekday>,
    pub start_time: NaiveTime,
    pub end_time: NaiveTime,
    /// Legacy single-role field. No longer used for scheduling; kept for
    /// backward compatibility and migration. See `role_requirements`.
    pub required_role: String,
    /// Overall minimum headcount. The *effective* minimum is the larger of this
    /// and the role-derived floor (see `Shift::effective_min`).
    pub min_employees: u32,
    pub max_employees: u32,
    /// Per-role minimums. Empty ⇒ wildcard (any available staff).
    #[serde(default)]
    pub role_requirements: Vec<RoleRequirement>,
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
    /// Legacy single-role field. No longer used for scheduling; kept for
    /// backward compatibility and migration. See `role_requirements`.
    pub required_role: String,
    /// Overall minimum headcount (possibly raised above the role-derived floor).
    pub min_employees: u32,
    pub max_employees: u32,
    /// Per-role minimums. Empty ⇒ wildcard (any available staff).
    #[serde(default)]
    pub role_requirements: Vec<RoleRequirement>,
}

impl ShiftTemplate {
    /// Returns true if this template constrains roles.
    pub fn has_required_role(&self) -> bool {
        !self.role_requirements.is_empty()
    }
}

/// Canonical midnight-crossing rule shared by the scheduler, exporters and
/// models: a `(start, end)` time pair crosses midnight iff `end < start`.
/// `end == start` is a zero-duration same-day interval, not a 24h one.
pub fn crosses_midnight(start: NaiveTime, end: NaiveTime) -> bool {
    end < start
}

/// Duration in hours of a `(start, end)` time pair, wrapping past midnight
/// when [`crosses_midnight`] holds.
pub fn duration_hours(start: NaiveTime, end: NaiveTime) -> f32 {
    let s = start.num_seconds_from_midnight();
    let e = end.num_seconds_from_midnight();
    let secs = if crosses_midnight(start, end) {
        86400 - s + e
    } else {
        e - s
    };
    secs as f32 / 3600.0
}

impl Shift {
    /// Returns true if this shift constrains roles.
    pub fn has_required_role(&self) -> bool {
        !self.role_requirements.is_empty()
    }

    /// The headcount floor implied by the role minimums: the largest single
    /// role minimum (one person can cover several distinct roles, but a role
    /// needing N distinct holders forces N people). Zero when unconstrained.
    pub fn derived_min(&self) -> u32 {
        self.role_requirements
            .iter()
            .map(|r| r.min_count)
            .max()
            .unwrap_or(0)
    }

    /// The minimum headcount that actually applies: the larger of the manual
    /// `min_employees` and the role-derived floor.
    pub fn effective_min(&self) -> u32 {
        self.min_employees.max(self.derived_min())
    }

    /// True when the shift wraps past midnight into the next day.
    pub fn crosses_midnight(&self) -> bool {
        crosses_midnight(self.start_time, self.end_time)
    }

    pub fn duration_hours(&self) -> f32 {
        duration_hours(self.start_time, self.end_time)
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
    use crate::testutil::ShiftBuilder;

    fn make_shift(start: (u32, u32), end: (u32, u32), date: (i32, u32, u32)) -> Shift {
        ShiftBuilder::new()
            .id(1)
            .date(NaiveDate::from_ymd_opt(date.0, date.1, date.2).unwrap())
            .times_hm(start, end)
            .role("Barista")
            .build()
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

    #[test]
    fn has_required_role_true_for_named_role() {
        let s = make_shift((7, 0), (12, 0), (2026, 3, 23));
        assert!(s.has_required_role());
    }

    #[test]
    fn has_required_role_false_for_empty() {
        let mut s = make_shift((7, 0), (12, 0), (2026, 3, 23));
        s.required_role = "".into();
        s.role_requirements.clear();
        assert!(!s.has_required_role());
    }

    #[test]
    fn derived_and_effective_min() {
        // 2 baristas → floor 2; 1 barista + 1 opening → floor 1 (shared cover).
        let mut s = make_shift((7, 0), (12, 0), (2026, 3, 23));
        s.role_requirements = vec![
            RoleRequirement {
                role: "barista".into(),
                min_count: 1,
            },
            RoleRequirement {
                role: "opening".into(),
                min_count: 1,
            },
        ];
        s.min_employees = 1;
        assert_eq!(s.derived_min(), 1);
        assert_eq!(s.effective_min(), 1);

        s.role_requirements = vec![RoleRequirement {
            role: "barista".into(),
            min_count: 2,
        }];
        assert_eq!(s.derived_min(), 2);
        assert_eq!(s.effective_min(), 2);

        // Manual min can raise above the role floor.
        s.min_employees = 3;
        assert_eq!(s.effective_min(), 3);
    }
}
