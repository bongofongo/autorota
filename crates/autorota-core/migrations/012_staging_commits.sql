-- Persisted staging state: tracks which shifts the user has staged for commit.
CREATE TABLE IF NOT EXISTS staged_shifts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    shift_id    INTEGER NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    rota_id     INTEGER NOT NULL REFERENCES rotas(id) ON DELETE CASCADE,
    staged_at   TEXT    NOT NULL,
    UNIQUE(shift_id)
);

-- Immutable commit snapshots: each row is a point-in-time record of committed shifts.
CREATE TABLE IF NOT EXISTS commits (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    rota_id         INTEGER NOT NULL REFERENCES rotas(id) ON DELETE CASCADE,
    committed_at    TEXT    NOT NULL,
    summary         TEXT    NOT NULL,
    snapshot_json   TEXT    NOT NULL
);

-- Migrate existing finalized rotas into the commits table so we don't lose history.
-- For each finalized rota, create a synthetic commit with the current assignment data.
INSERT INTO commits (rota_id, committed_at, summary, snapshot_json)
SELECT
    r.id,
    COALESCE(r.last_modified, datetime('now')),
    'Migrated from finalized state',
    json_object(
        'week_start', r.week_start,
        'committed_shift_ids', (
            SELECT json_group_array(s.id)
            FROM shifts s WHERE s.rota_id = r.id
        ),
        'shifts', (
            SELECT json_group_array(
                json_object(
                    'shift_id', s.id,
                    'date', s.date,
                    'start_time', s.start_time,
                    'end_time', s.end_time,
                    'required_role', s.required_role,
                    'min_employees', s.min_employees,
                    'max_employees', s.max_employees,
                    'assignments', (
                        SELECT COALESCE(json_group_array(
                            json_object(
                                'assignment_id', a.id,
                                'employee_id', a.employee_id,
                                'employee_name', COALESCE(a.employee_name, ''),
                                'status', a.status,
                                'hourly_wage', a.hourly_wage,
                                'wage_currency', e.wage_currency
                            )
                        ), '[]')
                        FROM assignments a
                        LEFT JOIN employees e ON e.id = a.employee_id
                        WHERE a.shift_id = s.id
                    )
                )
            )
            FROM shifts s WHERE s.rota_id = r.id
        )
    )
FROM rotas r
WHERE r.finalized = 1;
