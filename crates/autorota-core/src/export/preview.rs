//! Synthetic-fixture previews. Feed the same renderer path used by live
//! exports so a preview is pixel-identical to what the user will get when
//! they export the real rota.

use chrono::NaiveDate;

use crate::models::{
    assignment::{Assignment, AssignmentStatus},
    availability::Availability,
    employee::Employee,
    shift::{Shift, ShiftTemplate},
};

use super::config::{EmployeeExportConfig, ExportConfig, ExportResult};
use super::{ExportError, render_employee_export, render_week_export};

/// Fixed Monday used as the preview week. Year picked to be distinct so the
/// sample can't be mistaken for a real week in the user's data.
const PREVIEW_WEEK: &str = "2099-04-20";

/// Generate a full-rota preview using synthetic template data.
pub fn generate_preview_full(config: ExportConfig) -> Result<ExportResult, ExportError> {
    let fx = Fixture::build();
    render_week_export(
        fx.week_start,
        &fx.assignments,
        &fx.shifts,
        &fx.employees,
        &fx.templates,
        &config,
    )
}

/// Generate a per-employee preview using synthetic template data. Picks the
/// first fixture employee regardless of `config.employee_id`.
pub fn generate_preview_employee(
    config: EmployeeExportConfig,
) -> Result<ExportResult, ExportError> {
    let fx = Fixture::build();
    let employee = &fx.employees[0];
    let end = fx.week_start + chrono::Duration::days(6);

    let emp_assignments: Vec<Assignment> = fx
        .assignments
        .iter()
        .filter(|a| a.employee_id == employee.id)
        .cloned()
        .collect();

    render_employee_export(
        &employee.display_name(),
        employee.id,
        fx.week_start,
        end,
        &emp_assignments,
        &fx.shifts,
        &fx.templates,
        &config,
    )
}

struct Fixture {
    week_start: NaiveDate,
    employees: Vec<Employee>,
    templates: Vec<ShiftTemplate>,
    shifts: Vec<Shift>,
    assignments: Vec<Assignment>,
}

