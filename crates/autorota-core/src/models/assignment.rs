use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AssignmentStatus {
    Proposed,
    Confirmed,
    Overridden,
}

impl fmt::Display for AssignmentStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Proposed => write!(f, "Proposed"),
            Self::Confirmed => write!(f, "Confirmed"),
            Self::Overridden => write!(f, "Overridden"),
        }
    }
}

impl FromStr for AssignmentStatus {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "Proposed" => Ok(Self::Proposed),
            "Confirmed" => Ok(Self::Confirmed),
            "Overridden" => Ok(Self::Overridden),
            other => Err(format!("invalid assignment status: {other}")),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Assignment {
    pub id: i64,
    pub rota_id: i64,
    pub shift_id: i64,
    pub employee_id: i64,
    pub status: AssignmentStatus,
}
