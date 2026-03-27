-- Migration 007: Split the single 'name' column into first_name, last_name, and nickname.
-- Existing rows have their name copied into first_name; last_name defaults to empty string.

ALTER TABLE employees ADD COLUMN first_name TEXT NOT NULL DEFAULT '';
ALTER TABLE employees ADD COLUMN last_name  TEXT NOT NULL DEFAULT '';
ALTER TABLE employees ADD COLUMN nickname   TEXT;

UPDATE employees SET first_name = TRIM(name);

ALTER TABLE employees DROP COLUMN name;
