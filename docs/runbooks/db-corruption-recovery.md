# DB corruption recovery

**Trigger:** the app fails to open the SQLite database at launch, or the
`DatabaseRecoveryView` (added in PR1 of the bulletproofing pass) is shown.

## Where the database lives

`~/Library/Application Support/AutorotaApp/autorota.db` (macOS)
or the iOS app sandbox's `Library/Application Support/AutorotaApp/`.

Helpers in `AutorotaKit`:

- `autorotaDefaultDBURL()` returns the resolved URL.
- `autorotaQuarantineDatabase(at:)` renames the DB plus its WAL/SHM
  siblings to `db.corrupt-<unix-ts>.sqlite` (and removes the WAL/SHM
  to prevent SQLite re-attaching to the broken journal on reopen).

## What the app does automatically

`AutorotaAppApp.init()` runs a two-pass open:

1. `autorotaInitDb()` — try the existing DB.
2. On failure: `autorotaQuarantineDatabase(...)` then `autorotaInitDb()` again
   against a fresh empty file.
3. If the second attempt also fails: `DatabaseRecoveryView` is shown with
   the original error and a **Reset & start fresh** button (which calls
   `autorotaQuarantineDatabase` again before asking the user to relaunch).

So in most cases the user can resolve corruption without manual intervention.

## When manual intervention is needed

If the user reports they keep seeing the recovery view (the second open
also fails), the FS itself is broken, the disk is full, or the parent
directory has the wrong permissions.

1. Ask for the **error detail** shown in the recovery view (it's
   `textSelection(.enabled)` so they can copy it). Common codes:
   - `DbConnectionFailed: file is not a database (code 26)` → file replaced
     by binary garbage; quarantine should fix.
   - `DbConnectionFailed: disk I/O error` → disk full or sandbox locked.
   - `DbConnectionFailed: permission denied` → reinstall, sandbox got
     into a bad state.
2. Ask the user to send you the quarantined `db.corrupt-<ts>.sqlite` (it's
   in the same directory as `autorota.db`). You may be able to recover
   data from it via:
   ```bash
   sqlite3 db.corrupt-<ts>.sqlite ".recover" > recovered.sql
   sqlite3 fresh.db < recovered.sql
   ```
3. If there's anything to import back, see
   [customer-data-extraction.md](customer-data-extraction.md).

## Prevention

- Migrations now run inside per-statement transactions (PR4) so a partial
  schema change can no longer leave the file half-applied.
- `PRAGMA foreign_key_check` runs once after every `connect()` and refuses
  to return a pool with violating rows — surfaces silent corruption from
  earlier writes that ran with `foreign_keys=OFF`.
