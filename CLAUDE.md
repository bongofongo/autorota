# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# autorota

A multi-platform cafe shift scheduling app. Rust `autorota-core` provides the shared scheduling engine and SQLite database. Frontends: Tauri (desktop/web), SwiftUI (iOS/macOS). Future: Android (Kotlin via UniFFI), Linux.

## Purpose

Cafe managers define shifts that need to be filled each week. Employees declare their availability. The scheduler assigns employees to shifts respecting those preferences and any hour limits.

## Core concepts

- **Shift** — a time slot on a specific weekday with a start time, end time, and derived duration. Has a required role/skill and an employee capacity (min/max headcount).
- **Employee** — has a set of roles/skills, weekly and daily hour constraints, and an availability map.
- **Availability** — an hour-by-hour, weekday-keyed map with three states: `Yes`, `Maybe`, `No`. Employees have a default availability template and a week-specific override derived from it.
- **Assignment** — links one employee to one shift for a specific week. Status: `Proposed | Confirmed | Overridden`.
- **Rota** — the full collection of assignments for a given week; stored as a finalized schedule record.
- **Shift templates** — reusable weekly patterns from which concrete dated shift instances are materialised each scheduling run.

## Scheduling algorithm

Two-pass approach:
1. **Pre-assignment pass** — apply manual overrides/pins first.
2. **Greedy assignment pass** — for each remaining shift (hardest-to-fill first), score eligible employees by availability quality (`Yes > Maybe > No`), remaining hour budget, and fairness (fewest hours assigned so far this week). Tiebreak on that score.

## Architecture

**Cargo workspace** with four active crates:

```
autorota/
  Cargo.toml                          # workspace manifest
  crates/
    autorota-core/                    # pure library: models, scheduler, db layer
      src/
        lib.rs
        models/                       # employee, availability, shift, assignment, rota
        scheduler/                    # mod.rs (algorithm), scoring.rs, tiebreak.rs
        db/                           # mod.rs (pool + migrations), queries.rs
      migrations/                     # SQL migration files (embedded at runtime)
      tests/                          # db_integration.rs, scheduler_test.rs
    app-desktop/                      # Tauri v2 desktop shell
      src/                            # Frontend: main.ts (single-file UI), styles.css
      src-tauri/                      # Tauri backend: lib.rs (command handlers), tauri.conf.json
    autorota-ffi/                     # UniFFI wrapper → Swift/Kotlin bindings
      src/
        lib.rs                        # setup_scaffolding!(), OnceLock<Pool+Runtime>, #[uniffi::export] fns
        types.rs                      # Ffi* mirror types (#[derive(uniffi::Record)])
        error.rs                      # FfiError (#[derive(uniffi::Error)])
    uniffi-bindgen/                   # Standalone CLI crate for generating bindings
      src/main.rs                     # fn main() { uniffi::uniffi_bindgen_main() }
  platforms/
    apple/
      AutorotaKit/                    # Swift Package (SPM library)
        Package.swift
        Sources/AutorotaKit/
          generated/                  # uniffi-generated autorota_ffi.swift + headers (committed)
          AutorotaKit.swift           # async wrappers, DB init helper, week utilities
        XCFrameworks/                 # gitignored — built by scripts/build_xcframework.sh
          AutorotaFFI.xcframework/
      Apps/AutorotaApp/               # Xcode project (iOS 17 / macOS 14)
        AutorotaApp/
          AutorotaAppApp.swift        # @main, calls autorotaInitDb() on launch
          Views/
            ContentView.swift         # TabView: Rota / Employees / Templates
            RotaView.swift
            EmployeeListView.swift
            EmployeeDetailView.swift
            AvailabilityGridView.swift
            ShiftTemplateListView.swift
          ViewModels/
            RotaViewModel.swift
            EmployeeViewModel.swift
            ShiftTemplateViewModel.swift
  scripts/
    build_xcframework.sh              # full Rust→XCFramework build pipeline
```

### Rust layer

All business logic lives in `autorota-core`. `app-desktop/src-tauri` is a thin adapter exposing Tauri commands that call into core. The frontend is a single TypeScript file (`src/main.ts`) built with Vite.

`AppState` in `src-tauri/src/lib.rs` wraps a `Mutex<SqlitePool>` and is shared across all Tauri commands. The database file (`autorota.db`) is created in the OS app data directory on first launch.

Migrations are embedded as strings in `db/mod.rs` and run automatically on `connect()`. Migration 002 uses conditional logic (checks column existence) to be idempotent.

### autorota-ffi crate

UniFFI 0.28 wrapper exposing the full command surface to Swift (and future Kotlin). Key design decisions:

- `crate-type = ["staticlib", "cdylib"]` — `.a` for XCFramework, `.dylib` for binding generation
- Global `OnceLock<SqlitePool>` + `OnceLock<Runtime>` — all exported fns call `rt().block_on(...)`
- `Availability` crosses the FFI boundary as `Vec<AvailabilitySlot>` (flattened from `HashMap<(Weekday,u8), AvailabilityState>`)
- All chrono types cross as strings: dates `"YYYY-MM-DD"`, times `"HH:MM"`, weekdays `"Mon"`/`"Tue"` etc.
- `uniffi-bindgen` is a **separate crate** (not a `[[bin]]` in `autorota-ffi`) with `uniffi = { features = ["cli"] }`

### Apple platform

- Min deployment: iOS 17 / macOS 14 (for `@Observable`)
- `scripts/build_xcframework.sh` compiles for `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`; lipo-s the macOS slices; generates Swift bindings; assembles XCFramework
- **`SDKROOT` must be set per target** so `libsqlite3-sys`/cc-rs finds the correct SDK headers
- `autorota_ffiFFI.modulemap` must be copied as `module.modulemap` into the XCFramework headers dir so Clang exposes `module autorota_ffiFFI` to Swift
- `AutorotaKit.swift` provides async wrappers using `Task.detached` to keep blocking FFI calls off the main actor

## Stack

| Concern | Choice |
|---|---|
| Async runtime | Tokio |
| Database | SQLite via SQLx |
| Desktop (Linux/Windows/macOS) | Tauri v2 |
| iOS / macOS native | SwiftUI (iOS 17 / macOS 14) |
| Swift bindings | UniFFI 0.28 |
| Serialization | Serde + serde_json |
| Frontend build (desktop) | Vite + TypeScript |

## Dev commands

```bash
# Rust (run from workspace root)
cargo fmt
cargo clippy
cargo test
cargo test -p autorota-core                    # core tests only
cargo test -p autorota-core db_integration     # single test file

# Desktop app (run from crates/app-desktop/)
npm install
npm run tauri dev      # starts Vite + Tauri with hot reload
npm run tauri build    # production build

# Apple platform (run from workspace root)
# Prerequisites:
#   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin
bash scripts/build_xcframework.sh             # full release build
bash scripts/build_xcframework.sh --debug     # faster debug build
# Then open platforms/apple/Apps/AutorotaApp in Xcode and build/run
```
