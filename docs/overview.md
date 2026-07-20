# Autorota — Project Overview

Single source of truth for the project's architecture, features,
organisation, testing, and CI/CD state. Re-read before changing anything
load-bearing; everything else in `docs/` is either narrower-scoped
(feature specs) or historical (brainstorming, implemented plans).

---

## 1. Product Summary

Autorota is a multi-platform cafe shift-scheduling app. A manager defines
shifts (weekday slots with capacity and optional role). Employees hold
roles and publish weekly availability. The scheduler produces a weekly
rota, which the manager can edit, save, export, and sync across their
Apple devices via iCloud.

## 2. Repository Layout

```
autorota/
├── Cargo.toml                     # workspace manifest
├── crates/
│   ├── autorota-core/             # scheduling engine, db, export
│   ├── autorota-ffi/              # UniFFI bindings for Swift/Kotlin
│   ├── uniffi-bindgen/            # bindgen CLI binary (uniffi 0.28)
│   └── app-desktop/               # Tauri v2 desktop app (Rust + vanilla TS)
├── platforms/
│   └── apple/
│       ├── AutorotaKit/           # SPM package wrapping the XCFramework
│       ├── Apps/AutorotaApp/      # Xcode project (iOS/iPadOS/macOS)
│       ├── ExportOptions.plist
│       ├── ExportOptions-MacAppStore.plist
│       └── ExportOptions-DeveloperID.plist
├── scripts/
│   └── build_xcframework.sh       # per-SDK cargo build → XCFramework
├── docs/
│   ├── overview.md                # (this file)
│   ├── specs/                     # current-behaviour specs
│   ├── superpowers/plans/         # historical implementation plans
│   └── superpowers/specs/         # historical design specs
├── .github/workflows/             # CI/CD
├── Makefile                       # dev-command entry points
├── deny.toml                      # cargo-deny policy
├── CLAUDE.md                      # Claude Code conventions
├── AGENTS.md                      # agent conventions
├── GAPS.md                        # known gaps
├── BUG_LIST.md                    # open bugs
├── TODO_LIST.md                   # open work items
├── brainstorming.md               # historical
└── revised_brainstorming.md       # historical (cleaned)
```

## 3. Architecture

### 3.1 Rust Workspace

**`autorota-core`** — Pure Rust library. No FFI, no UI.
- `models/` — domain types: `employee`, `role`, `shift`, `rota`,
  `assignment`, `availability`, `overrides`, `save`, `shift_history`,
  `sync`.
- `db/` — sqlx connection pool, query helpers (`queries.rs`), migration
  runner. 20 numbered migrations under `migrations/`, auto-applied on
  init. Each migration is guarded by a runtime `sqlite_master` check so
  re-runs are safe.
- `scheduler/` — two-pass greedy algorithm. Pass 1 applies manual
  overrides. Pass 2 assigns remaining shifts hardest-to-fill-first,
  using `scoring.rs` (availability quality, hour budget, fairness) and
  `tiebreak.rs` (deterministic hash-based tie-breaking).
- `export/` — export pipeline. `config.rs` defines `ExportLayout`,
  `ExportFormat` (CSV/JSON/PDF), `ExportProfile` (staff/manager),
  `CellContentFlags`. `grid.rs` produces a shared intermediate
  `ExportGrid`; `csv.rs` and `json.rs` serialize it; `pdf/` (`mod`,
  `weekly`, `by_role`, `employee`, `employee_schedule`, `theme`) renders
  via pdf crate.
- `exchange/` — data-bundle exchange. Versioned JSON `DataBundle` with
  optional sections (roles, employees incl. weekly availability,
  employee availability exceptions, shift templates incl. role
  requirements, shift template exceptions). `export_data_bundle` writes
  any subset; `inspect_data_bundle` returns per-section counts for the
  import-confirmation UI; `import_data_bundle` upserts by name (never
  deletes), auto-creates referenced roles, and warns on unmatched
  exception references.
- `testutil/` — `assertions.rs`, `builders.rs`, `db.rs` test helpers
  shared by integration tests.

**`autorota-ffi`** — UniFFI 0.28 wrapper.
- `types.rs` — FFI-safe mirror types (`FfiEmployee`, `FfiShift`,
  `FfiAssignment`, `FfiWeekSchedule`, `FfiSave`, `FfiSyncRecord`, …).
  Dates/times/weekdays are strings (`YYYY-MM-DD`, `HH:MM`, `"Mon"`...).
