pub mod config;
pub mod csv;
pub mod grid;
pub mod ics;
pub mod json;
pub mod markdown;
pub mod pdf;
pub mod preview;
pub mod xlsx;

use base64::Engine;
use chrono::NaiveDate;
use sqlx::SqlitePool;

use crate::db::queries;
use crate::models::{
    assignment::Assignment,
    employee::Employee,
    shift::{Shift, ShiftTemplate},
};
use config::{EmployeeExportConfig, ExportConfig, ExportFormat, ExportResult, PdfTemplate};

/// Errors that can occur during export.
#[derive(Debug, thiserror::Error)]
pub enum ExportError {
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("no schedule found for week {0}")]
    NoSchedule(String),
    #[error("employee not found: {0}")]
    EmployeeNotFound(i64),
    #[error("pdf render error: {0}")]
    Pdf(String),
    #[error("export grid too large: {rows} rows × {cols} cols ({total} cells exceeds {limit})")]
    TooLarge {
        rows: usize,
        cols: usize,
        total: usize,
        limit: usize,
    },
}

/// Cap on the total number of cells in an export grid (rows × columns).
/// Empirically, an `ExportGrid` of 1M cells is ~tens of MB depending on cell
/// content, which is the upper bound we'll hand to PDF/CSV/JSON renderers
/// before they'll start hitting OOM on phones / older laptops.
pub(crate) const EXPORT_GRID_CELL_LIMIT: usize = 1_000_000;

/// Bound-check an `ExportGrid` before handing it to a renderer. Cheap; runs
/// after `build_grid` has already allocated, so this is a safety net rather
/// than an OOM preventer — but it stops downstream PDF/XLSX renderers from
/// melting on degenerate inputs.
pub(crate) fn check_grid_bounds(grid: &grid::ExportGrid) -> Result<(), ExportError> {
    let rows = grid.row_headers.len();
    let cols = grid.column_headers.len();
    let total = rows.saturating_mul(cols);
    if total > EXPORT_GRID_CELL_LIMIT {
        return Err(ExportError::TooLarge {
            rows,
            cols,
            total,
            limit: EXPORT_GRID_CELL_LIMIT,
        });
    }
    Ok(())
}

/// Export a week's schedule as CSV, JSON, or PDF.
///
/// PDF bytes are base64-encoded into `ExportResult.data` so the existing
/// `String`-typed FFI contract keeps working; frontends decode before writing
/// to disk. See `docs/superpowers/specs/2026-04-08-pdf-export-design.md`.
pub async fn export_week_schedule(
    pool: &SqlitePool,
    week_start: NaiveDate,
    config: ExportConfig,
) -> Result<ExportResult, ExportError> {
    let rota = queries::get_rota_by_week(pool, week_start)
        .await?
        .ok_or_else(|| ExportError::NoSchedule(week_start.to_string()))?;

    let shifts = queries::list_shifts_for_rota(pool, rota.id).await?;
    let employees = queries::list_all_employees(pool).await?;
    let templates = queries::list_all_shift_templates(pool).await?;

    render_week_export(
        week_start,
        &rota.assignments,
        &shifts,
        &employees,
        &templates,
        &config,
    )
}

