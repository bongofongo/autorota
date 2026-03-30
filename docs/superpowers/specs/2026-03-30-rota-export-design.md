# Rota Export Feature — Design Spec

## Context

Cafe managers need to share weekly schedules with staff and use them in external tools (spreadsheets, print). Currently there is no export functionality. This feature adds CSV and JSON export of weekly rotas, with the architecture designed so PDF rendering can be added later (Swift-side, using the same structured data from Rust).

## Requirements

- **Formats:** CSV, JSON (PDF deferred to future work)
- **Layouts:** Employee x Weekday grid, Shift x Weekday grid
- **Profiles:** "Staff Schedule" (no wages), "Manager Report" (with wages/costs)
- **Cell content:** Configurable — shift name, times, role (any combination)
- **Architecture:** Rust generates export data/files; Swift handles native share sheet and (future) PDF rendering
- **UI:** Export button on rota view, export default preferences in settings/menu

---

## 1. Rust Core — New `export` Module

**Location:** `crates/autorota-core/src/export/`

Register in `crates/autorota-core/src/lib.rs` as `pub mod export;`.

### Types (`config.rs`)

```rust
pub enum ExportLayout { EmployeeByWeekday, ShiftByWeekday }
pub enum ExportFormat { Csv, Json }
pub enum ExportProfile { StaffSchedule, ManagerReport }

pub struct CellContentFlags {
    pub show_shift_name: bool,
    pub show_times: bool,
    pub show_role: bool,
}

pub struct ExportConfig {
    pub layout: ExportLayout,
    pub format: ExportFormat,
    pub profile: ExportProfile,
    pub cell_content: CellContentFlags,
}

pub struct ExportResult {
    pub data: String,
    pub filename: String,
    pub mime_type: String,
}
```

### Grid Builder (`grid.rs`)

Intermediate representation consumed by both serializers:

```rust
pub struct ExportGrid {
    pub title: String,              // "Staff Schedule — Week of 2026-03-23"
    pub column_headers: Vec<String>, // ["Mon 23 Mar", "Tue 24 Mar", ...]
    pub row_headers: Vec<String>,    // employee names or shift labels
    pub cells: Vec<Vec<String>>,     // cells[row][col]
    pub daily_totals: Option<Vec<DaySummary>>,  // ManagerReport only
    pub weekly_total_cost: Option<f32>,          // ManagerReport only
}
```

**EmployeeByWeekday algorithm:**
1. Collect unique employees from assignments, sorted by display_name
2. Columns = Mon–Sun with date labels
3. For each (employee, weekday): find assignments, build cell text from flags
4. Multiple shifts on same day → newline-separated in cell
5. ManagerReport: append cost, compute daily/weekly totals

**ShiftByWeekday algorithm:**
1. Collect unique shift slots (start_time, end_time, role), sorted by start_time
2. Row headers = shift template name (or "role start–end" for ad-hoc shifts)
3. For each (shift slot, weekday): list assigned employee names
4. Unfilled slots marked as "(unfilled)"
5. ManagerReport: include per-employee cost

**Shift name resolution:** Join to `ShiftTemplate` via `template_id`. Ad-hoc shifts (no template) fall back to "role start–end" format.

### CSV Serializer (`csv.rs`)

- RFC 4180 compliant (quote cells with commas/newlines/quotes, escape `"` as `""`)
- Header row: blank + column headers
- Data rows: row header + cells
- ManagerReport: appended totals row
- No external crate needed

### JSON Serializer (`json.rs`)

Uses `serde_json` (already in workspace). Structure:

```json
{
  "metadata": {
    "week_start": "2026-03-23",
    "layout": "employee_by_weekday",
    "profile": "staff_schedule",
    "generated_at": "2026-03-30T12:00:00"
  },
  "columns": ["Mon 23 Mar", ...],
  "rows": [
    { "header": "Alice Smith", "cells": ["Morning (09:00-17:00)", "", ...] }
  ],
  "totals": null
}
```

### Entry Point (`mod.rs`)

```rust
pub async fn export_week_schedule(
    pool: &SqlitePool,
    week_start: NaiveDate,
    config: ExportConfig,
) -> Result<ExportResult, ExportError>
```

