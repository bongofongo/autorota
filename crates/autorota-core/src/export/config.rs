use std::fmt;
use std::str::FromStr;

/// Generate matching `FromStr`/`Display` impls mapping each variant to its
/// canonical string form. `$label` names the type in the parse error, e.g.
/// `"export layout"` → `"invalid export layout: {other}"`.
macro_rules! string_enum {
    ($ty:ident, $label:literal, { $($variant:ident => $s:literal),+ $(,)? }) => {
        impl FromStr for $ty {
            type Err = String;
            fn from_str(s: &str) -> Result<Self, Self::Err> {
                match s {
                    $($s => Ok(Self::$variant),)+
                    other => Err(format!(concat!("invalid ", $label, ": {}"), other)),
                }
            }
        }

        impl fmt::Display for $ty {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                match self {
                    $(Self::$variant => write!(f, $s),)+
                }
            }
        }
    };
}

/// Grid layout: rows × columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportLayout {
    /// Rows = employees, columns = Mon–Sun.
    EmployeeByWeekday,
    /// Rows = shift timeslots, columns = Mon–Sun.
    ShiftByWeekday,
}

string_enum!(ExportLayout, "export layout", {
    EmployeeByWeekday => "employee_by_weekday",
    ShiftByWeekday => "shift_by_weekday",
});

/// Output format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    Csv,
    Json,
    Pdf,
    Xlsx,
    Markdown,
    Ics,
}

string_enum!(ExportFormat, "export format", {
    Csv => "csv",
    Json => "json",
    Pdf => "pdf",
    Xlsx => "xlsx",
    Markdown => "markdown",
    Ics => "ics",
});

/// Fixed PDF template selection (only consulted when format == Pdf).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PdfTemplate {
    /// Single weekly grid (reuses ExportLayout).
    WeeklyGrid,
    /// One section per employee listing their shifts for the week.
    PerEmployee,
    /// One grid per role, stacked in a single PDF.
    ByRole,
}

string_enum!(PdfTemplate, "pdf template", {
    WeeklyGrid => "weekly_grid",
    PerEmployee => "per_employee",
    ByRole => "by_role",
});

/// Export profile controlling what data is included.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportProfile {
    /// Schedule only — no wage/cost data.
    StaffSchedule,
    /// Full report including wages and costs.
    ManagerReport,
}

string_enum!(ExportProfile, "export profile", {
    StaffSchedule => "staff_schedule",
    ManagerReport => "manager_report",
});

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
    /// Selected PDF template (only meaningful when format == Pdf).
    pub pdf_template: Option<PdfTemplate>,
    /// Ordered role names; when non-empty the export is split into one grid
    /// per role (custom layouts). `None` keeps the single-table output.
    pub role_sections: Option<Vec<String>>,
    /// Row-header content for `ShiftByWeekday`. `None` keeps the legacy
    /// label (template name + times, role gated on `cell_content.show_role`).
    pub row_content: Option<CellContentFlags>,
}

/// Configuration for a single-employee schedule export.
#[derive(Debug, Clone)]
pub struct EmployeeExportConfig {
    pub employee_id: i64,
    pub format: ExportFormat,
    pub profile: ExportProfile,
    pub cell_content: CellContentFlags,
    /// IANA timezone (e.g. `"Europe/London"`). Only consulted when
    /// `format == Ics`; when `None` the ICS output uses floating local times.
    pub timezone_id: Option<String>,
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
        for layout in [
            ExportLayout::EmployeeByWeekday,
            ExportLayout::ShiftByWeekday,
        ] {
            let s = layout.to_string();
            let parsed: ExportLayout = s.parse().unwrap();
            assert_eq!(parsed, layout);
        }
    }

    #[test]
    fn format_roundtrip() {
        for fmt in [
            ExportFormat::Csv,
            ExportFormat::Json,
            ExportFormat::Pdf,
            ExportFormat::Xlsx,
            ExportFormat::Markdown,
            ExportFormat::Ics,
        ] {
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
