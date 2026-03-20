# autorota

A Rust backend for cafe shift-scheduling software. Given a roster of employees and a set of weekly shift requirements, the system automatically assigns employees to shifts based on their availability and constraints.

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

The project is a **Cargo workspace** with three crates:

```
autorota/
  Cargo.toml                # workspace manifest
  crates/
    autorota-core/          # pure library: models, scheduler, db layer
    autorota-tauri/         # Tauri desktop shell (thin command wrappers)
    autorota-uniffi/        # iOS target via UniFFI Swift bindings
```

All business logic lives in `autorota-core`. The other crates are thin platform adapters.

### autorota-core layout

```
crates/autorota-core/src/
  lib.rs
  models/
    employee.rs       # Employee struct + serde
    availability.rs   # Availability map, AvailabilityState enum
    shift.rs          # Shift + ShiftTemplate structs
    assignment.rs     # Assignment struct + status enum
    rota.rs           # Rota (weekly schedule) struct
  scheduler/
    mod.rs            # algorithm entry point
    scoring.rs        # employee scoring/ranking
    tiebreak.rs
  db/
    mod.rs            # SQLx connection pool, migrations
    queries.rs        # typed query functions
```

## Stack

| Concern | Choice | Reason |
|---|---|---|
| Async runtime | Tokio | Works in Tauri, required by SQLx |
| Database | SQLite via SQLx | Embeds on iOS, trivial Postgres migration path |
| Desktop | Tauri | Direct Rust integration, fast iteration |
| iOS bindings | UniFFI | Auto-generates Swift from annotated Rust |
| Serialization | Serde + serde_json | JSON for config and FFI types |

## Database

SQLite to start. SQLx supports both SQLite and Postgres with the same API — migration is a connection string change and minor query adjustments. Postgres becomes relevant only if a sync server is added later.

## Dev commands

```
cargo fmt
cargo clippy
cargo test
```
