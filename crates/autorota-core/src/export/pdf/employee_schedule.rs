//! Single-employee schedule template: a dated list of shifts.
//!
//! Consumes a single-column `ExportGrid` where each row is a date and the
//! cell contains the shift details for that date. Works for both single-week
//! and multi-week date ranges.

use crate::export::grid::ExportGrid;

use super::theme::PdfBuilder;

pub fn render(grid: &ExportGrid) -> Result<Vec<u8>, String> {
    let mut builder = PdfBuilder::new("Employee Schedule")?;
    builder.draw_title(&grid.title);

    if grid.row_headers.is_empty() {
        builder.draw_body_line("(no shifts in this period)");
        return builder.finish();
    }

    for (row_idx, date_label) in grid.row_headers.iter().enumerate() {
        let cell = grid
            .cells
            .get(row_idx)
            .and_then(|r| r.first())
            .map(|s| s.as_str())
            .unwrap_or("");

        if cell.is_empty() {
            continue; // Skip days with no shifts.
        }

        builder.draw_subtitle(date_label);
        // Each shift within the cell is separated by \n.
        for line in cell.split('\n') {
            if !line.is_empty() {
                builder.draw_body_line(line);
            }
        }
    }

    if let Some(cost) = grid.weekly_total_cost {
        builder.draw_subtitle(&format!("Total Cost: ${cost:.2}"));
    }

    builder.finish()
}
