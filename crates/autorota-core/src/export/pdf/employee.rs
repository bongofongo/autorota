//! Per-Employee template: one section per employee listing their week.
//!
//! Consumes the `EmployeeByWeekday` `ExportGrid` — each row of the grid is
//! one employee, and the seven cells are that employee's shifts for each day.
//! Sections flow continuously; page breaks happen automatically inside the
//! body-line helper.

use chrono::NaiveDate;

use crate::export::grid::ExportGrid;

use super::theme::PdfBuilder;

pub fn render(grid: &ExportGrid, week_start: NaiveDate) -> Result<Vec<u8>, String> {
    let mut builder = PdfBuilder::new("Per-Employee Schedule")?;
    builder.draw_title(&format!(
        "Per-Employee Schedule — Week of {}",
        week_start.format("%Y-%m-%d")
    ));

    if grid.row_headers.is_empty() {
        builder.draw_body_line("(no shifts this week)");
        return builder.finish();
    }

    for (row_idx, employee) in grid.row_headers.iter().enumerate() {
        builder.draw_subtitle(employee);
        let row = &grid.cells[row_idx];
        let mut any = false;
        for (col_idx, cell) in row.iter().enumerate() {
            if cell.is_empty() {
                continue;
            }
            any = true;
            let day_label = grid
                .column_headers
                .get(col_idx)
                .cloned()
                .unwrap_or_default();
            // Flatten any newlines within a cell to "; " so one day = one line.
            let flattened = cell.replace('\n', "; ");
            builder.draw_body_line(&format!("{day_label}: {flattened}"));
        }
        if !any {
            builder.draw_body_line("(no shifts this week)");
        }
    }

    builder.finish()
}
