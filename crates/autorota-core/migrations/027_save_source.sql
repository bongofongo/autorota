-- Add a source discriminator to saves so the Edit Log can distinguish
-- scheduler-generated saves from manual edit-session saves.
-- Values: 'generation' | 'regeneration' | 'manual' | 'restore'.
ALTER TABLE saves ADD COLUMN source TEXT NOT NULL DEFAULT 'manual';
