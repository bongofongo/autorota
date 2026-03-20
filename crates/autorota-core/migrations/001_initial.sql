CREATE TABLE IF NOT EXISTS employees (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    roles TEXT NOT NULL DEFAULT '[]',                    -- JSON array of role strings
    max_daily_hours REAL NOT NULL DEFAULT 8.0,
    max_weekly_hours REAL NOT NULL DEFAULT 40.0,
    default_availability TEXT NOT NULL DEFAULT '{}',     -- JSON: {"Mon:8":"Yes", ...}
    availability TEXT NOT NULL DEFAULT '{}'              -- JSON: week-specific override
);

CREATE TABLE IF NOT EXISTS shift_templates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    weekdays TEXT NOT NULL,            -- comma-separated: "Mon,Wed,Fri"
    start_time TEXT NOT NULL,         -- "HH:MM:SS"
    end_time TEXT NOT NULL,           -- "HH:MM:SS"
    required_role TEXT NOT NULL,
    min_employees INTEGER NOT NULL DEFAULT 1,
    max_employees INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS rotas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    week_start TEXT NOT NULL,          -- ISO date "YYYY-MM-DD", always a Monday
    finalized INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS shifts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id INTEGER NOT NULL REFERENCES shift_templates(id) ON DELETE CASCADE,
    rota_id INTEGER NOT NULL REFERENCES rotas(id),
    date TEXT NOT NULL,                -- ISO date "YYYY-MM-DD"
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    required_role TEXT NOT NULL,
    min_employees INTEGER NOT NULL DEFAULT 1,
    max_employees INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS assignments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rota_id INTEGER NOT NULL REFERENCES rotas(id),
    shift_id INTEGER NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id INTEGER NOT NULL REFERENCES employees(id),
    status TEXT NOT NULL DEFAULT 'Proposed' CHECK(status IN ('Proposed', 'Confirmed', 'Overridden'))
);
