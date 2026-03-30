use std::collections::HashMap;

use chrono::{NaiveDate, Weekday};

use crate::models::assignment::Assignment;
use crate::models::employee::Employee;
use crate::models::shift::{Shift, ShiftTemplate};

use super::config::{CellContentFlags, ExportConfig, ExportLayout, ExportProfile};

/// Summary for a single day (ManagerReport only).
#[derive(Debug, Clone)]
pub struct DaySummary {
    pub total_hours: f32,
    pub total_cost: f32,
}

/// Intermediate grid representation consumed by CSV/JSON serializers.
#[derive(Debug, Clone)]
pub struct ExportGrid {
    pub title: String,
    pub column_headers: Vec<String>,
    pub row_headers: Vec<String>,
    pub cells: Vec<Vec<String>>,
    pub daily_totals: Option<Vec<DaySummary>>,
    pub weekly_total_cost: Option<f32>,
}

/// Denormalized assignment with all the data needed for grid building.
struct ResolvedAssignment<'a> {
    employee_name: String,
    shift: &'a Shift,
    shift_name: String,
    hourly_wage: Option<f32>,
}

pub fn build_grid(
    config: &ExportConfig,
    week_start: NaiveDate,
    assignments: &[Assignment],
    shifts: &[Shift],
    employees: &[Employee],
    templates: &[ShiftTemplate],
) -> ExportGrid {
    let emp_map: HashMap<i64, &Employee> = employees.iter().map(|e| (e.id, e)).collect();
    let tmpl_map: HashMap<i64, &ShiftTemplate> = templates.iter().map(|t| (t.id, t)).collect();
    let shift_map: HashMap<i64, &Shift> = shifts.iter().map(|s| (s.id, s)).collect();

    // Resolve all assignments into denormalized records.
    let resolved: Vec<ResolvedAssignment> = assignments
        .iter()
        .filter_map(|a| {
            let shift = shift_map.get(&a.shift_id)?;
            let employee_name = emp_map
                .get(&a.employee_id)
                .map(|e| e.display_name())
                .or_else(|| a.employee_name.clone())
                .unwrap_or_else(|| format!("Employee #{}", a.employee_id));
            let shift_name = shift
                .template_id
                .and_then(|tid| tmpl_map.get(&tid))
                .map(|t| t.name.clone())
                .unwrap_or_else(|| {
                    format!(
                        "{} {}-{}",
                        shift.required_role,
                        shift.start_time.format("%H:%M"),
                        shift.end_time.format("%H:%M"),
                    )
                });
            Some(ResolvedAssignment {
                employee_name,
                shift,
                shift_name,
                hourly_wage: a.hourly_wage,
            })
        })
        .collect();

    // Build column headers: Mon 23 Mar, Tue 24 Mar, ...
    let weekdays = [
        Weekday::Mon,
        Weekday::Tue,
        Weekday::Wed,
        Weekday::Thu,
        Weekday::Fri,
        Weekday::Sat,
        Weekday::Sun,
    ];
    let dates: Vec<NaiveDate> = weekdays
        .iter()
        .map(|wd| {
            let offset = wd.num_days_from_monday();
            week_start + chrono::Duration::days(offset as i64)
        })
        .collect();
    let column_headers: Vec<String> = dates
        .iter()
        .map(|d| d.format("%a %d %b").to_string())
        .collect();

    let is_manager = config.profile == ExportProfile::ManagerReport;

    let title = format!(
        "{} — Week of {}",
        if is_manager {
            "Manager Report"
        } else {
            "Staff Schedule"
        },
        week_start.format("%Y-%m-%d"),
    );

    match config.layout {
        ExportLayout::EmployeeByWeekday => {
            build_employee_grid(&resolved, &dates, &column_headers, &config.cell_content, is_manager, title)
        }
        ExportLayout::ShiftByWeekday => {
            build_shift_grid(&resolved, shifts, &dates, &column_headers, &config.cell_content, is_manager, title, &tmpl_map)
        }
    }
}

