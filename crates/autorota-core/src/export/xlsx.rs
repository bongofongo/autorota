//! XLSX renderer for rota + per-employee exports.
//!
//! Layout: one workbook, one or more sheets.
//! - Rota: "Schedule" (main grid) + one sheet per role ("By Role: {name}") +
//!   "Cost Summary" when the ManagerReport profile is in use.
//! - Employee: single "Schedule" sheet.
//!
//! Cell text is the same content that CSV/Markdown produce — we're not
//! reformatting shift content per format.

use rust_xlsxwriter::{Format, FormatAlign, FormatBorder, Workbook, XlsxError};

use super::grid::ExportGrid;

fn header_fmt() -> Format {
    Format::new()
        .set_bold()
        .set_background_color("#E8E8E8")
        .set_border(FormatBorder::Thin)
        .set_align(FormatAlign::Center)
}

fn cell_fmt() -> Format {
    Format::new()
        .set_border(FormatBorder::Thin)
        .set_text_wrap()
        .set_align(FormatAlign::Top)
}

fn totals_fmt() -> Format {
    Format::new()
        .set_bold()
        .set_background_color("#F5F5F5")
        .set_border(FormatBorder::Thin)
}

/// Render a workbook with the given sheets. Returns the raw XLSX bytes.
pub fn render_workbook(sheets: &[(String, &ExportGrid)]) -> Result<Vec<u8>, String> {
    let mut book = Workbook::new();
    for (name, grid) in sheets {
        let sheet_name = sanitize_sheet_name(name);
        let ws = book
            .add_worksheet()
            .set_name(&sheet_name)
            .map_err(err_to_string)?;
        write_grid(ws, grid).map_err(err_to_string)?;
    }
    book.save_to_buffer().map_err(err_to_string)
}

fn write_grid(ws: &mut rust_xlsxwriter::Worksheet, grid: &ExportGrid) -> Result<(), XlsxError> {
    let hfmt = header_fmt();
    let cfmt = cell_fmt();
    let tfmt = totals_fmt();

    ws.write_string_with_format(0, 0, "", &hfmt)?;
    for (c, header) in grid.column_headers.iter().enumerate() {
        ws.write_string_with_format(0, (c + 1) as u16, header, &hfmt)?;
    }

    for (r, row_header) in grid.row_headers.iter().enumerate() {
        let row_idx = (r + 1) as u32;
        ws.write_string_with_format(row_idx, 0, row_header, &hfmt)?;
        for (c, cell) in grid.cells[r].iter().enumerate() {
            ws.write_string_with_format(row_idx, (c + 1) as u16, cell, &cfmt)?;
        }
    }

    let mut next_row = grid.row_headers.len() as u32 + 1;
    if let Some(ref totals) = grid.daily_totals {
        ws.write_string_with_format(next_row, 0, "Totals", &tfmt)?;
        for (c, day) in totals.iter().enumerate() {
            let txt = format!("{:.1}h / ${:.2}", day.total_hours, day.total_cost);
            ws.write_string_with_format(next_row, (c + 1) as u16, &txt, &tfmt)?;
        }
        next_row += 1;
    }
    if let Some(weekly) = grid.weekly_total_cost {
        ws.write_string_with_format(next_row, 0, "Weekly Total", &tfmt)?;
        ws.write_number_with_format(next_row, 1, weekly as f64, &tfmt)?;
    }

    ws.set_column_width(0, 20)?;
    for c in 0..grid.column_headers.len() {
        ws.set_column_width((c + 1) as u16, 22)?;
    }

    Ok(())
}

fn err_to_string(e: XlsxError) -> String {
    e.to_string()
}

