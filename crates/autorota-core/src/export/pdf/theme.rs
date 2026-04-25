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
/// Tight intra-cell line gap. Table cells stack related lines (shift name,
/// time, role) so they need much denser spacing than prose paragraphs.
const CELL_LINE_LEADING: f64 = 1.0;
const CELL_PADDING_X: f64 = 1.5;
const CELL_PADDING_Y: f64 = 1.0;
const ROW_MIN_HEIGHT: f64 = 6.0;
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
    /// text is pre-wrapped: each explicit line is soft-wrapped on whitespace
    /// to fit its column, and single tokens that exceed the column width are
    /// ellipsized as a last resort. Row height grows to the tallest post-wrap
    /// cell.
    pub fn draw_grid_table(&mut self, grid: &ExportGrid) {
        let n_cols = grid.column_headers.len();
        if n_cols == 0 {
            return;
        }
        let data_col_width = (USABLE_WIDTH_MM - LABEL_COL_WIDTH_MM) / n_cols as f64;

        // Header row.
        let header_lines: Vec<Vec<String>> = grid
            .column_headers
            .iter()
            .map(|h| wrap_cell(h, data_col_width))
            .collect();
        let header_height = row_height_for(&[], &header_lines);
        self.ensure_space(header_height + ROW_MIN_HEIGHT);
        self.draw_table_row_pre("", &header_lines, data_col_width, header_height, true);

        // Data rows.
        for (row_idx, row) in grid.cells.iter().enumerate() {
            let label = grid.row_headers.get(row_idx).cloned().unwrap_or_default();
            let label_lines = wrap_cell(&label, LABEL_COL_WIDTH_MM);
            let cell_lines: Vec<Vec<String>> =
                row.iter().map(|c| wrap_cell(c, data_col_width)).collect();
            let row_height = row_height_for(&label_lines, &cell_lines);
            // Page break if this row doesn't fit.
            if self.remaining_height() < row_height {
                self.new_page();
                // Redraw header on new page so the table is self-describing.
                self.draw_table_row_pre("", &header_lines, data_col_width, header_height, true);
            }
            self.draw_table_row_pre_label(
                &label_lines,
                &cell_lines,
                data_col_width,
                row_height,
                false,
            );
        }
    }

    fn draw_table_row_pre(
        &mut self,
        label: &str,
        cells: &[Vec<String>],
        data_col_width: f64,
        row_height: f64,
        is_header: bool,
    ) {
        let label_lines = wrap_cell(label, LABEL_COL_WIDTH_MM);
        self.draw_table_row_pre_label(&label_lines, cells, data_col_width, row_height, is_header);
    }

    /// Draw a row from pre-wrapped cell lines.
    fn draw_table_row_pre_label(
        &mut self,
        label_lines: &[String],
        cells: &[Vec<String>],
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
        let draw_cell =
            |layer: &PdfLayerReference, font: &IndirectFontRef, lines: &[String], cell_x: f64| {
                let mut line_y = top_y - CELL_PADDING_Y - BODY_SIZE * 0.35;
                for l in lines {
                    layer.use_text(
                        l.clone(),
                        BODY_SIZE,
                        Mm(cell_x + CELL_PADDING_X),
                        Mm(line_y),
                        font,
                    );
                    line_y -= BODY_SIZE * 0.35 + CELL_LINE_LEADING;
                }
            };
        draw_cell(&layer, font, label_lines, x);
        x += LABEL_COL_WIDTH_MM;
        for cell in cells {
            draw_cell(&layer, font, cell, x);
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

/// Soft-wrap `raw` to fit `cell_w` mm. Preserves explicit `\n` as hard breaks,
/// greedy-wraps the rest on whitespace. Single tokens that exceed the cell
/// width get ellipsized (`…`) as a last resort so they can never overflow.
fn wrap_cell(raw: &str, cell_w: f64) -> Vec<String> {
    let max_chars = ((cell_w - 2.0 * CELL_PADDING_X) / AVG_CHAR_WIDTH_MM).max(1.0) as usize;
    let mut out: Vec<String> = Vec::new();
    for hard_line in raw.split('\n') {
        if hard_line.is_empty() {
            out.push(String::new());
            continue;
        }
        let mut current = String::new();
        for tok in hard_line.split_whitespace() {
            let tok_len = tok.chars().count();
            let fitted = if tok_len > max_chars {
                let mut s: String = tok.chars().take(max_chars.saturating_sub(1)).collect();
                s.push('…');
                s
            } else {
                tok.to_string()
            };
            if current.is_empty() {
                current = fitted;
            } else if current.chars().count() + 1 + fitted.chars().count() <= max_chars {
                current.push(' ');
                current.push_str(&fitted);
            } else {
                out.push(std::mem::take(&mut current));
                current = fitted;
            }
        }
        if !current.is_empty() {
            out.push(current);
        }
    }
    if out.is_empty() {
        out.push(String::new());
    }
    out
}

/// Tallest post-wrap line count across label + cells, converted to mm height.
fn row_height_for(label_lines: &[String], cell_lines: &[Vec<String>]) -> f64 {
    let max_lines = cell_lines
        .iter()
        .map(|c| c.len().max(1))
        .max()
        .unwrap_or(1)
        .max(label_lines.len().max(1));
    (ROW_MIN_HEIGHT)
        .max(max_lines as f64 * (BODY_SIZE * 0.35 + CELL_LINE_LEADING) + 2.0 * CELL_PADDING_Y)
}
