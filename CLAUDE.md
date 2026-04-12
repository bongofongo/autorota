# CLAUDE.md

## What is autorota?

Multi-platform cafe shift scheduling app. Rust `autorota-core` provides the scheduling engine and SQLite database. Frontends: Tauri (desktop/web), SwiftUI (iOS/macOS). Future: Android (Kotlin via UniFFI).

Cafe managers define shifts. Employees declare availability. The scheduler assigns employees to shifts respecting preferences and hour limits.

## Core concepts

- **Shift** — weekday time slot with optional role and employee capacity (min/max headcount). Wildcard shifts (no role) accept any employee
- **Employee** — has roles, weekly/daily hour constraints, availability map, optional wage & currency
- **Availability** — hour-by-hour, weekday-keyed: `Yes`, `Maybe`, `No`. Default template + date-specific overrides
- **Override** — two kinds: *employee availability overrides* (date-specific availability replacing the weekly template) and *shift template overrides* (date-specific changes to a template's times, capacity, or cancellation)
- **Assignment** — links employee to shift for a week. Status: `Proposed | Confirmed | Overridden`. Snapshots employee name and wage at creation
- **Rota** — all assignments for a given week. Can be finalized to prevent further changes
- **Role** — skill that employees hold and shifts require (optional on shifts)
- **Export** — CSV, JSON, and PDF schedule export. Layouts: employee-by-weekday or shift-by-weekday. Profiles: staff schedule (no wages) or manager report (with costs). PDF templates: weekly grid, per-employee, by-role
- **Staging/Commit** — git-like workflow for past shifts. Stage individual shifts, days, or weeks, then commit with a snapshot for audit history

## Architecture

Cargo workspace: `autorota-core` (models, scheduler, db, export), `autorota-ffi` (UniFFI bindings for Swift/Kotlin), `app-desktop` (Tauri v2). Apple platform under `platforms/apple/` with `AutorotaKit` (SPM package) and `AutorotaApp` (Xcode project). Database: SQLite with 12 auto-applied migrations.

Scheduling algorithm: two-pass greedy — apply manual overrides first, then assign remaining shifts hardest-to-fill-first using availability quality, hour budget, fairness scoring, and deterministic hash-based tiebreaking.

Services layer uses `AutorotaServiceProtocol` for testability. `LiveAutorotaService` wraps FFI and broadcasts `.autorotaDataChanged` notifications on mutations; `MockAutorotaService` for ViewModel unit tests. iCloud sync via `CKSyncEngine` with three-way per-field merge conflict resolution.

SwiftUI app features: onboarding flow, configurable tab bar, analytics dashboard (Charts framework), shift history with weekly/monthly breakdowns, commit history with change tracking, PDF/CSV/JSON export with share sheet.

## Dev commands

```bash
cargo fmt && cargo clippy && cargo test   # Rust

make swift-build-xcframework              # build XCFramework (required before Swift tests)
make swift-build-xcframework-debug        # faster debug build
make swift-build-check-macos              # compile check only (use after editing Swift)
make swift-build-check-ios
make swift-build-check-ipad
make swift-build-check                    # all three compile checks
make swift-test-app-macos                 # ViewModel tests (no FFI needed)
make swift-test-app-ios
make swift-test-app-ipad
make swift-test-package                   # SPM integration tests (needs XCFramework)
make test-all                             # everything
```

Set `VERBOSE=1` for full build output. `NOSIGN=1` is set automatically in make targets to disable code signing.

## Working conventions

- Use `make` targets or XcodeBuildMCP tools, not raw `xcodebuild`
- After editing Swift, run build-check targets to verify compilation — not full test suite
- ViewModel tests use `MockAutorotaService` and don't need the XCFramework
- SPM integration tests in `AutorotaKit/Tests/` need the XCFramework built first
- Xcode 26+ required
- Wages stored per-employee currency; display converted via `ExchangeRateService` using `api.frankfurter.dev`
- `SDKROOT` must be set per target when building the XCFramework
