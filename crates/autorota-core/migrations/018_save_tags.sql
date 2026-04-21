CREATE TABLE IF NOT EXISTS save_tags (
    save_id  INTEGER NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    tag      TEXT    NOT NULL,
    PRIMARY KEY (save_id, position)
);
CREATE INDEX IF NOT EXISTS idx_save_tags_save_id ON save_tags(save_id);
