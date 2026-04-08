//! PDF export templates. Each sub-module consumes the same `ExportGrid`
//! intermediate used by CSV/JSON so no business logic is duplicated.

pub mod by_role;
pub mod employee;
mod theme;
pub mod weekly;

#[cfg(test)]
mod tests {
    use chrono::NaiveDate;

    use crate::export::grid::{DaySummary, ExportGrid};

    fn week_start() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 3, 23).unwrap()
    }

    fn sample_grid(row_count: usize) -> ExportGrid {
        ExportGrid {
            title: "Test".to_string(),
            column_headers: (0..7).map(|i| format!("D{i}")).collect(),
            row_headers: (0..row_count).map(|i| format!("Row {i}")).collect(),
            cells: (0..row_count)
                .map(|i| (0..7).map(|d| format!("Shift {i}/{d}")).collect())
                .collect(),
            daily_totals: None,
            weekly_total_cost: None,
        }
    }

    fn assert_pdf(bytes: &[u8]) {
        assert!(bytes.len() > 500, "pdf too small ({} bytes)", bytes.len());
        assert!(
            bytes.starts_with(b"%PDF-"),
            "missing PDF magic, got {:?}",
            &bytes[..bytes.len().min(8)]
        );
    }

    #[test]
    fn weekly_render_produces_valid_pdf() {
        let mut grid = sample_grid(3);
        grid.weekly_total_cost = Some(1234.56);
        grid.daily_totals = Some(
            (0..7)
                .map(|_| DaySummary {
                    total_hours: 8.0,
                    total_cost: 120.0,
                })
                .collect(),
        );
        let bytes = super::weekly::render(&grid, week_start()).unwrap();
        assert_pdf(&bytes);
    }

    #[test]
    fn employee_render_produces_valid_pdf() {
        let grid = sample_grid(4);
        let bytes = super::employee::render(&grid, week_start()).unwrap();
        assert_pdf(&bytes);
    }

    #[test]
    fn employee_render_handles_empty_week() {
        let grid = ExportGrid {
            title: "Test".to_string(),
            column_headers: (0..7).map(|i| format!("D{i}")).collect(),
            row_headers: vec![],
            cells: vec![],
            daily_totals: None,
            weekly_total_cost: None,
        };
        let bytes = super::employee::render(&grid, week_start()).unwrap();
        assert_pdf(&bytes);
    }

    #[test]
    fn by_role_render_produces_valid_pdf_and_scales_with_sections() {
        let one = vec![("Barista".to_string(), sample_grid(2))];
        let three = vec![
            ("Barista".to_string(), sample_grid(2)),
            ("Kitchen".to_string(), sample_grid(2)),
            ("Front".to_string(), sample_grid(2)),
        ];
        let small = super::by_role::render(&one, week_start()).unwrap();
        let large = super::by_role::render(&three, week_start()).unwrap();
        assert_pdf(&small);
        assert_pdf(&large);
        assert!(
            large.len() > small.len(),
            "three-role PDF ({}) should be larger than one-role ({})",
            large.len(),
            small.len()
        );
    }

    #[test]
    fn by_role_render_handles_empty_sections() {
        let bytes = super::by_role::render(&[], week_start()).unwrap();
        assert_pdf(&bytes);
    }

    #[test]
    fn weekly_grid_page_break_with_many_rows() {
        // 40 rows forces at least one page break inside the table.
        let grid = sample_grid(40);
        let bytes = super::weekly::render(&grid, week_start()).unwrap();
        assert_pdf(&bytes);
    }
}
