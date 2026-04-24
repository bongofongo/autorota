mod helpers;

use autorota_core::db::queries;
use autorota_core::export::config::*;
use autorota_core::export::grid::*;
use autorota_core::export::{ExportError, export_employee_schedule, export_week_schedule};
use autorota_core::models::availability::AvailabilityState;
use autorota_core::testutil::*;
use chrono::{NaiveDate, Weekday};

// ── Helper constructors ────────────────────────────────────────────────────

fn make_shift_for_grid(
    id: i64,
    template_id: Option<i64>,
    date: NaiveDate,
    start: u32,
    end: u32,
    role: &str,
    rota_id: i64,
) -> autorota_core::models::shift::Shift {
    let mut b = ShiftBuilder::new()
        .id(id)
        .date(date)
        .times(start, end)
        .role(role)
        .rota(rota_id)
        .capacity(1, 2);
    if let Some(tid) = template_id {
        b = b.template(tid);
    } else {
        b = b.no_template();
    }
    b.build()
}

fn make_template_for_grid(
    id: i64,
    name: &str,
    start: u32,
    end: u32,
    role: &str,
) -> autorota_core::models::shift::ShiftTemplate {
    ShiftTemplateBuilder::new(name)
        .id(id)
        .weekdays(&[
            Weekday::Mon,
            Weekday::Tue,
            Weekday::Wed,
            Weekday::Thu,
            Weekday::Fri,
        ])
        .times(start, end)
        .role(role)
        .capacity(1, 2)
        .build()
}

fn make_employee_for_grid(
    id: i64,
    first: &str,
    last: &str,
) -> autorota_core::models::employee::Employee {
    EmployeeBuilder::new(first)
        .id(id)
        .last_name(last)
        .role("barista")
        .wage(15.0, "usd")
        .start_date(week_start())
        .build()
}

fn make_assignment_for_grid(
    id: i64,
    shift_id: i64,
    employee_id: i64,
    wage: Option<f32>,
) -> autorota_core::models::assignment::Assignment {
    let mut b = AssignmentBuilder::new(shift_id, employee_id)
        .id(id)
        .confirmed();
    if let Some(w) = wage {
        b = b.wage(w);
    }
    b.build()
}

fn staff_config(layout: ExportLayout) -> ExportConfig {
    ExportConfigBuilder::staff().layout(layout).build()
}

