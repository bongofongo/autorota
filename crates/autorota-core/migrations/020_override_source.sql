ALTER TABLE employee_availability_overrides
ADD COLUMN source TEXT NOT NULL DEFAULT 'exception';
