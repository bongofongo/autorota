use crate::models::availability::Availability;
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Employee {
    pub id: i64,
    pub name: String,
    pub roles: Vec<String>,
    /// Date the employee started (defaults to creation date).
    pub start_date: NaiveDate,
    /// Target hours the employee wants to work per week.
    pub target_weekly_hours: f32,
    /// Permissible deviation from target weekly hours (e.g. 6 means ±6h).
    pub weekly_hours_deviation: f32,
    /// Maximum hours the employee may work in a single day.
    pub max_daily_hours: f32,
    /// Free-form notes about the employee.
    pub notes: Option<String>,
    /// Bank details for payment.
    pub bank_details: Option<String>,
    /// Default (template) availability — reused each week unless overridden.
    pub default_availability: Availability,
    /// Week-specific availability, copied from default at the start of each scheduling run.
    pub availability: Availability,
}

impl Employee {
    /// The hard upper bound on weekly hours for scheduling eligibility.
    pub fn max_weekly_hours(&self) -> f32 {
        self.target_weekly_hours + self.weekly_hours_deviation
    }

    /// The minimum desired weekly hours (used for fairness scoring).
    pub fn min_weekly_hours(&self) -> f32 {
        (self.target_weekly_hours - self.weekly_hours_deviation).max(0.0)
    }

    pub fn reset_availability(&mut self) {
        self.availability = self.default_availability.clone();
    }

    pub fn has_role(&self, role: &str) -> bool {
        self.roles.iter().any(|r| r == role)
    }
}
