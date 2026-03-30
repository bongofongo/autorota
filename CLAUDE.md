# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

# autorota

A multi-platform cafe shift scheduling app. Rust `autorota-core` provides the shared scheduling engine and SQLite database. Frontends: Tauri (desktop/web), SwiftUI (iOS/macOS). Future: Android (Kotlin via UniFFI), Linux.

## Purpose

Cafe managers define shifts that need to be filled each week. Employees declare their availability. The scheduler assigns employees to shifts respecting those preferences and any hour limits.

## Core concepts

- **Shift** — a time slot on a specific weekday with start/end time and derived duration. Has a required role/skill and employee capacity (min/max headcount).
- **Employee** — has roles/skills, weekly/daily hour constraints, and an availability map. Name is split into `first_name`, `last_name`, `nickname` with a `display_name()` helper.
- **Availability** — hour-by-hour, weekday-keyed map with three states: `Yes`, `Maybe`, `No`. Employees have a default template and a week-specific override.
- **Assignment** — links one employee to one shift for a specific week. Status: `Proposed | Confirmed | Overridden`.
- **Rota** — full collection of assignments for a given week; stored as a finalized schedule record.
- **Role** — a skill/role that employees can hold and shifts can require (stored in `roles` table).

## Scheduling algorithm

Two-pass approach:
1. **Pre-assignment pass** — apply manual overrides/pins first.
2. **Greedy assignment pass** — for each remaining shift (hardest-to-fill first), score eligible employees by availability quality (`Yes > Maybe > No`), remaining hour budget, and fairness (fewest hours assigned so far). Tiebreak on that score.

## Architecture

**Cargo workspace** with four active crates:

```
autorota/
  Cargo.toml
  Makefile                            # test suite runner (see Dev commands)
  crates/
    autorota-core/                    # pure library: models, scheduler, db layer
      src/
        models/                       # employee, availability, shift, assignment, rota, role
        scheduler/                    # mod.rs (algorithm), scoring.rs
        db/                           # mod.rs (pool + migrations), queries.rs
      migrations/                     # 001–010 SQL files, embedded at runtime
      tests/                          # db_integration.rs, scheduler_test.rs, helpers/
    app-desktop/                      # Tauri v2 desktop shell
      src/                            # main.ts (single-file UI), styles.css, main.js
      src-tauri/                      # lib.rs (command handlers), tauri.conf.json
    autorota-ffi/                     # UniFFI wrapper → Swift/Kotlin bindings
      src/
        lib.rs                        # OnceLock<Pool+Runtime>, #[uniffi::export] fns
        types.rs                      # Ffi* mirror types (#[derive(uniffi::Record)])
        error.rs                      # FfiError (#[derive(uniffi::Error)])
        bin/uniffi_bindgen.rs         # bindgen CLI entry point
  platforms/
    apple/
      AutorotaKit/                    # Swift Package (SPM library)
        Sources/AutorotaKit/
          generated/                  # committed: autorota_ffi.swift + headers
          AutorotaKit.swift           # async wrappers, DB init helper, week utilities
        Tests/AutorotaKitTests/       # SPM integration tests (real FFI)
        XCFrameworks/                 # gitignored — built by scripts/build_xcframework.sh
      Apps/AutorotaApp/               # Xcode project (iOS 17 / macOS 14)
        AutorotaApp/                  # @main entry, assets
        Services/                     # AutorotaServiceProtocol, LiveAutorotaService, ExchangeRateService
        ViewModels/                   # RotaViewModel, EmployeeViewModel, ShiftTemplateViewModel, RoleViewModel
        Views/                        # SwiftUI views
        AutorotaAppTests/             # ViewModel unit tests using MockAutorotaService
  scripts/
    build_xcframework.sh              # full Rust→XCFramework build pipeline
```

### Rust layer

All business logic lives in `autorota-core`. `app-desktop/src-tauri` is a thin adapter exposing Tauri commands. The frontend is a single TypeScript file built with Vite.

`AppState` in `src-tauri/src/lib.rs` wraps a `Mutex<SqlitePool>`. The DB file lives in the OS app data directory.

Migrations are embedded in `db/mod.rs` and run automatically on `connect()`.

