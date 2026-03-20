use crate::models::assignment::Assignment;
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Rota {
    pub id: i64,
    /// The Monday of the week this rota covers.
    pub week_start: NaiveDate,
    pub assignments: Vec<Assignment>,
    pub finalized: bool,
}
