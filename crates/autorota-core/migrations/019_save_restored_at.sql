-- When a user restores to a past save, stamp the restore time on that save.
-- Rows with a non-NULL restored_at sort above rows ordered by saved_at, and
-- the UI shows a red "Restored" badge. Also used to promote the restored
-- entry to the top of its week's list (even if it's older than siblings).
ALTER TABLE saves ADD COLUMN restored_at TEXT NULL;
CREATE INDEX IF NOT EXISTS idx_saves_restored_at ON saves(restored_at);
