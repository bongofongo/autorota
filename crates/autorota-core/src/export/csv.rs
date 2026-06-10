use super::grid::ExportGrid;

/// Per OWASP CSV-injection guidance: a leading `=`, `+`, `-`, `@`, tab,
/// or carriage-return makes Excel / Numbers / Sheets interpret the cell
/// as a formula on import. Prefixing with `'` neutralises that without
/// breaking the visible value (the leading apostrophe is hidden by the
/// parser).
///
/// Crucially, we skip leading whitespace (including the Unicode line
/// separators) before checking the first sentinel char — without this,
/// `" =cmd"` and `"\u{2028}=cmd"` slip past the bare `chars().next()`
/// check and Excel still parses them as formulas.
fn needs_formula_prefix(value: &str) -> bool {
    let first = value.chars().find(|c| !is_csv_skippable_whitespace(*c));
    matches!(
        first,
        Some('=') | Some('+') | Some('-') | Some('@') | Some('\t') | Some('\r')
    )
}

/// Whitespace characters Excel/Numbers/Sheets strip before formula
/// recognition. Includes U+0085 (NEL), U+2028 (LS), U+2029 (PS) which
/// `char::is_whitespace` already covers, plus regular ASCII whitespace.
fn is_csv_skippable_whitespace(c: char) -> bool {
    c == ' ' || c == '\u{00A0}' || c == '\u{0085}' || c == '\u{2028}' || c == '\u{2029}'
}

/// Escape a cell value per RFC 4180, plus OWASP CSV-injection
/// neutralisation for cells that would otherwise be parsed as formulas.
fn csv_escape(value: &str) -> String {
    let safe: std::borrow::Cow<'_, str> = if needs_formula_prefix(value) {
        std::borrow::Cow::Owned(format!("'{value}"))
    } else {
        std::borrow::Cow::Borrowed(value)
    };
    if safe.contains(',') || safe.contains('"') || safe.contains('\n') {
        let escaped = safe.replace('"', "\"\"");
        format!("\"{escaped}\"")
    } else {
        safe.into_owned()
    }
}

