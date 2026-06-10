-- Index saves by rota_id. The Edit Log filters/joins saves by rota_id
-- (list_saves, per-rota queries); without this, lookups scan the whole table
-- and degrade as the save count grows over months/years.
CREATE INDEX IF NOT EXISTS idx_saves_rota_id ON saves(rota_id);
