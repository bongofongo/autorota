//! Content assertions for the PDF renderers: render each template, extract
//! the text layer with lopdf, and require the grid's actual strings (names,
//! headers, cells, cost totals) to be present. Complements the byte-level
//! `%PDF-` smoke tests inline in `export/pdf/mod.rs`.

use autorota_core::export::grid::{DaySummary, ExportGrid};
use autorota_core::export::pdf;
use chrono::NaiveDate;

fn week_start() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 1, 5).unwrap()
}

/// Extract the text of every page, concatenated.
fn extract_all_text(bytes: &[u8]) -> String {
    let doc = lopdf::Document::load_mem(bytes).expect("lopdf parses renderer output");
    let pages: Vec<u32> = doc.get_pages().keys().copied().collect();
    assert!(!pages.is_empty(), "PDF has no pages");
    let raw = pages
        .iter()
        .map(|p| doc.extract_text(&[*p]).expect("page text extracts"))
        .collect::<Vec<_>>()
        .join("\n");
    // Cell text wraps onto multiple extracted lines; normalize all whitespace
    // to single spaces so assertions can use the original cell strings.
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn grid() -> ExportGrid {
    ExportGrid {
        title: "Rota Week 2026-01-05".into(),
        column_headers: vec![
            "Mon 05".into(),
            "Tue 06".into(),
            "Wed 07".into(),
            "Thu 08".into(),
            "Fri 09".into(),
            "Sat 10".into(),
            "Sun 11".into(),
        ],
        row_headers: vec!["Alice Marzipan".into(), "Bob Quokka".into()],
        cells: vec![
            vec![
                "Morning 08:00-12:00".into(),
                String::new(),
                "Evening 17:00-22:00".into(),
                String::new(),
                String::new(),
                String::new(),
                String::new(),
            ],
            vec![
                String::new(),
                "Kitchen 09:00-15:00".into(),
                String::new(),
                String::new(),
                String::new(),
                String::new(),
                String::new(),
            ],
        ],
        daily_totals: None,
        weekly_total_cost: None,
    }
}

#[test]
fn weekly_pdf_contains_names_headers_cells_and_costs() {
    let mut g = grid();
    g.daily_totals = Some(
        (0..7)
            .map(|_| DaySummary {
                total_hours: 8.0,
                total_cost: 120.0,
            })
            .collect(),
    );
    g.weekly_total_cost = Some(1234.56);

    let bytes = pdf::weekly::render(&g, week_start()).unwrap();
    let text = extract_all_text(&bytes);

    for needle in [
        "Alice Marzipan",
        "Bob Quokka",
        "Mon 05",
        "Sun 11",
        "Morning 08:00-12:00",
        "Kitchen 09:00-15:00",
        "1234.56",
    ] {
        assert!(
            text.contains(needle),
            "weekly PDF missing {needle:?}:\n{text}"
        );
    }
}

#[test]
fn employee_pdf_contains_rows_and_headers() {
    let g = grid();
    let bytes = pdf::employee::render(&g, week_start()).unwrap();
    let text = extract_all_text(&bytes);
    for needle in [
        "Alice Marzipan",
        "Bob Quokka",
        "Mon 05",
        "Morning 08:00-12:00",
    ] {
        assert!(
            text.contains(needle),
            "employee PDF missing {needle:?}:\n{text}"
        );
    }
}

#[test]
fn employee_schedule_pdf_contains_title_and_cells() {
    let g = grid();
    let bytes = pdf::employee_schedule::render(&g).unwrap();
    let text = extract_all_text(&bytes);
    for needle in ["Rota Week 2026-01-05", "Morning 08:00-12:00"] {
        assert!(
            text.contains(needle),
            "employee_schedule PDF missing {needle:?}:\n{text}"
        );
    }
}

#[test]
fn by_role_pdf_contains_each_section() {
    let sections = vec![
        ("Barista".to_string(), grid()),
        ("Kitchen".to_string(), grid()),
    ];
    let bytes = pdf::by_role::render(&sections, week_start()).unwrap();
    let text = extract_all_text(&bytes);
    for needle in ["Barista", "Kitchen", "Alice Marzipan"] {
        assert!(
            text.contains(needle),
            "by_role PDF missing {needle:?}:\n{text}"
        );
    }
}

#[test]
fn many_rows_paginate_and_all_pages_have_text() {
    let rows = 80;
    let g = ExportGrid {
        title: "Big".into(),
        column_headers: (0..7).map(|i| format!("D{i}")).collect(),
        row_headers: (0..rows).map(|i| format!("Employee {i:03}")).collect(),
        cells: (0..rows)
            .map(|i| (0..7).map(|d| format!("S{i:03}/{d}")).collect())
            .collect(),
        daily_totals: None,
        weekly_total_cost: None,
    };
    let bytes = pdf::weekly::render(&g, week_start()).unwrap();
    let doc = lopdf::Document::load_mem(&bytes).unwrap();
    let pages: Vec<u32> = doc.get_pages().keys().copied().collect();
    assert!(pages.len() > 1, "80 rows should paginate, got 1 page");

    let text = extract_all_text(&bytes);
    assert!(text.contains("Employee 000"), "first row missing");
    assert!(
        text.contains(&format!("Employee {:03}", rows - 1)),
        "last row missing — page break dropped rows"
    );
}

/// Documented limitation probe: the renderers use printpdf's built-in
/// Helvetica (WinAnsi encoding), so non-Latin text cannot be encoded.
/// This test pins whatever the current behavior is so a change (embedding
/// a Unicode font, or a regression to panics) is caught deliberately.
#[test]
fn non_winansi_names_do_not_panic() {
    let mut g = grid();
    g.row_headers[0] = "李小龙 (Bruce)".into();
    g.cells[0][0] = "咖啡 08:00".into();

    // Must not panic or error even though the glyphs aren't encodable.
    let bytes = pdf::weekly::render(&g, week_start()).unwrap();
    let text = extract_all_text(&bytes);

    // Latin content still extracts fine alongside the non-encodable name.
    assert!(text.contains("Bob Quokka"));
    assert!(text.contains("08:00"));
    // Known limitation, pinned: CJK glyphs are not encodable in WinAnsi and do
    // not survive into the text layer. If this assertion ever fails, a Unicode
    // font landed — delete this pin and assert the opposite.
    assert!(
        !text.contains("李小龙"),
        "CJK unexpectedly rendered — Unicode font support arrived? Update this pin."
    );
}
