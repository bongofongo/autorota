CREATE TABLE IF NOT EXISTS availability_progress (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    employee_id INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    week_start TEXT NOT NULL,
    done INTEGER NOT NULL DEFAULT 0,
    UNIQUE(employee_id, week_start)
);
