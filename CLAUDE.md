# CLAUDE.md

## What is autorota?

Multi-platform cafe shift scheduling app. Rust `autorota-core` provides the scheduling engine and SQLite database. Frontends: Tauri (desktop/web), SwiftUI (iOS/iPadOS/macOS). Future: Android (Kotlin via UniFFI).

Cafe managers define shifts. Employees declare availability. The scheduler assigns employees to shifts respecting preferences and hour limits.

## Core concepts

- **Shift** — weekday time slot with optional role and employee capacity (min/max headcount). Wildcard shifts (no role) accept any employee
- **Employee** — has roles, weekly/daily hour constraints, availability map, optional wage & currency. Name split into `first_name`, `last_name`, `nickname`
- **Availability** — hour-by-hour, weekday-keyed: `Yes`, `Maybe`, `No`. Default weekly template + date-specific overrides
- **Override / Exception** — two kinds: *employee availability overrides* (date-specific availability replacing the weekly template) and *shift template overrides* (date-specific changes to a template's times, capacity, or cancellation). Each override carries a `source` discriminator
- **Assignment** — links employee to shift for a week. Status: `Proposed | Confirmed | Overridden`. Snapshots employee name and wage at creation
- **Rota** — all assignments for a given week
- **Role** — skill that employees hold and shifts require (optional on shifts)
- **Save** — immutable snapshot of a rota. Auto-created on edit-mode exit and week navigation. Supports tags/labels, restore, and per-save diff vs. previous. Replaced the legacy manual "commit" flow
- **Edit Log** — timeline view of saves per week with inline diff expansion, labeling, and restore. Replaces the old commit-history UI
- **Export** — CSV, JSON, and PDF schedule export. Layouts: employee-by-weekday or shift-by-weekday. Profiles: staff schedule (no wages) or manager report (with costs). PDF templates: weekly grid, per-employee, by-role

## Architecture

Cargo workspace: `autorota-core` (models, scheduler, db, export), `autorota-ffi` (UniFFI bindings for Swift/Kotlin), `uniffi-bindgen` (bindgen binary), `app-desktop` (Tauri v2). Apple platform under `platforms/apple/` with `AutorotaKit` (SPM package wrapping the XCFramework) and `AutorotaApp` (Xcode project, iOS/iPadOS/macOS). Database: SQLite with 23 auto-applied migrations.

Scheduling algorithm: two-pass greedy — apply manual overrides first, then assign remaining shifts hardest-to-fill-first using availability quality, hour budget, fairness scoring, and deterministic hash-based tiebreaking.

Services layer uses `AutorotaServiceProtocol` for testability. `LiveAutorotaService` wraps FFI and broadcasts `.autorotaDataChanged` notifications on mutations; `MockAutorotaService` for ViewModel unit tests. iCloud sync via `CKSyncEngine` with three-way per-field merge conflict resolution (`AutorotaSyncEngine`, `SyncConflictResolver`, `SyncRecordMapper`).

SwiftUI app features: onboarding flow, configurable tab bar (3 iOS / 4 macOS configurable slots + pinned Menu), overflow "Menu" tab for hidden pages, analytics dashboard (Charts framework), shift history with weekly/monthly breakdowns, Edit Log activity feed with diff + restore, PDF/CSV/JSON export with share sheet, iCloud sync prompt on first launch.

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
- When a bug is patched (or believed to be patched), append a concise entry to `BUG_LOG.md` marked patched-pending-verification so the user can confirm the fix actually holds
- ViewModel tests use `MockAutorotaService` and don't need the XCFramework
- SPM integration tests in `AutorotaKit/Tests/` need the XCFramework built first
- Xcode 26+ required; deployment targets iOS/iPadOS 26.2, macOS 26.1, visionOS 26.2
- Wages stored per-employee currency; display converted via `ExchangeRateService` using `api.frankfurter.dev`
- `SDKROOT` must be set per target when building the XCFramework