fn build_employee_grid(
    resolved: &[ResolvedAssignment],
    dates: &[NaiveDate],
    column_headers: &[String],
    flags: &CellContentFlags,
    is_manager: bool,
    title: String,
) -> ExportGrid {
    // Collect unique employee names, sorted.
    let mut employee_names: Vec<String> = resolved
        .iter()
        .map(|r| r.employee_name.clone())
        .collect();
    employee_names.sort();
    employee_names.dedup();

    let mut cells: Vec<Vec<String>> = Vec::with_capacity(employee_names.len());
    let mut daily_hours = vec![0.0_f32; 7];
    let mut daily_cost = vec![0.0_f32; 7];

    for name in &employee_names {
        let mut row = Vec::with_capacity(7);
        for (col, date) in dates.iter().enumerate() {
            let day_assignments: Vec<&ResolvedAssignment> = resolved
                .iter()
                .filter(|r| r.employee_name == *name && r.shift.date == *date)
                .collect();

            if day_assignments.is_empty() {
                row.push(String::new());
            } else {
                let cell_parts: Vec<String> = day_assignments
                    .iter()
                    .map(|r| {
                        let mut parts = Vec::new();
                        if flags.show_shift_name {
                            parts.push(r.shift_name.clone());
                        }
                        if flags.show_times {
                            parts.push(format!(
                                "{}-{}",
                                r.shift.start_time.format("%H:%M"),
                                r.shift.end_time.format("%H:%M"),
                            ));
                        }
                        if flags.show_role {
                            parts.push(r.shift.required_role.clone());
                        }
                        let mut text = parts.join(" ");
                        if is_manager {
                            if let Some(wage) = r.hourly_wage {
                                let cost = wage * r.shift.duration_hours();
                                text.push_str(&format!(" (${cost:.2})"));
                            }
                        }
                        if is_manager {
                            daily_hours[col] += r.shift.duration_hours();
                            if let Some(wage) = r.hourly_wage {
                                daily_cost[col] += wage * r.shift.duration_hours();
                            }
                        }
                        text
                    })
                    .collect();
                row.push(cell_parts.join("\n"));
            }
        }
        cells.push(row);
    }

    let (daily_totals, weekly_total_cost) = if is_manager {
        let totals: Vec<DaySummary> = daily_hours
            .iter()
            .zip(daily_cost.iter())
            .map(|(&h, &c)| DaySummary {
                total_hours: h,
                total_cost: c,
            })
            .collect();
        let weekly = daily_cost.iter().sum();
        (Some(totals), Some(weekly))
    } else {
        (None, None)
    };

    ExportGrid {
        title,
        column_headers: column_headers.to_vec(),
        row_headers: employee_names,
        cells,
        daily_totals,
        weekly_total_cost,
    }
}

