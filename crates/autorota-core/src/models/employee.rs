use crate::models::availability::Availability;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Employee {
    pub id: i64,
    pub name: String,
    pub roles: Vec<String>,
    /// Maximum hours the employee may work in a single day.
    pub max_daily_hours: f32,
    /// Maximum hours the employee may work in a week.
    pub max_weekly_hours: f32,
    /// Default (template) availability — reused each week unless overridden.
    pub default_availability: Availability,
    /// Week-specific availability, copied from default at the start of each scheduling run.
    pub availability: Availability,
}

impl Employee {
    pub fn reset_availability(&mut self) {
        self.availability = self.default_availability.clone();
    }

    pub fn has_role(&self, role: &str) -> bool {
        self.roles.iter().any(|r| r == role)
    }
}
