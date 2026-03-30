-- Add hourly wage to employees (their current rate) and assignments (snapshot at scheduling time).
ALTER TABLE employees ADD COLUMN hourly_wage REAL DEFAULT NULL;
ALTER TABLE assignments ADD COLUMN hourly_wage REAL DEFAULT NULL;