fn build_shift_grid(
    resolved: &[ResolvedAssignment],
    all_shifts: &[Shift],
    dates: &[NaiveDate],
    column_headers: &[String],
    flags: &CellContentFlags,
    is_manager: bool,
    title: String,
    tmpl_map: &HashMap<i64, &ShiftTemplate>,
) -> ExportGrid {
    // A "shift slot" is identified by (start_time, end_time, required_role).
    // We derive a label and collect unique slots sorted by start_time.
    #[derive(Clone, PartialEq, Eq, Hash)]
    struct SlotKey {
        start: String,
        end: String,
        role: String,
    }

    let mut slot_order: Vec<SlotKey> = Vec::new();
    let mut slot_labels: HashMap<SlotKey, String> = HashMap::new();

    // Build slot keys from all shifts (not just assigned ones) so unfilled slots appear.
    let mut shift_slots: Vec<(&Shift, SlotKey)> = all_shifts
        .iter()
        .map(|s| {
            let key = SlotKey {
                start: s.start_time.format("%H:%M").to_string(),
                end: s.end_time.format("%H:%M").to_string(),
                role: s.required_role.clone(),
            };
            (s, key)
        })
        .collect();
    shift_slots.sort_by(|a, b| a.0.start_time.cmp(&b.0.start_time));

    for (shift, key) in &shift_slots {
        if !slot_order.contains(key) {
            let label = shift
                .template_id
                .and_then(|tid| tmpl_map.get(&tid))
                .map(|t| t.name.clone())
                .unwrap_or_else(|| {
                    format!("{} {}-{}", key.role, key.start, key.end)
                });
            slot_labels.insert(key.clone(), label);
            slot_order.push(key.clone());
        }
    }

    let row_headers: Vec<String> = slot_order
        .iter()
        .map(|k| slot_labels.get(k).cloned().unwrap_or_default())
        .collect();

    let mut cells: Vec<Vec<String>> = Vec::with_capacity(slot_order.len());
    let mut daily_hours = vec![0.0_f32; 7];
    let mut daily_cost = vec![0.0_f32; 7];

    for slot_key in &slot_order {
        let mut row = Vec::with_capacity(7);
        for (col, date) in dates.iter().enumerate() {
            // Find assignments for this shift slot on this date.
            let matching: Vec<&ResolvedAssignment> = resolved
                .iter()
                .filter(|r| {
                    r.shift.date == *date
                        && r.shift.start_time.format("%H:%M").to_string() == slot_key.start
                        && r.shift.end_time.format("%H:%M").to_string() == slot_key.end
                        && r.shift.required_role == slot_key.role
                })
                .collect();

            if matching.is_empty() {
                // Check if a shift exists but is unfilled.
                let has_shift = all_shifts.iter().any(|s| {
                    s.date == *date
                        && s.start_time.format("%H:%M").to_string() == slot_key.start
                        && s.end_time.format("%H:%M").to_string() == slot_key.end
                        && s.required_role == slot_key.role
                });
                row.push(if has_shift {
                    "(unfilled)".to_string()
                } else {
                    String::new()
                });
            } else {
                let cell_parts: Vec<String> = matching
                    .iter()
                    .map(|r| {
                        let mut text = r.employee_name.clone();
                        // In shift layout, cell content flags control additional info.
                        let mut extras = Vec::new();
                        if flags.show_times {
                            extras.push(format!(
                                "{}-{}",
                                r.shift.start_time.format("%H:%M"),
                                r.shift.end_time.format("%H:%M"),
                            ));
                        }
                        if flags.show_role {
                            extras.push(r.shift.required_role.clone());
                        }
                        if !extras.is_empty() {
                            text.push_str(&format!(" ({})", extras.join(", ")));
                        }
                        if is_manager {
                            if let Some(wage) = r.hourly_wage {
                                let cost = wage * r.shift.duration_hours();
                                text.push_str(&format!(" ${cost:.2}"));
                            }
                        }
                        if is_manager {
                            daily_hours[col] += r.shift.duration_hours();
                            if let Some(wage) = r.hourly_wage {
                                daily_cost[col] += wage * r.shift.duration_hours();
                            }
                        }
                        text
                    })
                    .collect();
                row.push(cell_parts.join("\n"));
            }
        }
        cells.push(row);
    }

    let (daily_totals, weekly_total_cost) = if is_manager {
        let totals: Vec<DaySummary> = daily_hours
            .iter()
            .zip(daily_cost.iter())
            .map(|(&h, &c)| DaySummary {
                total_hours: h,
                total_cost: c,
            })
            .collect();
        let weekly = daily_cost.iter().sum();
        (Some(totals), Some(weekly))
    } else {
        (None, None)
    };

    ExportGrid {
        title,
        column_headers: column_headers.to_vec(),
        row_headers,
        cells,
        daily_totals,
        weekly_total_cost,
    }
}

#[cfg(test)]
mod tests {
    use chrono::NaiveTime;

    use crate::models::assignment::AssignmentStatus;

    use super::*;

