use std::fmt;
use std::str::FromStr;

/// Grid layout: rows × columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportLayout {
    /// Rows = employees, columns = Mon–Sun.
    EmployeeByWeekday,
    /// Rows = shift timeslots, columns = Mon–Sun.
    ShiftByWeekday,
}

impl FromStr for ExportLayout {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "employee_by_weekday" => Ok(Self::EmployeeByWeekday),
            "shift_by_weekday" => Ok(Self::ShiftByWeekday),
            other => Err(format!("invalid export layout: {other}")),
        }
    }
}

impl fmt::Display for ExportLayout {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmployeeByWeekday => write!(f, "employee_by_weekday"),
            Self::ShiftByWeekday => write!(f, "shift_by_weekday"),
        }
    }
}

/// Output format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    Csv,
    Json,
}

impl FromStr for ExportFormat {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "csv" => Ok(Self::Csv),
            "json" => Ok(Self::Json),
            other => Err(format!("invalid export format: {other}")),
        }
    }
}

impl fmt::Display for ExportFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Csv => write!(f, "csv"),
            Self::Json => write!(f, "json"),
        }
    }
}

/// Export profile controlling what data is included.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportProfile {
    /// Schedule only — no wage/cost data.
    StaffSchedule,
    /// Full report including wages and costs.
    ManagerReport,
}

impl FromStr for ExportProfile {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "staff_schedule" => Ok(Self::StaffSchedule),
            "manager_report" => Ok(Self::ManagerReport),
            other => Err(format!("invalid export profile: {other}")),
        }
    }
}

impl fmt::Display for ExportProfile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::StaffSchedule => write!(f, "staff_schedule"),
            Self::ManagerReport => write!(f, "manager_report"),
        }
    }
}

/// Which fields to show in each grid cell.
#[derive(Debug, Clone)]
pub struct CellContentFlags {
    pub show_shift_name: bool,
    pub show_times: bool,
    pub show_role: bool,
}

/// Full export configuration.
#[derive(Debug, Clone)]
pub struct ExportConfig {
    pub layout: ExportLayout,
    pub format: ExportFormat,
    pub profile: ExportProfile,
    pub cell_content: CellContentFlags,
}

/// Result of an export operation.
#[derive(Debug, Clone)]
pub struct ExportResult {
    pub data: String,
    pub filename: String,
    pub mime_type: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_roundtrip() {
        for layout in [ExportLayout::EmployeeByWeekday, ExportLayout::ShiftByWeekday] {
            let s = layout.to_string();
            let parsed: ExportLayout = s.parse().unwrap();
            assert_eq!(parsed, layout);
        }
    }

    #[test]
    fn format_roundtrip() {
        for fmt in [ExportFormat::Csv, ExportFormat::Json] {
            let s = fmt.to_string();
            let parsed: ExportFormat = s.parse().unwrap();
            assert_eq!(parsed, fmt);
        }
    }

    #[test]
    fn profile_roundtrip() {
        for profile in [ExportProfile::StaffSchedule, ExportProfile::ManagerReport] {
            let s = profile.to_string();
            let parsed: ExportProfile = s.parse().unwrap();
            assert_eq!(parsed, profile);
        }
    }

    #[test]
    fn invalid_layout() {
        assert!("invalid".parse::<ExportLayout>().is_err());
    }

    #[test]
    fn invalid_format() {
        assert!("invalid".parse::<ExportFormat>().is_err());
    }

    #[test]
    fn invalid_profile() {
        assert!("invalid".parse::<ExportProfile>().is_err());
    }
}
