-- Migration 002: Rename weekday -> weekdays, add ON DELETE CASCADE.
-- This migration is run conditionally from Rust (only if the old 'weekday' column exists).

CREATE TABLE IF NOT EXISTS shift_templates_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    weekdays TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    required_role TEXT NOT NULL,
    min_employees INTEGER NOT NULL DEFAULT 1,
    max_employees INTEGER NOT NULL DEFAULT 1
);

INSERT OR IGNORE INTO shift_templates_new (id, name, weekdays, start_time, end_time, required_role, min_employees, max_employees)
    SELECT id, name, weekday, start_time, end_time, required_role, min_employees, max_employees
    FROM shift_templates;

DROP TABLE shift_templates;
ALTER TABLE shift_templates_new RENAME TO shift_templates;

CREATE TABLE IF NOT EXISTS shifts_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id INTEGER NOT NULL REFERENCES shift_templates(id) ON DELETE CASCADE,
    rota_id INTEGER NOT NULL REFERENCES rotas(id),
    date TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    required_role TEXT NOT NULL,
    min_employees INTEGER NOT NULL DEFAULT 1,
    max_employees INTEGER NOT NULL DEFAULT 1
);

INSERT OR IGNORE INTO shifts_new SELECT * FROM shifts;
DROP TABLE shifts;
ALTER TABLE shifts_new RENAME TO shifts;

CREATE TABLE IF NOT EXISTS assignments_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rota_id INTEGER NOT NULL REFERENCES rotas(id),
    shift_id INTEGER NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id INTEGER NOT NULL REFERENCES employees(id),
    status TEXT NOT NULL DEFAULT 'Proposed' CHECK(status IN ('Proposed', 'Confirmed', 'Overridden'))
);

INSERT OR IGNORE INTO assignments_new SELECT * FROM assignments;
DROP TABLE assignments;
ALTER TABLE assignments_new RENAME TO assignments;