Steps:
1. Fetch rota via existing `get_rota_by_week`
2. Fetch shifts, employees, shift templates (reuse existing query functions)
3. Build `ExportGrid` via `grid::build_grid`
4. Serialize to CSV or JSON
5. Return `ExportResult` with data, filename (`rota-{date}-{layout}-{profile}.{ext}`), mime type

Error type:
```rust
pub enum ExportError {
    Db(sqlx::Error),
    NoSchedule(String),
}
```

---

## 2. FFI Layer

**File:** `crates/autorota-ffi/src/types.rs`

```rust
#[derive(Clone, uniffi::Record)]
pub struct FfiExportConfig {
    pub layout: String,         // "employee_by_weekday" | "shift_by_weekday"
    pub format: String,         // "csv" | "json"
    pub profile: String,        // "staff_schedule" | "manager_report"
    pub show_shift_name: bool,
    pub show_times: bool,
    pub show_role: bool,
}

#[derive(Clone, uniffi::Record)]
pub struct FfiExportResult {
    pub data: String,
    pub filename: String,
    pub mime_type: String,
}
```

**File:** `crates/autorota-ffi/src/lib.rs`

New exported function `export_week_schedule(week_start: String, config: FfiExportConfig) -> Result<FfiExportResult, FfiError>` with a `parse_export_config` helper to convert string enums to core types.

---

## 3. Swift Layer

### Service Protocol

Add to `AutorotaServiceProtocol`:
```swift
func exportWeekSchedule(weekStart: String, config: FfiExportConfig) async throws -> FfiExportResult
```

Implement in `LiveAutorotaService` (wraps FFI call via `Task.detached`).

### Export Sheet View (new: `Views/ExportSheetView.swift`)

Presented as a `.sheet` from the rota view:
- Segmented picker: layout (By Employee / By Shift)
- Segmented picker: format (CSV / JSON)
- Segmented picker: profile (Staff / Manager)
- Toggles: shift name, times, role
- "Export" button → calls service → writes to temp file → presents `UIActivityViewController`

Initial values populated from `@AppStorage` defaults.

### Rota View Integration

**File:** `Views/RotaView.swift`

Add toolbar button (`square.and.arrow.up` SF Symbol) conditioned on `vm.schedule != nil`. Tapping presents the export sheet.

### Settings/Menu — Export Defaults

**File:** `Views/SettingsView.swift`

New "Export Defaults" section with:

| @AppStorage Key | Type | Default |
|---|---|---|
| `exportDefaultLayout` | String | `"employee_by_weekday"` |
| `exportDefaultProfile` | String | `"staff_schedule"` |
| `exportDefaultFormat` | String | `"csv"` |
| `exportShowShiftName` | Bool | `true` |
| `exportShowTimes` | Bool | `true` |
| `exportShowRole` | Bool | `true` |

---

## 4. Implementation Order

| Phase | Work | Key Files |
|---|---|---|
| 1 | Rust export module + tests | `crates/autorota-core/src/export/{mod,config,grid,csv,json}.rs` |
| 2 | FFI types + function | `crates/autorota-ffi/src/{types,lib}.rs` |
| 3 | Swift service wrappers | `AutorotaKit.swift`, `AutorotaServiceProtocol.swift`, `LiveAutorotaService.swift` |
| 4 | Swift UI (export sheet, rota button, settings) | `ExportSheetView.swift`, `RotaView.swift`, `SettingsView.swift` |

---

## 5. Testing

- **Rust unit tests:** Grid building with hand-constructed data (both layouts). CSV escaping edge cases. JSON structure validation via `serde_json::from_str` round-trip.
- **Rust integration tests:** In-memory SQLite with seeded data → `export_week_schedule` → verify output for all config combinations. Test NoSchedule error.
- **FFI tests:** `parse_export_config` with valid/invalid inputs. End-to-end FFI call.
- **Swift ViewModel tests:** Mock service returning canned `FfiExportResult`. Verify config construction from UI state.

---

## 6. Future: PDF Export

When ready, PDF rendering will use the same `FfiExportResult` JSON data (or a dedicated structured format). Swift renders it with `UIGraphicsPDFRenderer` / `PDFKit` for native quality. The Rust data pipeline built here will be reused as-is.
