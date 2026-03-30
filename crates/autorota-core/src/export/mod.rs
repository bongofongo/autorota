pub mod config;
pub mod csv;
pub mod grid;
pub mod json;

use chrono::NaiveDate;
use sqlx::SqlitePool;

use crate::db::queries;
use config::{ExportConfig, ExportFormat, ExportResult};

/// Errors that can occur during export.
#[derive(Debug, thiserror::Error)]
pub enum ExportError {
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("no schedule found for week {0}")]
    NoSchedule(String),
}

/// Export a week's schedule as CSV or JSON.
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

    let export_grid = grid::build_grid(&config, week_start, &rota.assignments, &shifts, &employees, &templates);

    let data = match config.format {
        ExportFormat::Csv => csv::render_csv(&export_grid),
        ExportFormat::Json => json::render_json(&export_grid, &config, week_start),
    };

    let ext = match config.format {
        ExportFormat::Csv => "csv",
        ExportFormat::Json => "json",
    };
    let mime = match config.format {
        ExportFormat::Csv => "text/csv",
        ExportFormat::Json => "application/json",
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