/// Excel sheet names are limited to 31 chars and can't contain `:\/?*[]`.
fn sanitize_sheet_name(name: &str) -> String {
    let mut out: String = name
        .chars()
        .map(|c| match c {
            ':' | '\\' | '/' | '?' | '*' | '[' | ']' => '_',
            _ => c,
        })
        .collect();
    if out.chars().count() > 31 {
        out = out.chars().take(31).collect();
    }
    if out.is_empty() {
        out = "Sheet".into();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::grid::ExportGrid;
    use calamine::{Data, Reader};
    use std::io::Cursor;

    fn grid() -> ExportGrid {
        ExportGrid {
            title: "Week".into(),
            column_headers: vec!["Mon".into(), "Tue".into()],
            row_headers: vec!["Alice".into()],
            cells: vec![vec!["Morning".into(), String::new()]],
            daily_totals: None,
            weekly_total_cost: None,
        }
    }

    #[test]
    fn basic_grid_roundtrip_through_calamine() {
        let g = grid();
        let bytes = render_workbook(&[("Schedule".into(), &g)]).unwrap();
        let mut wb: calamine::Xlsx<_> =
            calamine::open_workbook_from_rs(Cursor::new(bytes)).unwrap();
        let sheets = wb.sheet_names();
        assert_eq!(sheets, vec!["Schedule"]);
        let range = wb.worksheet_range("Schedule").unwrap();
        let header: Vec<String> = range
            .rows()
            .next()
            .unwrap()
            .iter()
            .map(|c| match c {
                Data::String(s) => s.clone(),
                Data::Empty => String::new(),
                _ => c.to_string(),
            })
            .collect();
        assert_eq!(header, vec!["".to_string(), "Mon".into(), "Tue".into()]);
    }

    #[test]
    fn multi_sheet_workbook_has_all_sheets() {
        let g = grid();
        let bytes =
            render_workbook(&[("Schedule".into(), &g), ("By Role: Barista".into(), &g)]).unwrap();
        let wb: calamine::Xlsx<_> = calamine::open_workbook_from_rs(Cursor::new(bytes)).unwrap();
        assert_eq!(wb.sheet_names(), vec!["Schedule", "By Role_ Barista"]);
    }

    #[test]
    fn sheet_name_sanitized_and_truncated() {
        assert_eq!(sanitize_sheet_name("Cost: Summary"), "Cost_ Summary");
        assert_eq!(
            sanitize_sheet_name("A very long sheet name that is over thirty one chars")
                .chars()
                .count(),
            31
        );
    }

    /// Formula-injection regression pin (parity with the CSV neutralisation
    /// tests): cells are written via `write_string_with_format`, which produces
    /// string-typed cells that Excel never evaluates. If the writer ever
    /// switches to a type-inferring `write` call, these payloads would come
    /// back as Float/formula and this test fails.
    #[test]
    fn formula_payloads_stay_inert_strings() {
        let payloads = [
            "=SUM(A1:A9)",
            "+cmd|' /C calc'!A0",
            "-2+3",
            "@foo",
            "\t=1+1",
            "\r=1+1",
        ];
        let g = ExportGrid {
            title: "Week".into(),
            column_headers: vec!["Mon".into()],
            row_headers: payloads.iter().map(|p| format!("row {p}")).collect(),
            cells: payloads.iter().map(|p| vec![p.to_string()]).collect(),
            daily_totals: None,
            weekly_total_cost: None,
        };
        let bytes = render_workbook(&[("Schedule".into(), &g)]).unwrap();
        let mut wb: calamine::Xlsx<_> =
            calamine::open_workbook_from_rs(Cursor::new(bytes)).unwrap();
        let range = wb.worksheet_range("Schedule").unwrap();

        // Skip the header row; every payload cell must round-trip as a string
        // with content intact — never a number or formula result. (`\r` legally
        // round-trips as the OOXML escape `_x000D_`; still a string cell.)
        for (i, payload) in payloads.iter().enumerate() {
            let expected = payload.replace('\r', "_x000D_");
            let cell = range.get_value(((i + 1) as u32, 1)).unwrap();
            match cell {
                Data::String(s) => assert_eq!(s, &expected, "payload mangled at row {i}"),
                other => panic!("payload {payload:?} came back as non-string {other:?}"),
            }
        }
    }
}
