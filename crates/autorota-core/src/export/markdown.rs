use super::grid::ExportGrid;

/// Render role-sectioned grids as one Markdown document: a `##` heading per
/// role followed by that section's table.
pub fn render_markdown_sections(sections: &[(String, ExportGrid)]) -> String {
    sections
        .iter()
        .map(|(role, grid)| format!("## {role}\n\n{}", render_markdown(grid)))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Render an `ExportGrid` as a GitHub-flavored Markdown table.
///
/// Column widths are computed from the widest cell (including header) so the
/// raw markdown reads cleanly in a monospace viewer. Newlines inside cells are
/// collapsed to `<br>` so the table stays on one row per record.
pub fn render_markdown(grid: &ExportGrid) -> String {
    let mut header = vec![String::new()];
    header.extend(grid.column_headers.iter().cloned());

    let mut rows: Vec<Vec<String>> = Vec::with_capacity(grid.row_headers.len());
    for (i, rh) in grid.row_headers.iter().enumerate() {
        let mut row = vec![rh.clone()];
        row.extend(grid.cells[i].iter().map(|c| c.replace('\n', "<br>")));
        rows.push(row);
    }

    if let Some(ref totals) = grid.daily_totals {
        let mut row = vec!["**Totals**".to_string()];
        for day in totals {
            row.push(format!("{:.1}h / ${:.2}", day.total_hours, day.total_cost));
        }
        rows.push(row);
    }

    let mut widths = vec![0usize; header.len()];
    for (i, h) in header.iter().enumerate() {
        widths[i] = widths[i].max(h.chars().count());
    }
    for row in &rows {
        for (i, c) in row.iter().enumerate() {
            if i < widths.len() {
                widths[i] = widths[i].max(c.chars().count());
            }
        }
    }

    let pad = |s: &str, w: usize| -> String {
        let len = s.chars().count();
        if len >= w {
            s.to_string()
        } else {
            format!("{s}{}", " ".repeat(w - len))
        }
    };

    let mut out = String::new();
    out.push('|');
    for (i, h) in header.iter().enumerate() {
        out.push(' ');
        out.push_str(&pad(h, widths[i]));
        out.push_str(" |");
    }
    out.push('\n');

    out.push('|');
    for w in &widths {
        out.push_str(&format!(" {} |", "-".repeat(*w)));
    }
    out.push('\n');

    for row in &rows {
        out.push('|');
        for i in 0..header.len() {
            let cell = row.get(i).map(String::as_str).unwrap_or("");
            out.push(' ');
            out.push_str(&pad(cell, widths[i]));
            out.push_str(" |");
        }
        out.push('\n');
    }

    if let Some(weekly) = grid.weekly_total_cost {
        out.push_str(&format!("\n**Weekly Total:** ${weekly:.2}\n"));
    }

    out
}

/// Compact per-employee Markdown: one bullet per day.
///
/// Uses a single-employee grid (dates as columns, one row). Empty cells become
/// "off" and newlines in a cell (multiple shifts) separate with "+".
pub fn render_employee_markdown(grid: &ExportGrid, employee_name: &str) -> String {
    let mut out = format!("# {employee_name}\n\n");
    if grid.row_headers.is_empty() || grid.cells.is_empty() {
        out.push_str("_No shifts in range._\n");
        return out;
    }
    let row = &grid.cells[0];
    for (i, col) in grid.column_headers.iter().enumerate() {
        let cell = row.get(i).map(String::as_str).unwrap_or("").trim();
        let body = if cell.is_empty() {
            "off".to_string()
        } else {
            cell.replace('\n', " + ")
        };
        out.push_str(&format!("- **{col}** — {body}\n"));
    }
    if let Some(weekly) = grid.weekly_total_cost {
        out.push_str(&format!("\n**Total cost:** ${weekly:.2}\n"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::grid::DaySummary;

    fn grid() -> ExportGrid {
        ExportGrid {
            title: "Week".into(),
            column_headers: vec!["Mon".into(), "Tue".into()],
            row_headers: vec!["Alice".into(), "Bob".into()],
            cells: vec![
                vec!["Morning 07-12".into(), String::new()],
                vec![String::new(), "Eve 17-22".into()],
            ],
            daily_totals: None,
            weekly_total_cost: None,
        }
    }

    #[test]
    fn basic_table_has_header_separator_and_rows() {
        let md = render_markdown(&grid());
        let lines: Vec<&str> = md.lines().collect();
        assert!(lines[0].starts_with("|"));
        assert!(lines[1].contains("---"));
        assert!(lines[2].contains("Alice"));
        assert!(lines[3].contains("Bob"));
    }

    #[test]
    fn totals_row_renders_when_present() {
        let mut g = grid();
        g.daily_totals = Some(vec![
            DaySummary {
                total_hours: 5.0,
                total_cost: 75.0,
            },
            DaySummary {
                total_hours: 0.0,
                total_cost: 0.0,
            },
        ]);
        g.weekly_total_cost = Some(75.0);
        let md = render_markdown(&g);
        assert!(md.contains("**Totals**"));
        assert!(md.contains("**Weekly Total:** $75.00"));
    }

    #[test]
    fn employee_markdown_marks_empty_days_off() {
        let g = ExportGrid {
            title: "".into(),
            column_headers: vec!["Mon".into(), "Tue".into()],
            row_headers: vec!["Alice".into()],
            cells: vec![vec!["Morning".into(), String::new()]],
            daily_totals: None,
            weekly_total_cost: None,
        };
        let md = render_employee_markdown(&g, "Alice");
        assert!(md.contains("# Alice"));
        assert!(md.contains("**Mon** — Morning"));
        assert!(md.contains("**Tue** — off"));
    }

    #[test]
    fn newlines_collapse_to_br_in_table() {
        let mut g = grid();
        g.cells[0][0] = "Morning\nEarly".into();
        let md = render_markdown(&g);
        assert!(md.contains("Morning<br>Early"));
    }
}