- `lib.rs` — ~50 `pub fn` exports grouped by domain: employees, roles,
  shift templates, rotas + scheduling, assignments, overrides, saves,
  sync, availability progress, export. Single global Tokio runtime and
  SQLite pool in a `OnceLock`.

**`uniffi-bindgen`** — Standalone CLI binary used by
`scripts/build_xcframework.sh` to generate Swift bindings from the
compiled `autorota-ffi` dylib.

**`app-desktop`** — Tauri v2 desktop app.
- `src-tauri/src/lib.rs` — ~30 `tauri::command` handlers wrapping
  `autorota-core` calls, sharing a sqlx pool via `AppState`.
- `src/main.ts` — vanilla TypeScript (no framework), direct DOM + Tauri
  `invoke`. Vite dev server on :5173. Mirrors a subset of
  `autorota-core` types as TS interfaces.

### 3.2 Apple Platform

**`AutorotaKit`** (SPM package):
- `Sources/AutorotaKit/AutorotaKit.swift` — public async wrappers around
  the generated bindings (each call `Task.detached`s onto a background
  thread so Rust never blocks the main actor).
- `Sources/AutorotaKit/generated/autorota_ffi.swift` — auto-generated
  UniFFI Swift bindings.
- The package ships an XCFramework artifact built by
  `scripts/build_xcframework.sh` for `aarch64-apple-darwin`,
  `x86_64-apple-darwin`, `aarch64-apple-ios`, and
  `aarch64-apple-ios-sim`.

**`AutorotaApp`** (Xcode project, iOS/iPadOS/macOS):
- `AutorotaAppApp.swift` — `@main` app entry. Runs `autorotaInitDb()`,
  instantiates `ExchangeRateService` and `AutorotaSyncEngine`, handles
  the first-launch sync prompt.
- `Views/` — 23 SwiftUI screens. Core: `ContentView`, `RotaView`,
  `EmployeeListView`, `EmployeeDetailView`, `ShiftTemplateListView`,
  `OverridesTabView`, `EditLogView`, `AnalyticsView`, `ExportTabView`,
  `SettingsView`, `OnboardingView`, `SyncPromptView`, `HelpView`.
  Availability: `AvailabilityGridView`,
  `AllAvailabilitiesSetView`, `WeeklyAvailabilityView`,
  `CarouselAvailabilityView`. Navigation plumbing: `TabPage`,
  `RotaUIBridge`, `EmployeeUIBridge`, `RotaOverflowPopover`.
  Export: `ExportSheetView`. History: `EmployeeShiftHistoryView`.
- `ViewModels/` — 10 `@Observable` view models (`RotaViewModel`,
  `EmployeeViewModel`, `EmployeeExportViewModel`, `ShiftTemplateViewModel`,
  `AnalyticsViewModel`, `AvailabilityProgressViewModel`,
  `EditLogViewModel`, `OverrideViewModel`, `RoleViewModel`,
  `ShiftHistoryViewModel`).
- `Services/` — infrastructure layer:
  - `AutorotaServiceProtocol` — interface all view models consume.
  - `LiveAutorotaService` — production. Wraps FFI calls; posts
    `Notification.Name.autorotaDataChanged` on mutations so views refresh.
  - `AutorotaSyncEngine` — `CKSyncEngineDelegate` implementation for
    iCloud sync.
  - `SyncRecordMapper` — `FfiSyncRecord` ↔ `CKRecord` field mapping.
  - `SyncConflictResolver` — three-way per-field merge (base vs local
    vs server).
  - `ExchangeRateService` — fetches rates from `api.frankfurter.dev`
    with 24-hour cache for multi-currency wage display.
  - `FfiError+UserMessage` — maps typed FFI errors to user-facing strings.
- `AutorotaApp.entitlements` — CloudKit container
  `iCloud.com.toadmountain.autorota`; background-modes for remote
  notifications.
- `Assets.xcassets` — AppIcon, AccentColor.
- Deployment targets: iOS/iPadOS 26.2, macOS 26.1, visionOS 26.2
  (Xcode 26 baseline).

## 4. Core Features