fn default_flags() -> CellContentFlags {
    CellContentFlags {
        show_shift_name: true,
        show_times: true,
        show_role: false,
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 1. build_grids_by_role
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn grids_by_role_two_roles_produces_two_grids() {
    let ws = week_start();
    let mon = ws;

    let templates = vec![
        make_template_for_grid(1, "Morning Barista", 7, 12, "barista"),
        make_template_for_grid(2, "Morning Server", 7, 12, "server"),
    ];
    let shifts = vec![
        make_shift_for_grid(1, Some(1), mon, 7, 12, "barista", 1),
        make_shift_for_grid(2, Some(2), mon, 7, 12, "server", 1),
    ];
    let employees = vec![
        make_employee_for_grid(1, "Alice", "Smith"),
        make_employee_for_grid(2, "Bob", "Jones"),
    ];
    let assignments = vec![
        make_assignment_for_grid(1, 1, 1, Some(15.0)),
        make_assignment_for_grid(2, 2, 2, Some(15.0)),
    ];

    let config = staff_config(ExportLayout::ShiftByWeekday);
    let grids = build_grids_by_role(&config, ws, &assignments, &shifts, &employees, &templates);

    assert_eq!(grids.len(), 2);
    assert_eq!(grids[0].0, "barista");
    assert_eq!(grids[1].0, "server");
}

#[test]
fn grids_by_role_same_role_produces_one_grid() {
    let ws = week_start();
    let mon = ws;
    let tue = ws + chrono::Duration::days(1);

    let templates = vec![make_template_for_grid(1, "Morning", 7, 12, "barista")];
    let shifts = vec![
        make_shift_for_grid(1, Some(1), mon, 7, 12, "barista", 1),
        make_shift_for_grid(2, Some(1), tue, 7, 12, "barista", 1),
    ];
    let employees = vec![make_employee_for_grid(1, "Alice", "Smith")];
    let assignments = vec![
        make_assignment_for_grid(1, 1, 1, Some(15.0)),
        make_assignment_for_grid(2, 2, 1, Some(15.0)),
    ];

    let config = staff_config(ExportLayout::EmployeeByWeekday);
    let grids = build_grids_by_role(&config, ws, &assignments, &shifts, &employees, &templates);

    assert_eq!(grids.len(), 1);
    assert_eq!(grids[0].0, "barista");
}

#[test]
fn grids_by_role_empty_shifts_produces_empty() {
    let ws = week_start();
    let config = staff_config(ExportLayout::EmployeeByWeekday);
    let grids = build_grids_by_role(&config, ws, &[], &[], &[], &[]);
    assert!(grids.is_empty());
}

#[test]
fn grids_by_role_alphabetical_order() {
    let ws = week_start();
    let mon = ws;

    let templates = vec![
        make_template_for_grid(1, "Shift Z", 7, 12, "zebra"),
        make_template_for_grid(2, "Shift A", 7, 12, "alpha"),
        make_template_for_grid(3, "Shift M", 7, 12, "middle"),
    ];
    let shifts = vec![
        make_shift_for_grid(1, Some(1), mon, 7, 12, "zebra", 1),
        make_shift_for_grid(2, Some(2), mon, 7, 12, "alpha", 1),
        make_shift_for_grid(3, Some(3), mon, 7, 12, "middle", 1),
    ];
    let employees = vec![make_employee_for_grid(1, "Alice", "Smith")];
    let assignments = vec![
        make_assignment_for_grid(1, 1, 1, None),
        make_assignment_for_grid(2, 2, 1, None),
        make_assignment_for_grid(3, 3, 1, None),
    ];

    let config = staff_config(ExportLayout::ShiftByWeekday);
    let grids = build_grids_by_role(&config, ws, &assignments, &shifts, &employees, &templates);

    let role_names: Vec<&str> = grids.iter().map(|(name, _)| name.as_str()).collect();
    assert_eq!(role_names, vec!["alpha", "middle", "zebra"]);
}

#[test]
fn grids_by_role_wildcard_shows_any_role() {
    let ws = week_start();
    let mon = ws;

    let templates = vec![make_template_for_grid(1, "Flex Shift", 7, 12, "")];
    let shifts = vec![make_shift_for_grid(1, Some(1), mon, 7, 12, "", 1)];
    let employees = vec![make_employee_for_grid(1, "Alice", "Smith")];
    let assignments = vec![make_assignment_for_grid(1, 1, 1, None)];

    let config = staff_config(ExportLayout::EmployeeByWeekday);
    let grids = build_grids_by_role(&config, ws, &assignments, &shifts, &employees, &templates);

    assert_eq!(grids.len(), 1);
    assert_eq!(grids[0].0, "Any Role");
}

// ════════════════════════════════════════════════════════════════════════════
// 2. build_single_employee_grid
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn single_employee_grid_basic() {
    let ws = week_start();
    let mon = ws;

    let templates = vec![make_template_for_grid(1, "Morning", 7, 12, "barista")];
    let shifts = vec![make_shift_for_grid(1, Some(1), mon, 7, 12, "barista", 1)];
    let assignments = vec![make_assignment_for_grid(1, 1, 1, Some(15.0))];

    let dates: Vec<NaiveDate> = (0..7).map(|i| ws + chrono::Duration::days(i)).collect();

    let grid = build_single_employee_grid(
        "Alice Smith",
        &dates,
        &assignments,
        &shifts,
        &templates,
        &default_flags(),
        false,
    );

    assert!(grid.title.contains("Alice Smith"));
    assert!(grid.title.contains("Week of"));
    assert_eq!(grid.column_headers, vec!["Shifts"]);
    // Monday has an assignment
    assert!(!grid.cells[0][0].is_empty());
    assert!(grid.cells[0][0].contains("Morning"));
    // weekly_total_cost should be None for staff mode
    assert!(grid.weekly_total_cost.is_none());
}

#[test]
fn single_employee_grid_7_day_title_format() {
    let ws = week_start();
    let dates: Vec<NaiveDate> = (0..7).map(|i| ws + chrono::Duration::days(i)).collect();

    let grid = build_single_employee_grid(
        "Alice Smith",
        &dates,
        &[],
        &[],
        &[],
        &default_flags(),
        false,
    );

    assert!(
        grid.title.contains("Week of"),
        "7-day range title should say 'Week of', got: {}",
        grid.title
    );
}

#[test]
fn single_employee_grid_non_7_day_title_format() {
    let ws = week_start();
    // Use a 5-day range (not 7)
    let dates: Vec<NaiveDate> = (0..5).map(|i| ws + chrono::Duration::days(i)).collect();

    let grid =
        build_single_employee_grid("Bob Jones", &dates, &[], &[], &[], &default_flags(), false);

    assert!(
        grid.title.contains(" to "),
        "Non-7-day range title should say 'X to Y', got: {}",
        grid.title
    );
    assert!(
        !grid.title.contains("Week of"),
        "Non-7-day range title should NOT say 'Week of', got: {}",
        grid.title
    );
}

#[test]
fn single_employee_grid_manager_mode_includes_cost() {
    let ws = week_start();
    let mon = ws;

    let templates = vec![make_template_for_grid(1, "Morning", 7, 12, "barista")];
    let shifts = vec![make_shift_for_grid(1, Some(1), mon, 7, 12, "barista", 1)];
    // 5 hours at $15/hr = $75
    let assignments = vec![make_assignment_for_grid(1, 1, 1, Some(15.0))];

    let dates: Vec<NaiveDate> = (0..7).map(|i| ws + chrono::Duration::days(i)).collect();

    let grid = build_single_employee_grid(
        "Alice Smith",
        &dates,
        &assignments,
        &shifts,
        &templates,
        &default_flags(),
        true, // is_manager
    );

    assert!(
        grid.cells[0][0].contains("$75.00"),
        "Manager mode should include cost, got: {}",
        grid.cells[0][0]
    );
    assert_eq!(grid.weekly_total_cost, Some(75.0));
}

#[test]
fn single_employee_grid_staff_mode_no_cost() {
    let ws = week_start();
    let mon = ws;

    let templates = vec![make_template_for_grid(1, "Morning", 7, 12, "barista")];
    let shifts = vec![make_shift_for_grid(1, Some(1), mon, 7, 12, "barista", 1)];
    let assignments = vec![make_assignment_for_grid(1, 1, 1, Some(15.0))];

    let dates: Vec<NaiveDate> = (0..7).map(|i| ws + chrono::Duration::days(i)).collect();

    let grid = build_single_employee_grid(
        "Alice Smith",
        &dates,
        &assignments,
        &shifts,
        &templates,
        &default_flags(),
        false, // staff mode
    );

    assert!(
        !grid.cells[0][0].contains('$'),
        "Staff mode should not include cost, got: {}",
        grid.cells[0][0]
    );
    assert!(grid.weekly_total_cost.is_none());
}

#[test]
fn single_employee_grid_empty_day() {
    let ws = week_start();
    let dates: Vec<NaiveDate> = (0..7).map(|i| ws + chrono::Duration::days(i)).collect();

    // No assignments at all
    let grid = build_single_employee_grid(
        "Alice Smith",
        &dates,
        &[],
        &[],
        &[],
        &default_flags(),
        false,
    );

    // All cells should be empty
    for row in &grid.cells {
        assert_eq!(row[0], "");
    }
}

#[test]
fn single_employee_grid_multiple_shifts_same_day() {
    let ws = week_start();
    let mon = ws;

    let templates = vec![
        make_template_for_grid(1, "Morning", 7, 12, "barista"),
        make_template_for_grid(2, "Afternoon", 13, 17, "barista"),
    ];
    let shifts = vec![
        make_shift_for_grid(1, Some(1), mon, 7, 12, "barista", 1),
        make_shift_for_grid(2, Some(2), mon, 13, 17, "barista", 1),
    ];
    let assignments = vec![
        make_assignment_for_grid(1, 1, 1, None),
        make_assignment_for_grid(2, 2, 1, None),
    ];

    let dates: Vec<NaiveDate> = (0..7).map(|i| ws + chrono::Duration::days(i)).collect();

    let grid = build_single_employee_grid(
        "Alice Smith",
        &dates,
        &assignments,
        &shifts,
        &templates,
        &default_flags(),
        false,
    );

    let monday_cell = &grid.cells[0][0];
    assert!(
        monday_cell.contains("Morning"),
        "Should contain Morning shift"
    );
    assert!(
        monday_cell.contains("Afternoon"),
        "Should contain Afternoon shift"
    );
    assert!(
        monday_cell.contains('\n'),
        "Multiple shifts should be joined by newline"
    );
}

#[test]
fn single_employee_grid_ad_hoc_shift_fallback() {
    let ws = week_start();
    let mon = ws;

    let templates: Vec<autorota_core::models::shift::ShiftTemplate> = vec![];
    // Ad-hoc shift with no template
    let shifts = vec![make_shift_for_grid(1, None, mon, 14, 18, "server", 1)];
    let assignments = vec![make_assignment_for_grid(1, 1, 1, None)];

    let dates: Vec<NaiveDate> = (0..7).map(|i| ws + chrono::Duration::days(i)).collect();

    let grid = build_single_employee_grid(
        "Alice Smith",
        &dates,
        &assignments,
        &shifts,
        &templates,
        &default_flags(),
        false,
    );

    let monday_cell = &grid.cells[0][0];
    assert!(
        monday_cell.contains("server 14:00-18:00"),
        "Ad-hoc shift should fall back to 'Role HH:MM-HH:MM' format, got: {}",
        monday_cell
    );
}

// ════════════════════════════════════════════════════════════════════════════
// 3. export_week_schedule (async, DB integration)
// ════════════════════════════════════════════════════════════════════════════

/// Seed the database with a full week's worth of data and return the rota ID.
async fn seed_full_week(pool: &sqlx::SqlitePool) -> i64 {
    let ws = week_start();

    // Insert roles
    seed_roles(pool, &["barista"]).await;

    // Insert employees
    let emp = EmployeeBuilder::new("Alice")
        .id(1)
        .last_name("Smith")
        .role("barista")
        .wage(15.0, "usd")
        .available(AvailabilityState::Yes)
        .start_date(ws)
        .build();
    seed_employees(pool, &[emp]).await;

    // Insert shift template
    let tmpl = ShiftTemplateBuilder::new("Morning")
        .id(1)
        .weekdays(&[Weekday::Mon, Weekday::Tue])
        .times(7, 12)
        .role("barista")
        .capacity(1, 2)
        .build();
    seed_templates(pool, &[tmpl]).await;

    // Create rota and materialise shifts
    let rota_id = queries::insert_rota(pool, ws).await.unwrap();
    let shifts = queries::materialise_shifts(pool, rota_id, ws)
        .await
        .unwrap();

    // Create assignments for each materialised shift (employee 1 = Alice)
    for shift in &shifts {
        let assignment = AssignmentBuilder::new(shift.id, 1)
            .rota(rota_id)
            .confirmed()
            .wage(15.0)
            .name("Alice Smith")
            .build();
        queries::insert_assignment(pool, &assignment).await.unwrap();
    }

    rota_id
}

#[tokio::test]
async fn export_week_csv() {
    let pool = test_pool().await;
    seed_full_week(&pool).await;

    let config = ExportConfigBuilder::staff()
        .format(ExportFormat::Csv)
        .layout(ExportLayout::EmployeeByWeekday)
        .build();

    let result = export_week_schedule(&pool, week_start(), config)
        .await
        .unwrap();

    assert!(
        result.filename.ends_with(".csv"),
        "Filename should end with .csv: {}",
        result.filename
    );
    assert_eq!(result.mime_type, "text/csv");
    // CSV should contain the employee name
    assert!(
        result.data.contains("Alice Smith"),
        "CSV should contain employee name"
    );
    // CSV should have header row with day names
    assert!(
        result.data.contains("Mon"),
        "CSV should contain day headers"
    );
}

#[tokio::test]
async fn export_week_json() {
    let pool = test_pool().await;
    seed_full_week(&pool).await;

    let config = ExportConfigBuilder::staff()
        .format(ExportFormat::Json)
        .layout(ExportLayout::EmployeeByWeekday)
        .build();

    let result = export_week_schedule(&pool, week_start(), config)
        .await
        .unwrap();

    assert!(
        result.filename.ends_with(".json"),
        "Filename should end with .json: {}",
        result.filename
    );
    assert_eq!(result.mime_type, "application/json");
    // Should be valid JSON
    let parsed: serde_json::Value =
        serde_json::from_str(&result.data).expect("Export data should be valid JSON");
    // Should contain metadata and rows
    assert!(
        parsed.get("metadata").is_some(),
        "JSON should contain metadata"
    );
    assert!(parsed.get("rows").is_some(), "JSON should contain rows");
    assert!(
        parsed.get("columns").is_some(),
        "JSON should contain columns"
    );
    // Verify metadata fields
    assert_eq!(parsed["metadata"]["week_start"], "2026-03-23");
    assert_eq!(parsed["metadata"]["layout"], "employee_by_weekday");
    assert_eq!(parsed["metadata"]["profile"], "staff_schedule");
}

#[tokio::test]
async fn export_week_pdf() {
    let pool = test_pool().await;
    seed_full_week(&pool).await;

    let config = ExportConfigBuilder::staff()
        .format(ExportFormat::Pdf)
        .layout(ExportLayout::EmployeeByWeekday)
        .build();

    let result = export_week_schedule(&pool, week_start(), config)
        .await
        .unwrap();

    assert!(
        result.filename.ends_with(".pdf"),
        "Filename should end with .pdf: {}",
        result.filename
    );
    assert_eq!(result.mime_type, "application/pdf");
    // Data is base64-encoded PDF
    let bytes = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &result.data)
        .expect("Should be valid base64");
    // PDF magic bytes: %PDF
    assert!(
        bytes.starts_with(b"%PDF"),
        "Decoded data should start with PDF magic bytes"
    );
}

#[tokio::test]
async fn export_week_no_schedule_error() {
    let pool = test_pool().await;
    // Don't seed any data — no rota exists for this week

    let config = ExportConfigBuilder::staff()
        .format(ExportFormat::Csv)
        .build();

    let nonexistent_week = NaiveDate::from_ymd_opt(2099, 1, 6).unwrap();
    let err = export_week_schedule(&pool, nonexistent_week, config)
        .await
        .unwrap_err();

    assert!(
        matches!(err, ExportError::NoSchedule(_)),
        "Should return NoSchedule error, got: {err:?}"
    );
}

// ════════════════════════════════════════════════════════════════════════════
// 4. export_employee_schedule (async, DB integration)
// ════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn export_employee_csv() {
    let pool = test_pool().await;
    seed_full_week(&pool).await;

    let ws = week_start();
    let end = ws + chrono::Duration::days(6);

    let config = EmployeeExportConfig {
        employee_id: 1,
        format: ExportFormat::Csv,
        profile: ExportProfile::StaffSchedule,
        cell_content: CellContentFlags {
            show_shift_name: true,
            show_times: true,
            show_role: false,
        },
        timezone_id: None,
    };

    let result = export_employee_schedule(&pool, 1, ws, end, config)
        .await
        .unwrap();

    assert!(
        result.filename.ends_with(".csv"),
        "Filename should end with .csv: {}",
        result.filename
    );
    assert_eq!(result.mime_type, "text/csv");
    assert!(
        result.filename.contains("alice-smith"),
        "Filename should contain employee name slug: {}",
        result.filename
    );
    // CSV content should include shift data
    assert!(
        result.data.contains("Morning"),
        "CSV should contain shift name"
    );
}

