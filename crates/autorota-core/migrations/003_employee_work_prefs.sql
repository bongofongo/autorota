-- Add new employee fields: start_date, work preferences, notes, bank_details.
-- Migrate max_weekly_hours → target_weekly_hours with a default ±6h deviation.

ALTER TABLE employees ADD COLUMN start_date TEXT NOT NULL DEFAULT '2026-01-01';
ALTER TABLE employees ADD COLUMN target_weekly_hours REAL NOT NULL DEFAULT 40.0;
ALTER TABLE employees ADD COLUMN weekly_hours_deviation REAL NOT NULL DEFAULT 6.0;
ALTER TABLE employees ADD COLUMN notes TEXT;
ALTER TABLE employees ADD COLUMN bank_details TEXT;

-- Migrate existing max_weekly_hours into target_weekly_hours
UPDATE employees SET target_weekly_hours = max_weekly_hours;