/// Pure-render version of week-schedule export. Takes already-loaded data
/// so the same renderer path can serve live exports (DB-backed) and previews
/// (synthetic fixture).
pub(crate) fn render_week_export(
    week_start: NaiveDate,
    assignments: &[Assignment],
    shifts: &[Shift],
    employees: &[Employee],
    templates: &[ShiftTemplate],
    config: &ExportConfig,
) -> Result<ExportResult, ExportError> {
    match config.format {
        ExportFormat::Ics => Err(ExportError::Pdf(
            "ICS export is not supported at the rota level; export per-employee instead"
                .to_string(),
        )),
        ExportFormat::Csv | ExportFormat::Json | ExportFormat::Markdown => {
            let export_grid = grid::build_grid(
                config,
                week_start,
                assignments,
                shifts,
                employees,
                templates,
            );
            check_grid_bounds(&export_grid)?;

            let data = match config.format {
                ExportFormat::Csv => csv::render_csv(&export_grid),
                ExportFormat::Json => json::render_json(&export_grid, config, week_start),
                ExportFormat::Markdown => markdown::render_markdown(&export_grid),
                _ => unreachable!(),
            };
            let (ext, mime) = match config.format {
                ExportFormat::Csv => ("csv", "text/csv"),
                ExportFormat::Json => ("json", "application/json"),
                ExportFormat::Markdown => ("md", "text/markdown"),
                _ => unreachable!(),
            };
            let filename = format!(
                "rota-{}-{}-{}.{ext}",
                week_start.format("%Y-%m-%d"),
                config.layout,
                config.profile,
            );
            Ok(ExportResult {
                data,
                filename,
                mime_type: mime.to_string(),
            })
        }
        ExportFormat::Xlsx => {
            let main_grid = grid::build_grid(
                config,
                week_start,
                assignments,
                shifts,
                employees,
                templates,
            );
            check_grid_bounds(&main_grid)?;
            let mut by_role_cfg = config.clone();
            by_role_cfg.layout = config::ExportLayout::ShiftByWeekday;
            let role_sections = grid::build_grids_by_role(
                &by_role_cfg,
                week_start,
                assignments,
                shifts,
                employees,
                templates,
            );
            for (_, g) in role_sections.iter() {
                check_grid_bounds(g)?;
            }

            let mut sheets: Vec<(String, &grid::ExportGrid)> =
                vec![("Schedule".to_string(), &main_grid)];
            for (role, g) in role_sections.iter() {
                sheets.push((format!("By Role: {role}"), g));
            }

            let bytes = xlsx::render_workbook(&sheets).map_err(ExportError::Pdf)?;
            let filename = format!(
                "rota-{}-{}-{}.xlsx",
                week_start.format("%Y-%m-%d"),
                config.layout,
                config.profile,
            );
            Ok(ExportResult {
                data: base64::engine::general_purpose::STANDARD.encode(&bytes),
                filename,
                mime_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                    .to_string(),
            })
        }
        ExportFormat::Pdf => {
            let template = config.pdf_template.unwrap_or(PdfTemplate::WeeklyGrid);
            let bytes = match template {
                PdfTemplate::WeeklyGrid => {
                    let export_grid = grid::build_grid(
                        config,
                        week_start,
                        assignments,
                        shifts,
                        employees,
                        templates,
                    );
                    check_grid_bounds(&export_grid)?;
                    pdf::weekly::render(&export_grid, week_start).map_err(ExportError::Pdf)?
                }
                PdfTemplate::PerEmployee => {
                    let mut cfg = config.clone();
                    cfg.layout = config::ExportLayout::EmployeeByWeekday;
                    let export_grid = grid::build_grid(
                        &cfg,
                        week_start,
                        assignments,
                        shifts,
                        employees,
                        templates,
                    );
                    check_grid_bounds(&export_grid)?;
                    pdf::employee::render(&export_grid, week_start).map_err(ExportError::Pdf)?
                }
                PdfTemplate::ByRole => {
                    let mut cfg = config.clone();
                    cfg.layout = config::ExportLayout::ShiftByWeekday;
                    let sections = grid::build_grids_by_role(
                        &cfg,
                        week_start,
                        assignments,
                        shifts,
                        employees,
                        templates,
                    );
                    for (_, g) in sections.iter() {
                        check_grid_bounds(g)?;
                    }
                    pdf::by_role::render(&sections, week_start).map_err(ExportError::Pdf)?
                }
            };

            let filename = format!("rota-{}-{}.pdf", week_start.format("%Y-%m-%d"), template,);
            Ok(ExportResult {
                data: base64::engine::general_purpose::STANDARD.encode(&bytes),
                filename,
                mime_type: "application/pdf".to_string(),
            })
        }
    }
}

/// Export a single employee's schedule over a date range.
pub async fn export_employee_schedule(
    pool: &SqlitePool,
    employee_id: i64,
    start_date: NaiveDate,
    end_date: NaiveDate,
    config: EmployeeExportConfig,
) -> Result<ExportResult, ExportError> {
    let employee = queries::get_employee(pool, employee_id)
        .await?
        .ok_or(ExportError::EmployeeNotFound(employee_id))?;

    let rotas = queries::get_rotas_in_range(pool, start_date, end_date).await?;
    let templates = queries::list_all_shift_templates(pool).await?;

    // Collect all shifts and assignments across rotas, filtering to the employee.
    let mut all_shifts = Vec::new();
    let mut all_assignments = Vec::new();
    for rota in &rotas {
        let shifts = queries::list_shifts_for_rota(pool, rota.id).await?;
        let emp_assignments: Vec<_> = rota
            .assignments
            .iter()
            .filter(|a| a.employee_id == employee_id)
            .cloned()
            .collect();
        all_assignments.extend(emp_assignments);
        all_shifts.extend(shifts);
    }

    render_employee_export(
        &employee.display_name(),
        employee_id,
        start_date,
        end_date,
        &all_assignments,
        &all_shifts,
        &templates,
        &config,
    )
}