### autorota-ffi crate

UniFFI 0.28 wrapper exposing the full command surface to Swift (and future Kotlin):

- `crate-type = ["staticlib", "cdylib"]` — `.a` for XCFramework, `.dylib` for binding generation
- Global `OnceLock<SqlitePool>` + `OnceLock<Runtime>` — all exported fns call `rt().block_on(...)`
- `Availability` crosses FFI as `Vec<AvailabilitySlot>` (flattened from `HashMap<(Weekday,u8), AvailabilityState>`)
- All chrono types cross as strings: dates `"YYYY-MM-DD"`, times `"HH:MM"`, weekdays `"Mon"` etc.
- The `uniffi-bindgen` CLI is in `src/bin/uniffi_bindgen.rs` (not a separate crate)

### Apple platform

- Min deployment: iOS 17 / macOS 14 (for `@Observable`)
- Services layer uses `AutorotaServiceProtocol` for testability — `LiveAutorotaService` wraps the FFI; `MockAutorotaService` is used in ViewModel unit tests
- `AutorotaKit.swift` provides async wrappers using `Task.detached` to keep blocking FFI off the main actor
- `scripts/build_xcframework.sh` compiles for `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`; lipo-s macOS slices; assembles XCFramework
- **`SDKROOT` must be set per target** so `libsqlite3-sys`/cc-rs finds the correct SDK headers

## Wages & currency

Employees have an optional `hourly_wage` and `wage_currency` (e.g. "usd", "gbp", "eur"). Wages are stored in the employee's chosen currency. Assignments snapshot the wage at scheduling time. `shift_cost` is computed at the FFI layer (`hourly_wage × duration`), not stored in DB. The global display currency (`@AppStorage("appCurrency")`) controls what the user sees everywhere — `ExchangeRateService` fetches live rates from `api.frankfurter.dev`, caches in UserDefaults for offline use, and converts between currencies at display time. The `AppCurrency` enum is defined in `SettingsView.swift`.

## Stack

| Concern | Choice |
|---|---|
| Async runtime | Tokio |
| Database | SQLite via SQLx |
| Desktop | Tauri v2 |
| iOS / macOS native | SwiftUI (iOS 17 / macOS 14) |
| Swift bindings | UniFFI 0.28 |
| Serialization | Serde + serde_json |
| Frontend build | Vite + TypeScript |

## Dev commands

All Swift/Xcode tasks use the `make` targets defined in `Makefile` or the XcodeBuildMCP tools — prefer those over raw `xcodebuild` invocations.

```bash
# Rust (workspace root)
cargo fmt
cargo clippy
cargo test
cargo test -p autorota-core                    # core tests only

# Desktop app (crates/app-desktop/)
npm run tauri dev      # Vite + Tauri with hot reload
npm run tauri build    # production build

# Apple platform — build XCFramework first (workspace root)
make swift-build-xcframework           # release build
make swift-build-xcframework-debug     # faster debug build

# Swift build checks (compile only, no simulator run)
make swift-build-check-macos
make swift-build-check-ios
make swift-build-check                 # all three platforms

# Swift ViewModel unit tests (mock service, no live FFI)
make swift-test-app-macos
make swift-test-app-ios

# SPM integration tests (real FFI — XCFramework must be built first)
make swift-test-package

# Full suite
make test-all
```

## Swift / Xcode tooling

- **Always use the `xcodebuildmcp-cli` skill** before calling any XcodeBuildMCP tools (see AGENTS.md).
- Use XcodeBuildMCP tools (`build_macos`, `build_sim`, `test_macos`, `test_sim`, etc.) in preference to raw shell `xcodebuild` commands.
- **After editing Swift files, run only the build-check targets** (`make swift-build-check-macos` or `make swift-build-check-ios`) to verify compilation. Do not run the full simulator test suite just to check that code compiles.
- ViewModel unit tests (`AutorotaAppTests/`) use `MockAutorotaService` and do not require the XCFramework — they run without rebuilding Rust.
- SPM integration tests in `AutorotaKit/Tests/` require the XCFramework to be built first.
- Xcode 26+ is required (as specified in the Makefile).
