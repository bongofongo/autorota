//! Synthetic-fixture previews. Feed the same renderer path used by live
//! exports so a preview is pixel-identical to what the user will get when
//! they export the real rota.
//!
//! The fixture itself lives in [`crate::sample`] and is shared so any
//! sample-data surface in the app uses one canonical dataset.

use chrono::Duration;

use crate::sample::{SampleWeek, build_sample_week};

use super::config::{EmployeeExportConfig, ExportConfig, ExportResult};
use super::{ExportError, render_employee_export, render_week_export};

/// Generate a full-rota preview using the canonical sample dataset.
///
/// Note: `config.employee_id`, `config.start_date`, and `config.end_date` are
/// ignored — the fixture week is fixed and the layout / format / template /
/// profile fields are the only ones honored.
pub fn generate_preview_full(config: ExportConfig) -> Result<ExportResult, ExportError> {
    let SampleWeek {
        week_start,
        employees,
        templates,
        shifts,
        assignments,
    } = build_sample_week();

    render_week_export(
        week_start,
        &assignments,
        &shifts,
        &employees,
        &templates,
        &config,
    )
}

/// Generate a per-employee preview using the canonical sample dataset.
///
/// Always renders the first fixture employee regardless of `config.employee_id`.
pub fn generate_preview_employee(
    config: EmployeeExportConfig,
) -> Result<ExportResult, ExportError> {
    let SampleWeek {
        week_start,
        employees,
        templates,
        shifts,
        assignments,
    } = build_sample_week();

    let employee = &employees[0];
    let end = week_start + Duration::days(6);

    let emp_assignments: Vec<_> = assignments
        .iter()
        .filter(|a| a.employee_id == employee.id)
        .cloned()
        .collect();

    render_employee_export(
        &employee.display_name(),
        employee.id,
        week_start,
        end,
        &emp_assignments,
        &shifts,
        &templates,
        &config,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::config::{
        CellContentFlags, ExportFormat, ExportLayout, ExportProfile, PdfTemplate,
    };

    fn full_cfg(format: ExportFormat, profile: ExportProfile) -> ExportConfig {
        ExportConfig {
            layout: ExportLayout::EmployeeByWeekday,
            format,
            profile,
            cell_content: CellContentFlags {
                show_shift_name: true,
                show_times: true,
                show_role: true,
            },
            pdf_template: Some(PdfTemplate::WeeklyGrid),
            role_sections: None,
            row_content: None,
        }
    }

    fn emp_cfg(format: ExportFormat, profile: ExportProfile) -> EmployeeExportConfig {
        EmployeeExportConfig {
            employee_id: 1,
            format,
            profile,
            cell_content: CellContentFlags {
                show_shift_name: true,
                show_times: true,
                show_role: true,
            },
            timezone_id: Some("Europe/London".to_string()),
        }
    }

    #[test]
    fn full_pdf_preview_renders_nonempty() {
        let r = generate_preview_full(full_cfg(ExportFormat::Pdf, ExportProfile::StaffSchedule))
            .unwrap();
        assert!(!r.data.is_empty());
        assert_eq!(r.mime_type, "application/pdf");
    }

    #[test]
    fn full_pdf_manager_report_renders() {
        let r = generate_preview_full(full_cfg(ExportFormat::Pdf, ExportProfile::ManagerReport))
            .unwrap();
        assert!(!r.data.is_empty());
    }

    #[test]
    fn employee_pdf_preview_renders() {
        let r = generate_preview_employee(emp_cfg(ExportFormat::Pdf, ExportProfile::StaffSchedule))
            .unwrap();
        assert!(!r.data.is_empty());
        assert_eq!(r.mime_type, "application/pdf");
    }

    #[test]
    fn full_csv_preview_has_rows() {
        let r = generate_preview_full(full_cfg(ExportFormat::Csv, ExportProfile::StaffSchedule))
            .unwrap();
        assert!(r.data.lines().count() > 2);
    }

    // Regression: employee ICS preview must only contain that employee's
    // assigned shifts, not one event per day of the week. Employee 1 in the
    // sample week is assigned on 4 days (Mon/Wed/Thu/Fri), so exactly 4 events.
    #[test]
    fn employee_ics_preview_only_has_assigned_events() {
        let r = generate_preview_employee(emp_cfg(ExportFormat::Ics, ExportProfile::StaffSchedule))
            .unwrap();
        assert_eq!(r.mime_type, "text/calendar");
        assert_eq!(
            r.data.matches("BEGIN:VEVENT").count(),
            4,
            "expected 4 assigned events for employee 1, got:\n{}",
            r.data
        );
    }
}
