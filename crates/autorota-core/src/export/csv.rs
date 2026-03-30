use super::grid::ExportGrid;

/// Escape a cell value per RFC 4180.
fn csv_escape(value: &str) -> String {
    if value.contains(',') || value.contains('"') || value.contains('\n') {
        let escaped = value.replace('"', "\"\"");
        format!("\"{escaped}\"")
    } else {
        value.to_string()
    }
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
    fn csv_with_totals() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: vec!["Mon".to_string(), "Tue".to_string()],
            row_headers: vec!["Alice".to_string()],
            cells: vec![vec!["Morning".to_string(), String::new()]],
            daily_totals: Some(vec![
                DaySummary { total_hours: 5.0, total_cost: 75.0 },
                DaySummary { total_hours: 0.0, total_cost: 0.0 },
            ]),
            weekly_total_cost: Some(75.0),
        };
        let csv = render_csv(&grid);
        assert!(csv.contains("Totals,5.0h / $75.00,0.0h / $0.00"));
        assert!(csv.contains("Weekly Total,$75.00"));
    }
}
