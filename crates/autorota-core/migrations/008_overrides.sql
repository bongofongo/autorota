-- Migration 008: Employee availability overrides and shift template overrides

CREATE TABLE IF NOT EXISTS employee_availability_overrides (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    employee_id INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    date        TEXT    NOT NULL,   -- "YYYY-MM-DD"
    -- Per-hour availability for just this day: {"8":"Yes","9":"Maybe",...}
    -- Absent hours default to Maybe (matching existing Availability behaviour)
    availability TEXT   NOT NULL DEFAULT '{}',
    notes        TEXT,
    UNIQUE(employee_id, date)
);

CREATE TABLE IF NOT EXISTS shift_template_overrides (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id   INTEGER NOT NULL REFERENCES shift_templates(id) ON DELETE CASCADE,
    date          TEXT    NOT NULL,   -- "YYYY-MM-DD"
    cancelled     INTEGER NOT NULL DEFAULT 0,   -- 1 = skip materialising this shift
    start_time    TEXT,                          -- override "HH:MM:SS", NULL = use template
    end_time      TEXT,                          -- override "HH:MM:SS", NULL = use template
    min_employees INTEGER,                       -- override, NULL = use template
    max_employees INTEGER,                       -- override, NULL = use template
    notes         TEXT,
    UNIQUE(template_id, date)
);
