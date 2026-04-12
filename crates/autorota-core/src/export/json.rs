use chrono::NaiveDate;
use serde::Serialize;

use super::config::ExportConfig;
use super::grid::ExportGrid;

#[derive(Serialize)]
struct JsonExport {
    metadata: Metadata,
    columns: Vec<String>,
    rows: Vec<JsonRow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    totals: Option<Totals>,
}

#[derive(Serialize)]
struct Metadata {
    week_start: String,
    layout: String,
    profile: String,
    generated_at: String,
}

#[derive(Serialize)]
struct JsonRow {
    header: String,
    cells: Vec<String>,
}

#[derive(Serialize)]
struct Totals {
    daily: Vec<DayTotal>,
    weekly_cost: f32,
}

#[derive(Serialize)]
struct DayTotal {
    hours: f32,
    cost: f32,
}

/// Render an `ExportGrid` as a structured JSON string.
pub fn render_json(grid: &ExportGrid, config: &ExportConfig, week_start: NaiveDate) -> String {
    let rows = grid
        .row_headers
        .iter()
        .zip(grid.cells.iter())
        .map(|(header, cells)| JsonRow {
            header: header.clone(),
            cells: cells.clone(),
        })
        .collect();

    let totals = grid.daily_totals.as_ref().map(|dt| {
        let daily = dt
            .iter()
            .map(|d| DayTotal {
                hours: d.total_hours,
                cost: d.total_cost,
            })
            .collect();
        Totals {
            daily,
            weekly_cost: grid.weekly_total_cost.unwrap_or(0.0),
        }
    });

    let now = chrono::Local::now();

    let export = JsonExport {
        metadata: Metadata {
            week_start: week_start.format("%Y-%m-%d").to_string(),
            layout: config.layout.to_string(),
            profile: config.profile.to_string(),
            generated_at: now.format("%Y-%m-%dT%H:%M:%S").to_string(),
        },
        columns: grid.column_headers.clone(),
        rows,
        totals,
    };

    serde_json::to_string_pretty(&export).expect("JSON serialization should not fail")
}

// ─── Employee schedule JSON ─────────────────────────────────

#[derive(Serialize)]
struct EmployeeJsonExport {
    metadata: EmployeeMetadata,
    columns: Vec<String>,
    rows: Vec<JsonRow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    total_cost: Option<f32>,
}

#[derive(Serialize)]
struct EmployeeMetadata {
    employee_name: String,
    start_date: String,
    end_date: String,
    profile: String,
    generated_at: String,
}

/// Render a single-employee `ExportGrid` as JSON with employee-specific metadata.
pub fn render_employee_json(
    grid: &ExportGrid,
    employee_name: &str,
    start_date: chrono::NaiveDate,
    end_date: chrono::NaiveDate,
    profile: &super::config::ExportProfile,
) -> String {
    let rows = grid
        .row_headers
        .iter()
        .zip(grid.cells.iter())
        .map(|(header, cells)| JsonRow {
            header: header.clone(),
            cells: cells.clone(),
        })
        .collect();

    let now = chrono::Local::now();

    let export = EmployeeJsonExport {
        metadata: EmployeeMetadata {
            employee_name: employee_name.to_string(),
            start_date: start_date.format("%Y-%m-%d").to_string(),
            end_date: end_date.format("%Y-%m-%d").to_string(),
            profile: profile.to_string(),
            generated_at: now.format("%Y-%m-%dT%H:%M:%S").to_string(),
        },
        columns: grid.column_headers.clone(),
        rows,
        total_cost: grid.weekly_total_cost,
    };

    serde_json::to_string_pretty(&export).expect("JSON serialization should not fail")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::config::*;
    use crate::export::grid::DaySummary;
    use crate::testutil::ExportConfigBuilder;

    fn test_config() -> ExportConfig {
        ExportConfigBuilder::staff()
            .format(ExportFormat::Json)
            .build()
    }

    #[test]
    fn json_structure() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon 23 Mar".to_string()],
            row_headers: vec!["Alice".to_string()],
            cells: vec![vec!["Morning 07:00-12:00".to_string()]],
            daily_totals: None,
            weekly_total_cost: None,
        };

        let ws = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
        let json_str = render_json(&grid, &test_config(), ws);
        let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        assert_eq!(parsed["metadata"]["week_start"], "2026-03-23");
        assert_eq!(parsed["metadata"]["layout"], "employee_by_weekday");
        assert_eq!(parsed["metadata"]["profile"], "staff_schedule");
        assert_eq!(parsed["columns"][0], "Mon 23 Mar");
        assert_eq!(parsed["rows"][0]["header"], "Alice");
        assert_eq!(parsed["rows"][0]["cells"][0], "Morning 07:00-12:00");
        assert!(parsed["totals"].is_null());
    }

    #[test]
    fn json_with_totals() {
        let config = ExportConfigBuilder::manager()
            .layout(ExportLayout::ShiftByWeekday)
            .format(ExportFormat::Json)
            .hide_times()
            .build();

        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon".to_string()],
            row_headers: vec!["Morning".to_string()],
            cells: vec![vec!["Alice $75.00".to_string()]],
            daily_totals: Some(vec![DaySummary {
                total_hours: 5.0,
                total_cost: 75.0,
            }]),
            weekly_total_cost: Some(75.0),
        };

        let ws = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
        let json_str = render_json(&grid, &config, ws);
        let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();

        assert_eq!(parsed["totals"]["daily"][0]["hours"], 5.0);
        assert_eq!(parsed["totals"]["daily"][0]["cost"], 75.0);
        assert_eq!(parsed["totals"]["weekly_cost"], 75.0);
    }

    #[test]
    fn json_roundtrip_valid() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon".to_string(), "Tue".to_string()],
            row_headers: vec!["Alice".to_string(), "Bob".to_string()],
            cells: vec![
                vec!["Morning".to_string(), String::new()],
                vec![String::new(), "Afternoon".to_string()],
            ],
            daily_totals: None,
            weekly_total_cost: None,
        };

        let ws = NaiveDate::from_ymd_opt(2026, 3, 23).unwrap();
        let json_str = render_json(&grid, &test_config(), ws);

        // Should be valid JSON.
        let result: Result<serde_json::Value, _> = serde_json::from_str(&json_str);
        assert!(result.is_ok());
    }
}
