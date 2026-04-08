-- Migration 013: Performance indexes for hot foreign-key lookups.
-- These speed up rota loading, deletion (which scans by shift_id/rota_id),
-- and availability override lookups during scheduling.

CREATE INDEX IF NOT EXISTS idx_shifts_rota_id           ON shifts(rota_id);
CREATE INDEX IF NOT EXISTS idx_assignments_shift_id     ON assignments(shift_id);
CREATE INDEX IF NOT EXISTS idx_assignments_employee_id  ON assignments(employee_id);
CREATE INDEX IF NOT EXISTS idx_assignments_rota_id      ON assignments(rota_id);
CREATE INDEX IF NOT EXISTS idx_emp_avail_overrides_emp_date
    ON employee_availability_overrides(employee_id, date);