/// Pure-render version of employee-schedule export. Assumes `assignments` and
/// `shifts` are already filtered to this employee / range.
pub(crate) fn render_employee_export(
    employee_name: &str,
    employee_id: i64,
    start_date: NaiveDate,
    end_date: NaiveDate,
    assignments: &[Assignment],
    shifts: &[Shift],
    templates: &[ShiftTemplate],
    config: &EmployeeExportConfig,
) -> Result<ExportResult, ExportError> {
    let mut scoped_shifts: Vec<Shift> = shifts
        .iter()
        .filter(|s| s.date >= start_date && s.date <= end_date)
        .cloned()
        .collect();
    // Already filtered upstream for DB path; preview path passes unfiltered.
    scoped_shifts.sort_by_key(|s| (s.date, s.start_time));

    let mut dates = Vec::new();
    let mut d = start_date;
    while d <= end_date {
        dates.push(d);
        d += chrono::Duration::days(1);
    }

    let is_manager = config.profile == config::ExportProfile::ManagerReport;

    let export_grid = grid::build_single_employee_grid(
        employee_name,
        &dates,
        assignments,
        &scoped_shifts,
        templates,
        &config.cell_content,
        is_manager,
    );
    check_grid_bounds(&export_grid)?;

    let slug = employee_name.to_lowercase().replace(' ', "-");

    match config.format {
        ExportFormat::Csv | ExportFormat::Json | ExportFormat::Markdown => {
            let data = match config.format {
                ExportFormat::Csv => csv::render_csv(&export_grid),
                ExportFormat::Json => json::render_employee_json(
                    &export_grid,
                    employee_name,
                    start_date,
                    end_date,
                    &config.profile,
                ),
                ExportFormat::Markdown => {
                    markdown::render_employee_markdown(&export_grid, employee_name)
                }
                _ => unreachable!(),
            };
            let (ext, mime) = match config.format {
                ExportFormat::Csv => ("csv", "text/csv"),
                ExportFormat::Json => ("json", "application/json"),
                ExportFormat::Markdown => ("md", "text/markdown"),
                _ => unreachable!(),
            };
            let filename = format!(
                "schedule-{}-{}-to-{}.{ext}",
                slug,
                start_date.format("%Y-%m-%d"),
                end_date.format("%Y-%m-%d"),
            );
            Ok(ExportResult {
                data,
                filename,
                mime_type: mime.to_string(),
            })
        }
        ExportFormat::Xlsx => {
            let bytes = xlsx::render_workbook(&[("Schedule".to_string(), &export_grid)])
                .map_err(ExportError::Pdf)?;
            let filename = format!(
                "schedule-{}-{}-to-{}.xlsx",
                slug,
                start_date.format("%Y-%m-%d"),
                end_date.format("%Y-%m-%d"),
            );
            Ok(ExportResult {
                data: base64::engine::general_purpose::STANDARD.encode(&bytes),
                filename,
                mime_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                    .to_string(),
            })
        }
        ExportFormat::Ics => {
            let template_by_id: std::collections::HashMap<i64, &str> =
                templates.iter().map(|t| (t.id, t.name.as_str())).collect();

            let mut entries: Vec<(crate::models::shift::Shift, String)> = Vec::new();
            for s in &scoped_shifts {
                let label = s
                    .template_id
                    .and_then(|id| template_by_id.get(&id).copied())
                    .unwrap_or("Shift")
                    .to_string();
                entries.push((s.clone(), label));
            }

            let data = ics::render_employee_calendar(
                employee_id,
                employee_name,
                &entries,
                config.timezone_id.as_deref(),
            );
            let filename = format!(
                "schedule-{}-{}-to-{}.ics",
                slug,
                start_date.format("%Y-%m-%d"),
                end_date.format("%Y-%m-%d"),
            );
            Ok(ExportResult {
                data,
                filename,
                mime_type: "text/calendar".to_string(),
            })
        }
        ExportFormat::Pdf => {
            let bytes = pdf::employee_schedule::render(&export_grid).map_err(ExportError::Pdf)?;
            let filename = format!(
                "schedule-{}-{}-to-{}.pdf",
                slug,
                start_date.format("%Y-%m-%d"),
                end_date.format("%Y-%m-%d"),
            );
            Ok(ExportResult {
                data: base64::engine::general_purpose::STANDARD.encode(&bytes),
                filename,
                mime_type: "application/pdf".to_string(),
            })
        }
    }
}

#[cfg(test)]
mod bounds_tests {
    use super::*;

    #[test]
    fn check_grid_bounds_accepts_normal_grid() {
        let g = grid::ExportGrid {
            title: "T".into(),
            column_headers: vec!["c".into(); 7],
            row_headers: vec!["r".into(); 50],
            cells: vec![vec![String::new(); 7]; 50],
            daily_totals: None,
            weekly_total_cost: None,
        };
        assert!(check_grid_bounds(&g).is_ok());
    }

    #[test]
    fn check_grid_bounds_rejects_oversize_grid() {
        // 1001 × 1001 = 1,002,001 cells — just over the cell limit. Skip
        // allocating the full cell matrix to keep the test cheap;
        // `check_grid_bounds` only inspects header lengths.
        let oversize = grid::ExportGrid {
            title: "T".into(),
            column_headers: vec!["c".into(); 1001],
            row_headers: vec!["r".into(); 1001],
            cells: Vec::new(),
            daily_totals: None,
            weekly_total_cost: None,
        };
        match check_grid_bounds(&oversize) {
            Err(ExportError::TooLarge {
                rows,
                cols,
                total,
                limit,
            }) => {
                assert_eq!(rows, 1001);
                assert_eq!(cols, 1001);
                assert_eq!(total, 1_002_001);
                assert_eq!(limit, EXPORT_GRID_CELL_LIMIT);
            }
            other => panic!("expected TooLarge, got {other:?}"),
        }
    }

}