/// Render role-sectioned grids as one CSV document: a role title line, the
/// section's grid, then a blank line between sections.
pub fn render_csv_sections(sections: &[(String, ExportGrid)]) -> String {
    sections
        .iter()
        .map(|(role, grid)| format!("{}\n{}", csv_escape(role), render_csv(grid)))
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Render an `ExportGrid` as an RFC 4180 CSV string.
pub fn render_csv(grid: &ExportGrid) -> String {
    let mut lines = Vec::new();

    // Header row: blank corner cell + column headers.
    let mut header = vec![String::new()];
    header.extend(grid.column_headers.iter().map(|h| csv_escape(h)));
    lines.push(header.join(","));

    // Data rows.
    for (i, row_header) in grid.row_headers.iter().enumerate() {
        let mut row = vec![csv_escape(row_header)];
        row.extend(grid.cells[i].iter().map(|c| csv_escape(c)));
        lines.push(row.join(","));
    }

    // Totals row (ManagerReport only).
    if let Some(ref totals) = grid.daily_totals {
        let mut row = vec!["Totals".to_string()];
        for day in totals {
            row.push(format!("{:.1}h / ${:.2}", day.total_hours, day.total_cost));
        }
        lines.push(row.join(","));

        if let Some(weekly) = grid.weekly_total_cost {
            lines.push(format!("Weekly Total,${weekly:.2}"));
        }
    }

    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::grid::DaySummary;

    fn simple_grid() -> ExportGrid {
        ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon 23 Mar".to_string(), "Tue 24 Mar".to_string()],
            row_headers: vec!["Alice".to_string(), "Bob".to_string()],
            cells: vec![
                vec!["Morning 07:00-12:00".to_string(), String::new()],
                vec![String::new(), "Afternoon 13:00-17:00".to_string()],
            ],
            daily_totals: None,
            weekly_total_cost: None,
        }
    }

    #[test]
    fn basic_csv() {
        let csv = render_csv(&simple_grid());
        let lines: Vec<&str> = csv.lines().collect();
        assert_eq!(lines[0], ",Mon 23 Mar,Tue 24 Mar");
        assert_eq!(lines[1], "Alice,Morning 07:00-12:00,");
        assert_eq!(lines[2], "Bob,,Afternoon 13:00-17:00");
    }

    #[test]
    fn csv_escapes_commas() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon".to_string()],
            row_headers: vec!["Smith, Alice".to_string()],
            cells: vec![vec!["Morning, early".to_string()]],
            daily_totals: None,
            weekly_total_cost: None,
        };
        let csv = render_csv(&grid);
        let lines: Vec<&str> = csv.lines().collect();
        assert_eq!(lines[1], "\"Smith, Alice\",\"Morning, early\"");
    }

    #[test]
    fn csv_escapes_quotes() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon".to_string()],
            row_headers: vec!["Alice".to_string()],
            cells: vec![vec!["The \"Morning\" shift".to_string()]],
            daily_totals: None,
            weekly_total_cost: None,
        };
        let csv = render_csv(&grid);
        assert!(csv.contains("\"The \"\"Morning\"\" shift\""));
    }

    #[test]
    fn csv_escapes_newlines() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon".to_string()],
            row_headers: vec!["Morning".to_string()],
            cells: vec![vec!["Alice\nBob".to_string()]],
            daily_totals: None,
            weekly_total_cost: None,
        };
        let csv = render_csv(&grid);
        // The newline cell should be quoted.
        assert!(csv.contains("\"Alice\nBob\""));
    }

    #[test]
    fn csv_neutralises_formula_prefix_equals() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon".to_string()],
            row_headers: vec!["Alice".to_string()],
            cells: vec![vec!["=SUM(A1:A10)".to_string()]],
            daily_totals: None,
            weekly_total_cost: None,
        };
        let csv = render_csv(&grid);
        // Leading '=' must be neutralised with a leading apostrophe.
        assert!(csv.contains("'=SUM(A1:A10)"));
        assert!(!csv.contains(",=SUM"));
    }

    #[test]
    fn csv_neutralises_formula_prefix_plus_minus_at() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["A".to_string(), "B".to_string(), "C".to_string()],
            row_headers: vec!["Alice".to_string()],
            cells: vec![vec![
                "+1+1".to_string(),
                "-2".to_string(),
                "@cmd".to_string(),
            ]],
            daily_totals: None,
            weekly_total_cost: None,
        };
        let csv = render_csv(&grid);
        assert!(csv.contains("'+1+1"));
        assert!(csv.contains("'-2"));
        assert!(csv.contains("'@cmd"));
    }

    #[test]
    fn csv_neutralised_cell_with_comma_still_quoted() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["A".to_string()],
            row_headers: vec!["Alice".to_string()],
            cells: vec![vec!["=A1,B1".to_string()]],
            daily_totals: None,
            weekly_total_cost: None,
        };
        let csv = render_csv(&grid);
        // Both prefix neutralisation and RFC 4180 quoting must apply.
        assert!(csv.contains("\"'=A1,B1\""));
    }

    #[test]
    fn csv_neutralises_whitespace_prefixed_formula() {
        // OWASP regression net: leading space + sentinel char must still be
        // neutralised. Excel strips ASCII whitespace before parsing the cell
        // as a formula.
        for prefix in [" ", "\u{00A0}", "\u{2028}", "\u{2029}", "\u{0085}"] {
            let payload = format!("{prefix}=SUM(A1:A10)");
            let grid = ExportGrid {
                title: "Test".to_string(),
                column_headers: vec!["Mon".to_string()],
                row_headers: vec!["Alice".to_string()],
                cells: vec![vec![payload.clone()]],
                daily_totals: None,
                weekly_total_cost: None,
            };
            let csv = render_csv(&grid);
            assert!(
                csv.contains(&format!("'{payload}")),
                "expected apostrophe-prefixed neutralisation for {payload:?}, got {csv:?}"
            );
        }
    }

    #[test]
    fn csv_with_totals() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon".to_string(), "Tue".to_string()],
            row_headers: vec!["Alice".to_string()],
            cells: vec![vec!["Morning".to_string(), String::new()]],
            daily_totals: Some(vec![
                DaySummary {
                    total_hours: 5.0,
                    total_cost: 75.0,
                },
                DaySummary {
                    total_hours: 0.0,
                    total_cost: 0.0,
                },
            ]),
            weekly_total_cost: Some(75.0),
        };
        let csv = render_csv(&grid);
        assert!(csv.contains("Totals,5.0h / $75.00,0.0h / $0.00"));
        assert!(csv.contains("Weekly Total,$75.00"));
    }
}
