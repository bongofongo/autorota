//! Low-level PDF layout primitives shared by all templates.
//!
//! Wraps a `printpdf` document with a stateful cursor, page management, and
//! a simple table renderer driven by `ExportGrid`. Page size is hard-coded to
//! A4 landscape; fonts are printpdf built-ins so no TTF files are shipped.

use std::io::BufWriter;

use printpdf::indices::{PdfLayerIndex, PdfPageIndex};
use printpdf::{
    BuiltinFont, IndirectFontRef, Line, Mm, PdfDocument, PdfDocumentReference, PdfLayerReference,
    Point,
};

use crate::export::grid::ExportGrid;

/// A4 landscape.
pub const PAGE_WIDTH_MM: f64 = 297.0;
pub const PAGE_HEIGHT_MM: f64 = 210.0;
pub const MARGIN_MM: f64 = 15.0;
pub const USABLE_WIDTH_MM: f64 = PAGE_WIDTH_MM - 2.0 * MARGIN_MM;

const TITLE_SIZE: f64 = 14.0;
const SUBTITLE_SIZE: f64 = 11.0;
const BODY_SIZE: f64 = 9.0;
const TITLE_LEADING: f64 = 7.0;
const SUBTITLE_LEADING: f64 = 6.0;
const BODY_LEADING: f64 = 4.2;
const CELL_PADDING_X: f64 = 1.5;
const CELL_PADDING_Y: f64 = 1.5;
const ROW_MIN_HEIGHT: f64 = 7.0;
/// Rough Helvetica 9pt average glyph width in mm. Used only for truncation.
const AVG_CHAR_WIDTH_MM: f64 = 1.55;
const LABEL_COL_WIDTH_MM: f64 = 40.0;

/// Stateful PDF builder: owns the document, the current page/layer cursor,
/// and both regular + bold built-in font refs.
pub struct PdfBuilder {
    doc: PdfDocumentReference,
    page: PdfPageIndex,
    layer: PdfLayerIndex,
    font: IndirectFontRef,
    bold: IndirectFontRef,
    /// Y position of the next line to draw, in mm from the page bottom.
    cursor_y: f64,
}

impl PdfBuilder {
    pub fn new(title: &str) -> Result<Self, String> {
        let (doc, page, layer) =
            PdfDocument::new(title, Mm(PAGE_WIDTH_MM), Mm(PAGE_HEIGHT_MM), "Layer 1");
        let font = doc
            .add_builtin_font(BuiltinFont::Helvetica)
            .map_err(|e| format!("font load: {e}"))?;
        let bold = doc
            .add_builtin_font(BuiltinFont::HelveticaBold)
            .map_err(|e| format!("font load: {e}"))?;
        Ok(Self {
            doc,
            page,
            layer,
            font,
            bold,
            cursor_y: PAGE_HEIGHT_MM - MARGIN_MM,
        })
    }

    fn layer_ref(&self) -> PdfLayerReference {
        self.doc.get_page(self.page).get_layer(self.layer)
    }

    /// Start a new page and reset the cursor to the top margin.
    pub fn new_page(&mut self) {
        let (p, l) = self
            .doc
            .add_page(Mm(PAGE_WIDTH_MM), Mm(PAGE_HEIGHT_MM), "Layer 1");
        self.page = p;
        self.layer = l;
        self.cursor_y = PAGE_HEIGHT_MM - MARGIN_MM;
    }

    /// Remaining vertical space above the bottom margin.
    pub fn remaining_height(&self) -> f64 {
        self.cursor_y - MARGIN_MM
    }

    /// Ensure at least `needed_mm` of vertical space remains; otherwise break.
    pub fn ensure_space(&mut self, needed_mm: f64) {
        if self.remaining_height() < needed_mm {
            self.new_page();
        }
    }

    pub fn draw_title(&mut self, text: &str) {
        let layer = self.layer_ref();
        // use_text's y anchor is the text baseline.
        let baseline = self.cursor_y - TITLE_SIZE * 0.35;
        layer.use_text(text, TITLE_SIZE, Mm(MARGIN_MM), Mm(baseline), &self.bold);
        self.cursor_y -= TITLE_SIZE * 0.35 + TITLE_LEADING;
    }

    pub fn draw_subtitle(&mut self, text: &str) {
        self.ensure_space(SUBTITLE_LEADING + SUBTITLE_SIZE);
        let layer = self.layer_ref();
        let baseline = self.cursor_y - SUBTITLE_SIZE * 0.35;
        layer.use_text(text, SUBTITLE_SIZE, Mm(MARGIN_MM), Mm(baseline), &self.bold);
        self.cursor_y -= SUBTITLE_SIZE * 0.35 + SUBTITLE_LEADING;
    }

    pub fn draw_body_line(&mut self, text: &str) {
        self.ensure_space(BODY_LEADING + BODY_SIZE);
        let layer = self.layer_ref();
        let baseline = self.cursor_y - BODY_SIZE * 0.35;
        layer.use_text(text, BODY_SIZE, Mm(MARGIN_MM), Mm(baseline), &self.font);
        self.cursor_y -= BODY_SIZE * 0.35 + BODY_LEADING;
    }

