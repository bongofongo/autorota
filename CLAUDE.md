# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the Project

```bash
# Run the main test/demo
python test.py

# Run individual component tests
python test_employee.py
python test_shift.py

# Run as a module
python -m autorota
```

No external dependencies — standard library only.

## Architecture

Autorota is a Python rota (shift schedule) generation system. The core flow is:

1. **Load shift templates** — `shifts.json` defines recurring weekly patterns (e.g., Mon–Fri: 07:00–14:00, 08:00–16:00, 11:00–20:00). `shift_overrides.json` provides date-specific overrides.
2. **Materialize shifts** — `PShift` (pattern shift) instances are converted to `Shift` instances for specific dates via `PShift.toShift(date)`.
3. **Assign employees** — `Rota` matches employees to shifts using tiebreak/sorting functions from `tiebreak.py`, respecting each employee's `AvailDict`.
4. **Output** — A `RotaDict` (date → shifts → employees) representing the final schedule.

### Key Classes

- **`Employee`** (`employee.py`) — Holds name, role, skills, and an `AvailDict` (hour-by-hour YES/MAYBE/NO availability per weekday). `Avail` is an `IntEnum` (YES=3, MAYBE=2, NO=1) enabling numeric comparison.
- **`PShift` / `Shift`** (`shift.py`) — `PShift` is a reusable template; `Shift` is a concrete dated instance with `capacity` (headcount needed). Known issue: `PShift.toShift()` doesn't correctly handle shifts ending past midnight (see TODO at `shift.py:16`).
- **`Rota`** (`rota.py`) — Orchestrates generation. Loads JSON schedules via `shift_utils.py`, iterates dates, and fills shifts using tiebreak functions.
- **`Shop`** (`shop.py`) — Aggregates employees and shifts across a full year.
- **`tiebreak.py`** — Functions like `sortByPreference()` and `getFirst()` that rank or select employees for a given shift.

### Data Files

- `src/autorota/shifts.json` — Weekly shift schedule template (keyed by weekday)
- `src/autorota/shift_overrides.json` — Date-specific overrides (ISO date string keys)