#[tokio::test]
async fn export_employee_not_found_error() {
    let pool = test_pool().await;
    // Seed the week so we have a valid rota, but use a nonexistent employee ID

    let ws = week_start();
    let end = ws + chrono::Duration::days(6);

    let config = EmployeeExportConfig {
        employee_id: 99999,
        format: ExportFormat::Csv,
        profile: ExportProfile::StaffSchedule,
        cell_content: CellContentFlags {
            show_shift_name: true,
            show_times: true,
            show_role: false,
        },
        timezone_id: None,
    };

    let err = export_employee_schedule(&pool, 99999, ws, end, config)
        .await
        .unwrap_err();

    assert!(
        matches!(err, ExportError::EmployeeNotFound(99999)),
        "Should return EmployeeNotFound error, got: {err:?}"
    );
}

#[tokio::test]
async fn export_employee_json() {
    let pool = test_pool().await;
    seed_full_week(&pool).await;

    let ws = week_start();
    let end = ws + chrono::Duration::days(6);

    let config = EmployeeExportConfig {
        employee_id: 1,
        format: ExportFormat::Json,
        profile: ExportProfile::StaffSchedule,
        cell_content: CellContentFlags {
            show_shift_name: true,
            show_times: true,
            show_role: false,
        },
        timezone_id: None,
    };

    let result = export_employee_schedule(&pool, 1, ws, end, config)
        .await
        .unwrap();

    assert!(result.filename.ends_with(".json"));
    assert_eq!(result.mime_type, "application/json");
    let parsed: serde_json::Value =
        serde_json::from_str(&result.data).expect("Export data should be valid JSON");
    // Employee JSON should have employee-related metadata
    assert!(
        result.data.contains("Alice Smith"),
        "JSON should contain employee name"
    );
    assert!(parsed.is_object(), "JSON should be an object");
}

