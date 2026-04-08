//! By-Role template: one grid per role, stacked in a single PDF.
//!
//! Tables flow continuously, but a role's grid is never broken mid-table: if
//! it cannot fit in the remaining vertical space it is pushed to the next
//! page. A conservative height estimate is used for the keep-together check.

use chrono::NaiveDate;

use crate::export::grid::ExportGrid;

use super::theme::PdfBuilder;

/// Minimum "useful" vertical space to start a new role section without
/// forcing a page break. Chosen so a role with a header + 2 data rows fits.
const MIN_SECTION_SPACE_MM: f64 = 40.0;

pub fn render(sections: &[(String, ExportGrid)], week_start: NaiveDate) -> Result<Vec<u8>, String> {
    let mut builder = PdfBuilder::new("Schedule by Role")?;
    builder.draw_title(&format!(
        "Schedule by Role — Week of {}",
        week_start.format("%Y-%m-%d")
    ));

    if sections.is_empty() {
        builder.draw_body_line("(no shifts this week)");
        return builder.finish();
    }

    for (role, grid) in sections {
        // Estimate total height for this role's table (header row + data rows
        // @ 7mm minimum each + subtitle). If that's greater than remaining and
        // the needed minimum, force a page break first so the table starts on
        // a fresh page and ideally fits in one piece.
        let estimated = 10.0 + (grid.cells.len() as f64 + 1.0) * 7.0;
        let needed = estimated.min(MIN_SECTION_SPACE_MM.max(40.0));
        if builder.remaining_height() < needed {
            builder.new_page();
        }
        builder.draw_subtitle(role);
        builder.draw_grid_table(grid);
    }

    builder.finish()
}