    /// Render an `ExportGrid` as a simple table. The label column gets a fixed
    /// width; the remaining columns share the rest of the page evenly. Cell
    /// text is wrapped on existing '\n' characters and truncated horizontally
    /// if it would overflow its column (no reflow — fixed-template output).
    pub fn draw_grid_table(&mut self, grid: &ExportGrid) {
        let n_cols = grid.column_headers.len();
        if n_cols == 0 {
            return;
        }
        let data_col_width = (USABLE_WIDTH_MM - LABEL_COL_WIDTH_MM) / n_cols as f64;

        // Header row.
        let header_height = ROW_MIN_HEIGHT;
        self.ensure_space(header_height + ROW_MIN_HEIGHT);
        self.draw_table_row(
            "",
            &grid.column_headers,
            data_col_width,
            header_height,
            true,
        );

        // Data rows.
        for (row_idx, row) in grid.cells.iter().enumerate() {
            let label = grid.row_headers.get(row_idx).cloned().unwrap_or_default();
            // Row height scales with the tallest multi-line cell.
            let max_lines = row
                .iter()
                .map(|c| c.lines().count().max(1))
                .max()
                .unwrap_or(1)
                .max(label.lines().count().max(1));
            let row_height = (ROW_MIN_HEIGHT)
                .max(max_lines as f64 * (BODY_SIZE * 0.35 + BODY_LEADING) + 2.0 * CELL_PADDING_Y);
            // Page break if this row doesn't fit.
            if self.remaining_height() < row_height {
                self.new_page();
                // Redraw header on new page so the table is self-describing.
                self.draw_table_row(
                    "",
                    &grid.column_headers,
                    data_col_width,
                    header_height,
                    true,
                );
            }
            self.draw_table_row(&label, row, data_col_width, row_height, false);
        }
    }

    /// Draw a single table row: label column + n data columns, with borders.
    fn draw_table_row(
        &mut self,
        label: &str,
        cells: &[String],
        data_col_width: f64,
        row_height: f64,
        is_header: bool,
    ) {
        let top_y = self.cursor_y;
        let bottom_y = top_y - row_height;
        let n_cols = cells.len();

        // Cell borders (rectangle around each cell).
        let layer = self.layer_ref();
        let mut x = MARGIN_MM;
        let col_widths: Vec<f64> = std::iter::once(LABEL_COL_WIDTH_MM)
            .chain(std::iter::repeat_n(data_col_width, n_cols))
            .collect();
        for w in &col_widths {
            let rect_points = vec![
                (Point::new(Mm(x), Mm(top_y)), false),
                (Point::new(Mm(x + w), Mm(top_y)), false),
                (Point::new(Mm(x + w), Mm(bottom_y)), false),
                (Point::new(Mm(x), Mm(bottom_y)), false),
            ];
            let line = Line {
                points: rect_points,
                is_closed: true,
                has_fill: false,
                has_stroke: true,
                is_clipping_path: false,
            };
            layer.add_shape(line);
            x += w;
        }

        // Text content. Use bold for headers.
        let font = if is_header { &self.bold } else { &self.font };
        let mut x = MARGIN_MM;
        let draw_cell = |layer: &PdfLayerReference,
                         font: &IndirectFontRef,
                         text: &str,
                         cell_x: f64,
                         cell_w: f64| {
            let max_chars = ((cell_w - 2.0 * CELL_PADDING_X) / AVG_CHAR_WIDTH_MM).max(1.0) as usize;
            let mut line_y = top_y - CELL_PADDING_Y - BODY_SIZE * 0.35;
            for raw in text.lines() {
                let truncated: String = if raw.chars().count() > max_chars {
                    raw.chars()
                        .take(max_chars.saturating_sub(1))
                        .collect::<String>()
                        + "…"
                } else {
                    raw.to_string()
                };
                layer.use_text(
                    truncated,
                    BODY_SIZE,
                    Mm(cell_x + CELL_PADDING_X),
                    Mm(line_y),
                    font,
                );
                line_y -= BODY_SIZE * 0.35 + BODY_LEADING;
            }
        };
        draw_cell(&layer, font, label, x, LABEL_COL_WIDTH_MM);
        x += LABEL_COL_WIDTH_MM;
        for cell in cells {
            draw_cell(&layer, font, cell, x, data_col_width);
            x += data_col_width;
        }

        self.cursor_y = bottom_y;
    }

    pub fn finish(self) -> Result<Vec<u8>, String> {
        let mut buf = BufWriter::new(Vec::<u8>::new());
        self.doc
            .save(&mut buf)
            .map_err(|e| format!("pdf save: {e}"))?;
        buf.into_inner()
            .map_err(|e| format!("pdf buffer flush: {e}"))
    }
}
