-- Migration 005: Make template_id nullable on shifts table to support ad-hoc shifts.
-- SQLite requires table recreation to change column constraints.

CREATE TABLE shifts_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id INTEGER REFERENCES shift_templates(id) ON DELETE CASCADE,
    rota_id INTEGER NOT NULL REFERENCES rotas(id),
    date TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    required_role TEXT NOT NULL,
    min_employees INTEGER NOT NULL DEFAULT 1,
    max_employees INTEGER NOT NULL DEFAULT 1
);

INSERT INTO shifts_new SELECT * FROM shifts;
DROP TABLE shifts;
ALTER TABLE shifts_new RENAME TO shifts;
