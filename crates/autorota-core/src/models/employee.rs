use crate::models::availability::Availability;
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Employee {
    pub id: i64,
    pub first_name: String,
    pub last_name: String,
    pub nickname: Option<String>,
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
    /// Contact phone number (free-form, no validation).
    pub phone: Option<String>,
    /// Contact email address (free-form, no validation).
    pub email: Option<String>,
    /// Messaging app linked to the phone number.
    /// `"imessage"` | `"whatsapp"` | `None` (phone not linked / no phone).
    pub preferred_contact: Option<String>,
    /// Hourly wage rate.
    pub hourly_wage: Option<f32>,
    /// Currency code for the wage (e.g. "usd", "gbp", "eur").
    pub wage_currency: Option<String>,
    /// Default (template) availability — reused each week unless overridden.
    pub default_availability: Availability,
    /// Week-specific availability, copied from default at the start of each scheduling run.
    pub availability: Availability,
    /// Soft-delete flag: true if the employee has been removed.
    #[serde(default)]
    pub deleted: bool,
}

impl Employee {
    /// Returns the nickname if set, otherwise "first_name last_name".
    pub fn display_name(&self) -> String {
        match &self.nickname {
            Some(n) if !n.is_empty() => n.clone(),
            _ => format!("{} {}", self.first_name, self.last_name),
        }
    }

    /// The hard upper bound on weekly hours for scheduling eligibility.
    pub fn max_weekly_hours(&self) -> f32 {
        self.target_weekly_hours + self.weekly_hours_deviation
    }

    pub fn has_role(&self, role: &str) -> bool {
        self.roles.iter().any(|r| r == role)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::EmployeeBuilder;

    fn make_employee() -> Employee {
        EmployeeBuilder::new("Alice")
            .id(1)
            .last_name("Smith")
            .roles(&["Barista", "Cashier"])
            .hours(30.0)
            .build()
    }

    #[test]
    fn display_name_uses_full_name_when_no_nickname() {
        let e = make_employee();
        assert_eq!(e.display_name(), "Alice Smith");
    }

    #[test]
    fn display_name_uses_nickname_when_present() {
        let mut e = make_employee();
        e.nickname = Some("Ally".into());
        assert_eq!(e.display_name(), "Ally");
    }

    #[test]
    fn display_name_ignores_empty_nickname() {
        let mut e = make_employee();
        e.nickname = Some("".into());
        assert_eq!(e.display_name(), "Alice Smith");
    }

    #[test]
    fn max_weekly_hours_is_target_plus_deviation() {
        let e = make_employee();
        assert_eq!(e.max_weekly_hours(), 36.0);
    }

    #[test]
    fn has_role_matches() {
        let e = make_employee();
        assert!(e.has_role("Barista"));
        assert!(e.has_role("Cashier"));
        assert!(!e.has_role("Manager"));
    }

    #[test]
    fn has_role_empty_roles() {
        let mut e = make_employee();
        e.roles.clear();
        assert!(!e.has_role("Barista"));
    }
}
