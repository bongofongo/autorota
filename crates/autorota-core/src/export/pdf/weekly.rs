//! Weekly Grid template: title + one `ExportGrid` rendered as a table.

use chrono::NaiveDate;

use crate::export::grid::ExportGrid;

use super::theme::PdfBuilder;

pub fn render(grid: &ExportGrid, week_start: NaiveDate) -> Result<Vec<u8>, String> {
    let mut builder = PdfBuilder::new(&grid.title)?;
    builder.draw_title(&format!(
        "{} — Week of {}",
        grid.title,
        week_start.format("%Y-%m-%d")
    ));
    builder.draw_grid_table(grid);

    if let Some(total) = grid.weekly_total_cost {
        builder.draw_body_line(&format!("Weekly total cost: ${total:.2}"));
    }

    builder.finish()
}