impl Fixture {
    fn build() -> Self {
        let week_start: NaiveDate = PREVIEW_WEEK
            .parse()
            .expect("hard-coded preview date parses");

        let employees = vec![
            emp(1, "Alice", "Chen", None, &["Barista"], 12.0, "gbp"),
            emp(2, "Bob", "Sato", None, &["Barista"], 11.0, "gbp"),
            emp(
                3,
                "Cara",
                "Liu",
                Some("C"),
                &["Lead Barista", "Barista"],
                15.0,
                "gbp",
            ),
            emp(4, "Dan", "Park", None, &["Kitchen"], 13.0, "gbp"),
            emp(5, "Eve", "Mori", None, &["Kitchen", "Barista"], 14.0, "gbp"),
        ];

        let templates = vec![
            tmpl(1, "Opening", "Barista", 8, 12),
            tmpl(2, "Midday", "Barista", 12, 16),
            tmpl(3, "Close", "Barista", 16, 20),
            tmpl(4, "Kitchen", "Kitchen", 9, 15),
            tmpl(5, "Lead", "Lead Barista", 10, 18),
        ];

        // ~20 shifts Mon–Sun. Builder yields (date_offset, template_id, assigned_employee).
        let spec: &[(i64, i64, Option<(i64, AssignmentStatus)>)] = &[
            // Mon
            (0, 1, Some((1, AssignmentStatus::Confirmed))),
            (0, 2, Some((2, AssignmentStatus::Confirmed))),
            (0, 4, Some((4, AssignmentStatus::Confirmed))),
            (0, 5, Some((3, AssignmentStatus::Confirmed))),
            // Tue
            (1, 1, Some((2, AssignmentStatus::Confirmed))),
            (1, 2, Some((5, AssignmentStatus::Proposed))),
            (1, 4, Some((4, AssignmentStatus::Confirmed))),
            // Wed
            (2, 1, Some((1, AssignmentStatus::Confirmed))),
            (2, 3, Some((3, AssignmentStatus::Confirmed))),
            (2, 4, Some((4, AssignmentStatus::Proposed))),
            // Thu
            (3, 2, Some((1, AssignmentStatus::Confirmed))),
            (3, 3, Some((2, AssignmentStatus::Confirmed))),
            (3, 5, Some((3, AssignmentStatus::Confirmed))),
            // Fri
            (4, 1, Some((5, AssignmentStatus::Confirmed))),
            (4, 2, Some((1, AssignmentStatus::Confirmed))),
            (4, 3, None), // intentionally unfilled
            (4, 4, Some((4, AssignmentStatus::Confirmed))),
            // Sat
            (5, 1, Some((2, AssignmentStatus::Confirmed))),
            (5, 5, Some((3, AssignmentStatus::Confirmed))),
            // Sun
            (6, 2, Some((5, AssignmentStatus::Confirmed))),
        ];

        let mut shifts = Vec::with_capacity(spec.len());
        let mut assignments = Vec::new();
        let mut next_shift_id: i64 = 1;
        let mut next_assignment_id: i64 = 1;

        let tmpl_by_id: std::collections::HashMap<i64, &ShiftTemplate> =
            templates.iter().map(|t| (t.id, t)).collect();

        for (offset, template_id, who) in spec {
            let tmpl = tmpl_by_id[template_id];
            let shift = Shift {
                id: next_shift_id,
                template_id: Some(tmpl.id),
                rota_id: 1,
                date: week_start + chrono::Duration::days(*offset),
                start_time: tmpl.start_time,
                end_time: tmpl.end_time,
                required_role: tmpl.required_role.clone(),
                min_employees: tmpl.min_employees,
                max_employees: tmpl.max_employees,
            };

            if let Some((emp_id, status)) = who {
                let emp = employees.iter().find(|e| e.id == *emp_id).unwrap();
                assignments.push(Assignment {
                    id: next_assignment_id,
                    rota_id: 1,
                    shift_id: next_shift_id,
                    employee_id: *emp_id,
                    status: *status,
                    employee_name: Some(emp.display_name()),
                    hourly_wage: emp.hourly_wage,
                });
                next_assignment_id += 1;
            }

            shifts.push(shift);
            next_shift_id += 1;
        }

        Self {
            week_start,
            employees,
            templates,
            shifts,
            assignments,
        }
    }
}

fn emp(
    id: i64,
    first: &str,
    last: &str,
    nickname: Option<&str>,
    roles: &[&str],
    wage: f32,
    currency: &str,
) -> Employee {
    Employee {
        id,
        first_name: first.to_string(),
        last_name: last.to_string(),
        nickname: nickname.map(str::to_string),
        roles: roles.iter().map(|r| r.to_string()).collect(),
        start_date: NaiveDate::from_ymd_opt(2099, 1, 1).unwrap(),
        target_weekly_hours: 30.0,
        weekly_hours_deviation: 6.0,
        max_daily_hours: 9.0,
        notes: None,
        bank_details: None,
        phone: None,
        email: None,
        preferred_contact: None,
        hourly_wage: Some(wage),
        wage_currency: Some(currency.to_string()),
        default_availability: Availability::default(),
        availability: Availability::default(),
        deleted: false,
    }
}

fn tmpl(id: i64, name: &str, role: &str, start_h: u32, end_h: u32) -> ShiftTemplate {
    ShiftTemplate {
        id,
        name: name.to_string(),
        weekdays: vec![
            chrono::Weekday::Mon,
            chrono::Weekday::Tue,
            chrono::Weekday::Wed,
            chrono::Weekday::Thu,
            chrono::Weekday::Fri,
            chrono::Weekday::Sat,
            chrono::Weekday::Sun,
        ],
        start_time: chrono::NaiveTime::from_hms_opt(start_h, 0, 0).unwrap(),
        end_time: chrono::NaiveTime::from_hms_opt(end_h, 0, 0).unwrap(),
        required_role: role.to_string(),
        min_employees: 1,
        max_employees: 2,
        deleted: false,
    }
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
}
