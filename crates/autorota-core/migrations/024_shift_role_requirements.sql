-- Multi-role shifts: each shift/template can require several roles, each with
-- its own minimum headcount. One employee who holds multiple required roles
-- covers one unit of each. The legacy `required_role` columns are kept for
-- backward compatibility but are no longer read by the scheduler.

CREATE TABLE IF NOT EXISTS shift_role_requirements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    shift_id INTEGER NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    min_count INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS template_role_requirements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id INTEGER NOT NULL REFERENCES shift_templates(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    min_count INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_srr_shift ON shift_role_requirements(shift_id);
CREATE INDEX IF NOT EXISTS idx_trr_template ON template_role_requirements(template_id);

-- Backfill: carry each existing non-empty single role across as one requirement
-- whose minimum is the old overall min_employees. Harmless when there are no rows.
INSERT INTO shift_role_requirements (shift_id, role, min_count)
    SELECT id, required_role, min_employees FROM shifts WHERE required_role <> '';

INSERT INTO template_role_requirements (template_id, role, min_count)
    SELECT id, required_role, min_employees FROM shift_templates WHERE required_role <> '';
