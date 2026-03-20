-- Migration 004: Add soft-delete flags and snapshot employee name in assignments.
-- This migration is run conditionally from Rust (only if 'deleted' column doesn't exist on employees).

ALTER TABLE employees ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;
ALTER TABLE shift_templates ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;
ALTER TABLE assignments ADD COLUMN employee_name TEXT;

-- Backfill existing assignments with current employee names
UPDATE assignments SET employee_name = (
    SELECT name FROM employees WHERE employees.id = assignments.employee_id
);
