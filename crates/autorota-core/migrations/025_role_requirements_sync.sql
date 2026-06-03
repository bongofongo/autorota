-- Sync-only mirror of the role-requirement child tables. Rides the existing
-- per-field sync pipeline (see syncable_columns / apply_remote_record).
ALTER TABLE shifts          ADD COLUMN role_requirements_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE shift_templates ADD COLUMN role_requirements_json TEXT NOT NULL DEFAULT '[]';

-- Backfill from the child tables created in migration 024. SQLite >= 3.38 has
-- json_group_array / json_object (bundled with the app's SQLite).
UPDATE shifts
SET role_requirements_json = COALESCE((
    SELECT json_group_array(json_object('role', role, 'min_count', min_count))
    FROM shift_role_requirements WHERE shift_id = shifts.id
), '[]');

UPDATE shift_templates
SET role_requirements_json = COALESCE((
    SELECT json_group_array(json_object('role', role, 'min_count', min_count))
    FROM template_role_requirements WHERE template_id = shift_templates.id
), '[]');