    fn week_start() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 3, 23).unwrap() // Monday
    }

    fn make_shift(id: i64, template_id: Option<i64>, date: NaiveDate, start: (u32, u32), end: (u32, u32), role: &str) -> Shift {
        Shift {
            id,
            template_id,
            rota_id: 1,
            date,
            start_time: NaiveTime::from_hms_opt(start.0, start.1, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(end.0, end.1, 0).unwrap(),
            required_role: role.to_string(),
            min_employees: 1,
            max_employees: 2,
        }
    }

    fn make_template(id: i64, name: &str, start: (u32, u32), end: (u32, u32), role: &str) -> ShiftTemplate {
        ShiftTemplate {
            id,
            name: name.to_string(),
            weekdays: vec![Weekday::Mon, Weekday::Tue],
            start_time: NaiveTime::from_hms_opt(start.0, start.1, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(end.0, end.1, 0).unwrap(),
            required_role: role.to_string(),
            min_employees: 1,
            max_employees: 2,
            deleted: false,
        }
    }

    fn make_employee(id: i64, first: &str, last: &str) -> Employee {
        use crate::models::availability::Availability;
        Employee {
            id,
            first_name: first.to_string(),
            last_name: last.to_string(),
            nickname: None,
            roles: vec!["Barista".to_string()],
            start_date: week_start(),
            target_weekly_hours: 40.0,
            weekly_hours_deviation: 5.0,
            max_daily_hours: 8.0,
            notes: None,
            bank_details: None,
            hourly_wage: Some(15.0),
            wage_currency: Some("usd".to_string()),
            default_availability: Availability::default(),
            availability: Availability::default(),
            deleted: false,
        }
    }

    fn make_assignment(id: i64, shift_id: i64, employee_id: i64, wage: Option<f32>) -> Assignment {
        Assignment {
            id,
            rota_id: 1,
            shift_id,
            employee_id,
            status: AssignmentStatus::Confirmed,
            employee_name: None,
            hourly_wage: wage,
        }
    }

    fn staff_config(layout: ExportLayout) -> ExportConfig {
        ExportConfig {
            layout,
            format: super::super::config::ExportFormat::Csv,
            profile: ExportProfile::StaffSchedule,
            cell_content: CellContentFlags {
                show_shift_name: true,
                show_times: true,
                show_role: false,
            },
        }
    }

    fn manager_config(layout: ExportLayout) -> ExportConfig {
        ExportConfig {
            layout,
            format: super::super::config::ExportFormat::Csv,
            profile: ExportProfile::ManagerReport,
            cell_content: CellContentFlags {
                show_shift_name: true,
                show_times: true,
                show_role: false,
            },
        }
    }

    #[test]
    fn employee_grid_basic() {
        let ws = week_start();
        let mon = ws; // Monday
        let tue = ws + chrono::Duration::days(1);

        let templates = vec![make_template(1, "Morning", (7, 0), (12, 0), "Barista")];
        let shifts = vec![
            make_shift(1, Some(1), mon, (7, 0), (12, 0), "Barista"),
            make_shift(2, Some(1), tue, (7, 0), (12, 0), "Barista"),
        ];
        let employees = vec![
            make_employee(1, "Alice", "Smith"),
            make_employee(2, "Bob", "Jones"),
        ];
        let assignments = vec![
            make_assignment(1, 1, 1, Some(15.0)),
            make_assignment(2, 2, 2, Some(12.0)),
        ];

        let config = staff_config(ExportLayout::EmployeeByWeekday);
        let grid = build_grid(&config, ws, &assignments, &shifts, &employees, &templates);

        assert_eq!(grid.row_headers, vec!["Alice Smith", "Bob Jones"]);
        assert_eq!(grid.column_headers.len(), 7);
        // Alice works Monday, Bob works Tuesday.
        assert!(grid.cells[0][0].contains("Morning"));
        assert!(grid.cells[0][0].contains("07:00-12:00"));
        assert!(grid.cells[0][1].is_empty()); // Alice not on Tuesday
        assert!(grid.cells[1][0].is_empty()); // Bob not on Monday
        assert!(grid.cells[1][1].contains("Morning"));
        assert!(grid.daily_totals.is_none());
    }

    #[test]
    fn employee_grid_manager_report() {
        let ws = week_start();
        let mon = ws;

        let templates = vec![make_template(1, "Morning", (7, 0), (12, 0), "Barista")];
        let shifts = vec![make_shift(1, Some(1), mon, (7, 0), (12, 0), "Barista")];
        let employees = vec![make_employee(1, "Alice", "Smith")];
        let assignments = vec![make_assignment(1, 1, 1, Some(15.0))];

        let config = manager_config(ExportLayout::EmployeeByWeekday);
        let grid = build_grid(&config, ws, &assignments, &shifts, &employees, &templates);

        // Should include cost: 15 * 5 hours = $75.00
        assert!(grid.cells[0][0].contains("$75.00"));
        assert!(grid.daily_totals.is_some());
        let totals = grid.daily_totals.unwrap();
        assert_eq!(totals[0].total_hours, 5.0);
        assert_eq!(totals[0].total_cost, 75.0);
        assert_eq!(grid.weekly_total_cost, Some(75.0));
    }

    #[test]
    fn shift_grid_basic() {
        let ws = week_start();
        let mon = ws;

        let templates = vec![make_template(1, "Morning", (7, 0), (12, 0), "Barista")];
        let shifts = vec![make_shift(1, Some(1), mon, (7, 0), (12, 0), "Barista")];
        let employees = vec![make_employee(1, "Alice", "Smith")];
        let assignments = vec![make_assignment(1, 1, 1, Some(15.0))];

        let config = staff_config(ExportLayout::ShiftByWeekday);
        let grid = build_grid(&config, ws, &assignments, &shifts, &employees, &templates);

        assert_eq!(grid.row_headers, vec!["Morning"]);
        // Monday cell should have Alice.
        assert!(grid.cells[0][0].contains("Alice Smith"));
        // Tuesday onwards should be empty (no shift exists for those days).
        for col in 1..7 {
            assert_eq!(grid.cells[0][col], "");
        }
    }

    #[test]
    fn shift_grid_unfilled() {
        let ws = week_start();
        let mon = ws;

        let templates = vec![make_template(1, "Morning", (7, 0), (12, 0), "Barista")];
        let shifts = vec![make_shift(1, Some(1), mon, (7, 0), (12, 0), "Barista")];
        let employees = vec![make_employee(1, "Alice", "Smith")];
        let assignments: Vec<Assignment> = vec![]; // No assignments

        let config = staff_config(ExportLayout::ShiftByWeekday);
        let grid = build_grid(&config, ws, &assignments, &shifts, &employees, &templates);

        assert_eq!(grid.cells[0][0], "(unfilled)");
    }

    #[test]
    fn multiple_employees_same_shift() {
        let ws = week_start();
        let mon = ws;

        let templates = vec![make_template(1, "Morning", (7, 0), (12, 0), "Barista")];
        let shifts = vec![make_shift(1, Some(1), mon, (7, 0), (12, 0), "Barista")];
        let employees = vec![
            make_employee(1, "Alice", "Smith"),
            make_employee(2, "Bob", "Jones"),
        ];
        let assignments = vec![
            make_assignment(1, 1, 1, Some(15.0)),
            make_assignment(2, 1, 2, Some(12.0)),
        ];

        let config = staff_config(ExportLayout::ShiftByWeekday);
        let grid = build_grid(&config, ws, &assignments, &shifts, &employees, &templates);

        // Both should appear in the same cell.
        let cell = &grid.cells[0][0];
        assert!(cell.contains("Alice Smith"));
        assert!(cell.contains("Bob Jones"));
        assert!(cell.contains('\n'));
    }

    #[test]
    fn ad_hoc_shift_fallback_name() {
        let ws = week_start();
        let mon = ws;

        let templates: Vec<ShiftTemplate> = vec![];
        let shifts = vec![make_shift(1, None, mon, (14, 0), (18, 0), "Server")];
        let employees = vec![make_employee(1, "Alice", "Smith")];
        let assignments = vec![make_assignment(1, 1, 1, None)];

        let config = staff_config(ExportLayout::EmployeeByWeekday);
        let grid = build_grid(&config, ws, &assignments, &shifts, &employees, &templates);

        // Shift name should fall back to "Server 14:00-18:00" pattern.
        assert!(grid.cells[0][0].contains("Server 14:00-18:00"));
    }

    #[test]
    fn cell_content_flags() {
        let ws = week_start();
        let mon = ws;

        let templates = vec![make_template(1, "Morning", (7, 0), (12, 0), "Barista")];
        let shifts = vec![make_shift(1, Some(1), mon, (7, 0), (12, 0), "Barista")];
        let employees = vec![make_employee(1, "Alice", "Smith")];
        let assignments = vec![make_assignment(1, 1, 1, None)];

        // Only show shift name.
        let config = ExportConfig {
            layout: ExportLayout::EmployeeByWeekday,
            format: super::super::config::ExportFormat::Csv,
            profile: ExportProfile::StaffSchedule,
            cell_content: CellContentFlags {
                show_shift_name: true,
                show_times: false,
                show_role: false,
            },
        };
        let grid = build_grid(&config, ws, &assignments, &shifts, &employees, &templates);
        assert_eq!(grid.cells[0][0], "Morning");

        // Show everything.
        let config = ExportConfig {
            layout: ExportLayout::EmployeeByWeekday,
            format: super::super::config::ExportFormat::Csv,
            profile: ExportProfile::StaffSchedule,
            cell_content: CellContentFlags {
                show_shift_name: true,
                show_times: true,
                show_role: true,
            },
        };
        let grid = build_grid(&config, ws, &assignments, &shifts, &employees, &templates);
        assert!(grid.cells[0][0].contains("Morning"));
        assert!(grid.cells[0][0].contains("07:00-12:00"));
        assert!(grid.cells[0][0].contains("Barista"));
    }
}