#[tokio::test]
async fn export_employee_pdf() {
    let pool = test_pool().await;
    seed_full_week(&pool).await;

    let ws = week_start();
    let end = ws + chrono::Duration::days(6);

    let config = EmployeeExportConfig {
        employee_id: 1,
        format: ExportFormat::Pdf,
        profile: ExportProfile::StaffSchedule,
        cell_content: CellContentFlags {
            show_shift_name: true,
            show_times: true,
            show_role: false,
        },
        timezone_id: None,
    };

    let result = export_employee_schedule(&pool, 1, ws, end, config)
        .await
        .unwrap();

    assert!(result.filename.ends_with(".pdf"));
    assert_eq!(result.mime_type, "application/pdf");
    let bytes = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &result.data)
        .expect("Should be valid base64");
    assert!(
        bytes.starts_with(b"%PDF"),
        "Decoded data should start with PDF magic bytes"
    );
}

#[tokio::test]
async fn export_week_manager_report_csv_includes_cost() {
    let pool = test_pool().await;
    seed_full_week(&pool).await;

    let config = ExportConfigBuilder::manager()
        .format(ExportFormat::Csv)
        .layout(ExportLayout::EmployeeByWeekday)
        .build();

    let result = export_week_schedule(&pool, week_start(), config)
        .await
        .unwrap();

    assert!(result.filename.contains("manager_report"));
    // Manager CSV should include cost figures
    assert!(
        result.data.contains("$"),
        "Manager report should include dollar amounts in cells"
    );
}