| Area | Where |
|------|-------|
| Employee CRUD, roles, wages, availability template | `EmployeeListView`, `EmployeeDetailView`, `EmployeeViewModel` |
| Shift template CRUD (weekly recurring shifts, wildcard roles, capacity) | `ShiftTemplateListView`, `ShiftTemplateViewModel` |
| Availability editing (hour-grid, carousel, weekly) | `AvailabilityGridView` + siblings |
| Overrides / Exceptions (per-date availability + shift overrides) | `OverridesTabView`, `OverrideViewModel` |
| Weekly rota generation (two-pass greedy) | `RotaView`, `RotaViewModel` → `run_schedule` FFI |
| Rota editing: move, swap, delete, ad-hoc shift, update times | `RotaViewModel` |
| Auto-save → Edit Log with labels, diff expansion, restore | `EditLogView`, `EditLogViewModel`, saves FFI |
| Per-employee shift history | `EmployeeShiftHistoryView`, `ShiftHistoryViewModel` |
| Analytics (totals, costs, charts) | `AnalyticsView`, `AnalyticsViewModel` |
| Export CSV / JSON / PDF (staff vs manager profiles; employee-by-weekday vs shift-by-weekday; weekly, by-role, per-employee PDFs) | `ExportTabView`, `ExportSheetView`, `EmployeeExportViewModel`, `autorota-core/export/*` |
| Data bundle export/import (Employees & Shifts pages; whole page or single category — roles, employees, availability exceptions, shifts, shift changes) | `DataBundleTransferView` (`DataBundleToolbarMenu`, `DataBundleImportView`), `autorota-core/exchange/*` |
| iCloud sync (private database, per-field merge, first-launch prompt) | `AutorotaSyncEngine`, `SyncConflictResolver`, `SyncRecordMapper`, `SyncPromptView` |
| Onboarding | `OnboardingView` |
| Demo mode (guided pre-purchase tour on a throwaway seeded DB; planet-crew sample data; spotlight coach marks with per-step sub-sequences on iPhone/iPad — the app's only interactive teaching, TipKit was removed in favour of it) | `DemoModeController`, `DemoBanner`, `TutorialSpotlight`, `autorota-core/demo.rs`, `switch_db`/`seed_demo_db` FFI |
| Availability grid bulk editing (sticky lasso toggle → drag selection; hold-then-drag activation shelved, see `docs/availability-hold-drag-lasso.md`) | `AvailabilityGridView` |
| Configurable tab bar + Menu overflow | `TabPage`, `TabLayoutManager`, `SettingsView` |
| Rota-page overflow menu (Delete / Edit / Share / Generate) | `RotaOverflowPopover`, spec in `docs/specs/rota-overflow-menu.md` |

### Key Data Semantics

- **Assignment status** — `Proposed | Confirmed | Overridden`. Status is
  never auto-promoted; manual edits create `Overridden` rows.
- **Soft delete** — employees and shift templates have a `deleted` flag
  so historical assignments still resolve names/wages.
- **Snapshot on assignment** — creating an assignment copies the
  employee's name and wage so later edits don't rewrite the past.
- **Saves** (migration 016 renamed from `commits`) — full-rota snapshots
  with optional `label` (017 renamed `committed_at` → `saved_at`),
  `save_tags` (018), and `restored_at` (019). Diffs are computed in Rust
  (`diff_rota_detailed`, `diff_save_vs_previous`, `diff_saves_detailed`).
- **Sync tables** (migration 011) — every domain table carries
  `last_modified`, `sync_status`, `sync_base_snapshot`. Deletions go
  into `sync_tombstones`. `sync_metadata` holds the CKSyncEngine
  server-change token and device id.
- **Override source** (migration 020) — overrides carry a `source`
  discriminator so per-date edits can be traced back to whether they
  came from the UI or a bulk action.

## 5. Database Migrations

Stored under `crates/autorota-core/migrations/`. All are auto-applied on
`init_db` in numeric order, each guarded by a runtime schema check.

| # | File | Change |
|---|------|--------|
| 001 | `001_initial.sql` | Base tables: employees, shift_templates, rotas, shifts, assignments |
| 002 | `002_weekdays_and_cascade.sql` | Rename weekday→weekdays; add ON DELETE CASCADE |
| 003 | `003_employee_work_prefs.sql` | Start date, weekly hours + deviation, notes, bank details |
| 004 | `004_history_support.sql` | Soft-delete flags; snapshot employee_name on assignment |
| 005 | `005_nullable_template_id.sql` | `shifts.template_id` nullable (ad-hoc shifts) |
| 006 | `006_roles_table.sql` | Roles table (id, name UNIQUE) |
| 007 | `007_employee_name_split.sql` | Split name → first_name/last_name/nickname |
| 008 | `008_overrides.sql` | Employee availability + shift template override tables |
| 009 | `009_employee_wages.sql` | Hourly wage on employees |
| 010 | `010_employee_wage_currency.sql` | Wage currency code |
| 011 | `011_sync_support.sql` | last_modified / sync_status / sync_base_snapshot on 8 tables; sync_metadata + sync_tombstones tables |
| 012 | `012_staging_commits.sql` | staged_shifts + commits tables (commits later renamed) |
| 013 | `013_perf_indexes.sql` | Performance indexes |
| 014 | `014_availability_progress.sql` | Per-employee availability progress tracking |
| 015 | `015_remove_finalized_staging.sql` | Drop finalized_staging column |
| 016 | `016_rename_commits_to_saves.sql` | `commits` → `saves`; add label |
| 017 | `017_rename_committed_at_to_saved_at.sql` | `committed_at` → `saved_at` |
| 018 | `018_save_tags.sql` | save_tags table |
| 019 | `019_save_restored_at.sql` | `restored_at` column on saves |
| 020 | `020_override_source.sql` | `source` discriminator on overrides |

## 6. Testing

### Rust

- `crates/autorota-core/tests/` — integration tests against a temporary
  SQLite file via `testutil`.
  - `db_integration.rs`
  - `scheduler_integration_test.rs`, `scheduler_test.rs`
  - `edge_cases_test.rs`
  - `queries_coverage_test.rs`
  - `export_test.rs` (CSV/JSON/grid end-to-end; PDF exercised only
    through happy paths)
  - `helpers/mod.rs`
- Unit `#[cfg(test)]` modules live inside the source files
  (`export/*.rs`, `models/*.rs`, `scheduler/scoring.rs`,
  `scheduler/tiebreak.rs`).
- Command: `cargo test` from the workspace root.

### Swift — AutorotaKit SPM

- `platforms/apple/AutorotaKit/Tests/AutorotaKitTests/`
  - `IntegrationTests.swift` — drives the real FFI against an in-memory
    SQLite.
  - `HelperTests.swift`
  - `Fixtures.swift`
- Requires the XCFramework to be built first
  (`make swift-build-xcframework`).
- Command: `make swift-test-package`.

### Swift — AutorotaApp

- `platforms/apple/Apps/AutorotaApp/AutorotaAppTests/` — ViewModel unit
  tests using `MockAutorotaService` (no FFI required).
  - `AnalyticsViewModelTests`, `RotaViewModelTests`,
    `ShiftTemplateViewModelTests`, `EmployeeViewModelTests`,
    `EditLogViewModelTests`, `RoleViewModelTests`.
  - `MockAutorotaService.swift` — in-memory test double.
- Commands: `make swift-test-app-macos | swift-test-app-ios |
  swift-test-app-ipad`.

### Uncovered areas

Tracked in `GAPS.md §Test coverage gaps`:
- `autorota-ffi` type-conversion / error paths
- Tauri command handlers (`app-desktop`)
- Apple sync services (`AutorotaSyncEngine`, `SyncConflictResolver`,
  `SyncRecordMapper`)
- UI / snapshot tests for SwiftUI
- PDF rendering details per template

## 7. CI/CD

All workflows live in `.github/workflows/`:

### `ci.yml` — push to `main` + PRs (concurrency-cancelling)
- **rust-checks** (reusable) — `cargo fmt --check`, `cargo clippy -D
  warnings`, unit tests, integration tests for `autorota-core`.
- **xcframework** (`macos-26`) — builds the XCFramework with
  `PERF_HELPERS=1` (Debug app builds link `seedPerfCorpus`) and uploads
  it + generated bindings as artifacts.
- **swift-package-tests** (`macos-26`) — SPM integration tests that
  download the XCFramework artifact and call the real FFI.
- **swift-compile-check** (`macos-26`, matrix macOS/iOS/iPadOS) —
  compile-only via `make swift-build-check-<target>`.
- Tauri desktop is deliberately not in CI (pre-existing compile failures;
  see the comment in `ci.yml`).

### `perf.yml` — PRs + manual dispatch (never blocks merge)
Criterion benches with a soft same-runner merge-base comparison, the Kit
FFI perf suite, and (scheduled/dispatch) the XCUITest perf run. All
report-only — see `perf-testing.md` and `perf-runbook.md`.

### `rust-checks.yml` — reusable
Called by `ci.yml` and `release.yml`. Pure-Rust gate (fmt, clippy, unit
tests, integration tests) using `dtolnay/rust-toolchain@stable`.

### `supply-chain.yml`
- Triggers: `Cargo.lock` / `deny.toml` changes, weekly Monday 06:00
  UTC, manual dispatch.
- Jobs: `cargo audit` (`rustsec/audit-check`), `cargo deny check`
  (`EmbarkStudios/cargo-deny-action`). Policy lives in `deny.toml`
  (MIT/Apache-2.0/BSD/ISC/Zlib/CC0/MPL-2.0/OpenSSL/Unicode allowed,
  multiple-versions warn, crates.io-only sources).

### `release.yml` — tag `v*.*.*`
- **tag-parse** — extracts version from the tag; `build_number` =
  `github.run_number`.
- **rust-checks** — reusable gate.
- **release-ios** — archives the iOS scheme, uploads to TestFlight via
  App Store Connect API key (`ExportOptions.plist`, team `34VGHNCG6J`).
- **release-macos** — parallel:
  - Mac App Store path (`ExportOptions-MacAppStore.plist`).
  - Developer ID path (`ExportOptions-DeveloperID.plist`) — archive,
    export, `xcrun notarytool submit --wait`, `stapler`, DMG output.
- **publish** — downloads the DMG artifact, creates a GitHub Release
  with it attached.

### Signing / release assets

- `platforms/apple/ExportOptions.plist` — iOS App Store Connect.
- `platforms/apple/ExportOptions-MacAppStore.plist` — Mac App Store.
- `platforms/apple/ExportOptions-DeveloperID.plist` — Developer ID
  direct-download DMG.
- Must be kept aligned with the signing certificates and team ID.

## 8. Dev Commands

```bash
# Rust
cargo fmt && cargo clippy && cargo test

# Apple — XCFramework first
make swift-build-xcframework          # release
make swift-build-xcframework-debug    # debug (faster iteration)

# Apple — compile checks
make swift-build-check-macos
make swift-build-check-ios
make swift-build-check-ipad
make swift-build-check                # all three

# Apple — tests
make swift-test-app-macos             # ViewModel tests (mock service)
make swift-test-app-ios
make swift-test-app-ipad
make swift-test-package               # SPM integration (needs XCFramework)
make test-all                         # everything

# Tauri desktop
cd crates/app-desktop && npm ci && npm run tauri dev
```

`VERBOSE=1` prints full build output; `NOSIGN=1` is set automatically by
the make targets so local builds don't need provisioning.

## 9. Working Conventions

- Use `make` targets (or `XcodeBuildMCP`) rather than raw `xcodebuild`.
- After Swift edits, run a build-check target — not the full test suite.
- ViewModel tests run against `MockAutorotaService` and do not require
  the XCFramework; SPM integration tests do.
- Xcode 26+ required; deployment targets iOS/iPadOS 26.2, macOS 26.1,
  visionOS 26.2.
- Wages are stored per-employee in the employee's currency. Display
  conversion goes through `ExchangeRateService`.
- `SDKROOT` must be set per target when building the XCFramework (see
  `scripts/build_xcframework.sh`).
- Cross-platform changes that touch the Rust model almost always
  require: migration, model field, query update, FFI type mirror, FFI
  export, Swift binding regen, view-model surface, view update.

## 10. Documentation Map

| Doc | Purpose |
|-----|---------|
| `docs/overview.md` | This file — current architecture + status |
| `docs/specs/rota-overflow-menu.md` | Current behaviour of the Rota dots menu |
| `docs/quick-bar-report.md` | Current tab bar + Menu overflow; notes the superseded radial-fan approach |
| `docs/superpowers/plans/*.md` | Historical implementation plans (marked implemented) |
| `docs/superpowers/specs/*.md` | Historical design specs (marked implemented or superseded) |
| `CLAUDE.md` | Concise project instructions for Claude |
| `AGENTS.md` | Agent conventions |
| `GAPS.md` | Known gaps and their severity |
| `BUG_LIST.md` | Open bugs |
| `TODO_LIST.md` | Open work items |
| `brainstorming.md`, `revised_brainstorming.md` | Historical design notes |
