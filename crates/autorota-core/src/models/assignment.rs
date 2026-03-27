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
    /// Snapshot of the employee name at the time of assignment.
    pub employee_name: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_display_roundtrip() {
        for status in [
            AssignmentStatus::Proposed,
            AssignmentStatus::Confirmed,
            AssignmentStatus::Overridden,
        ] {
            let s = status.to_string();
            let parsed: AssignmentStatus = s.parse().unwrap();
            assert_eq!(parsed, status);
        }
    }

    #[test]
    fn status_from_str_invalid() {
        let result: Result<AssignmentStatus, _> = "Invalid".parse();
        assert!(result.is_err());
    }
}
