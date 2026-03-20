# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# autorota

A Rust + Tauri desktop app for cafe shift scheduling. Given a roster of employees and a set of weekly shift requirements, the system automatically assigns employees to shifts based on their availability and constraints.

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

**Cargo workspace** with two active crates:

```
autorota/
  Cargo.toml                      # workspace manifest
  crates/
    autorota-core/                # pure library: models, scheduler, db layer
      src/
        lib.rs
        models/                   # employee, availability, shift, assignment, rota
        scheduler/                # mod.rs (algorithm), scoring.rs, tiebreak.rs
        db/                       # mod.rs (pool + migrations), queries.rs
      migrations/                 # 3 SQL migration files (embedded at runtime)
      tests/                      # db_integration.rs, scheduler_test.rs
    app-desktop/                  # Tauri v2 desktop shell
      src/                        # Frontend: main.ts (single-file UI), styles.css
      src-tauri/                  # Tauri backend: lib.rs (command handlers), tauri.conf.json
```

All business logic lives in `autorota-core`. `app-desktop/src-tauri` is a thin adapter exposing Tauri commands that call into core. The frontend is a single TypeScript file (`src/main.ts`) built with Vite.

`AppState` in `src-tauri/src/lib.rs` wraps a `Mutex<SqlitePool>` and is shared across all Tauri commands. The database file (`autorota.db`) is created in the OS app data directory on first launch.

Migrations are embedded as strings in `db/mod.rs` and run automatically on `connect()`. Migration 002 uses conditional logic (checks column existence) to be idempotent.

## Stack

| Concern | Choice |
|---|---|
| Async runtime | Tokio |
| Database | SQLite via SQLx |
| Desktop | Tauri v2 |
| Serialization | Serde + serde_json |
| Frontend build | Vite + TypeScript |

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
```
