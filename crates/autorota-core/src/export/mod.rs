pub mod config;
pub mod csv;
pub mod grid;
pub mod json;
pub mod pdf;

use base64::Engine;
use chrono::NaiveDate;
use sqlx::SqlitePool;

use crate::db::queries;
use config::{ExportConfig, ExportFormat, ExportResult, PdfTemplate};

/// Errors that can occur during export.
#[derive(Debug, thiserror::Error)]
pub enum ExportError {
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("no schedule found for week {0}")]
    NoSchedule(String),
    #[error("pdf render error: {0}")]
    Pdf(String),
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

    match config.format {
        ExportFormat::Csv | ExportFormat::Json => {
            let export_grid = grid::build_grid(
                &config,
                week_start,
                &rota.assignments,
                &shifts,
                &employees,
                &templates,
            );

            let data = match config.format {
                ExportFormat::Csv => csv::render_csv(&export_grid),
                ExportFormat::Json => json::render_json(&export_grid, &config, week_start),
                ExportFormat::Pdf => unreachable!(),
            };
            let (ext, mime) = match config.format {
                ExportFormat::Csv => ("csv", "text/csv"),
                ExportFormat::Json => ("json", "application/json"),
                ExportFormat::Pdf => unreachable!(),
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
        ExportFormat::Pdf => {
            let template = config.pdf_template.unwrap_or(PdfTemplate::WeeklyGrid);
            let bytes = match template {
                PdfTemplate::WeeklyGrid => {
                    let export_grid = grid::build_grid(
                        &config,
                        week_start,
                        &rota.assignments,
                        &shifts,
                        &employees,
                        &templates,
                    );
                    pdf::weekly::render(&export_grid, week_start).map_err(ExportError::Pdf)?
                }
                PdfTemplate::PerEmployee => {
                    // Force an employee-by-weekday grid regardless of the
                    // caller's layout setting — the per-employee template
                    // consumes that shape.
                    let mut cfg = config.clone();
                    cfg.layout = config::ExportLayout::EmployeeByWeekday;
                    let export_grid = grid::build_grid(
                        &cfg,
                        week_start,
                        &rota.assignments,
                        &shifts,
                        &employees,
                        &templates,
                    );
                    pdf::employee::render(&export_grid, week_start).map_err(ExportError::Pdf)?
                }
                PdfTemplate::ByRole => {
                    // Force shift-by-weekday for each role's sub-grid so the
                    // resulting tables read as "which shifts, which days,
                    // who's working them".
                    let mut cfg = config.clone();
                    cfg.layout = config::ExportLayout::ShiftByWeekday;
                    let sections = grid::build_grids_by_role(
                        &cfg,
                        week_start,
                        &rota.assignments,
                        &shifts,
                        &employees,
                        &templates,
                    );
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
