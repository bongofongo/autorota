# Customer data extraction

**Trigger:** a user needs their data out of a corrupted DB or an older
schema. Usually follows a session of
[db-corruption-recovery.md](db-corruption-recovery.md).

## What you're working from

The user sends you `db.corrupt-<ts>.sqlite` (or their full
`autorota.db`). It may be:

- Intact but on an older schema (rare — migrations are forward-only and
  the recovery flow only quarantines after a failed open).
- Truncated / partially overwritten (more common — recoverable rows usually
  live in stable pages).

## Recover what you can

1. **Run `.recover` on the corrupt file** (SQLite has built-in support
   for extracting whatever pages parse cleanly):
   ```bash
   sqlite3 db.corrupt-<ts>.sqlite ".recover" > recovered.sql
   ```
2. **Build a fresh DB and replay**:
   ```bash
   sqlite3 fresh.db < recovered.sql
   ```
3. **Verify shape** — the schema you get is whatever was in the file.
   It may be missing columns recent migrations added. To bring it
   forward, run the migration pipeline against `fresh.db` by pointing
   the app at it:
   ```bash
   cp fresh.db ~/Library/Application\ Support/AutorotaApp/autorota.db
   open -a AutorotaApp
   ```
   `connect()` runs the full migration sequence on launch and the
   post-migration `PRAGMA foreign_key_check` (PR4) refuses to open if
   anything is dangling.

## Export to give back to the user

If you don't want to roundtrip via the app, the project ships
exporters that take a live DB and emit human-friendly formats:

- `autorota_core::export::csv::render_csv` — rota grid
- `autorota_core::export::json` — machine-readable full week
- `autorota_core::export::pdf` — printable schedule

Easiest path: spin up the app pointed at the recovered DB and use the
in-app Export sheet to produce a CSV / PDF / JSON, then send those to
the user. The post-PR3 CSV exporter neutralises any cell that starts
with `=`, `+`, `-`, `@`, tab, or CR so it's safe to open in Excel.

## What you cannot recover

- If `.recover` returns no rows for a table, that table's pages are gone
  — there's no deeper recovery path.
- If the file is encrypted (it shouldn't be — Autorota doesn't enable
  SQLite encryption), you have nothing to work with.

## Don't do

- Don't try to merge the user's recovered DB into another user's DB —
  the integer primary keys collide and you'll silently overwrite rows.
  Always extract to a portable format (CSV / JSON) first, then re-import
  via the roster import UI (which validates each row through the
  PR3 boundary validators).
