# Sync divergence remediation

**Trigger:** two devices on the same iCloud account show different
employees / shifts / assignments and refuse to converge after a manual
re-sync. Or: a record the user deleted on device A still appears on
device B.

## Background

Sync uses `CKSyncEngine` (CloudKit). The local→remote and remote→local
flows are in `Services/AutorotaSyncEngine.swift`; field-level merges go
through `Services/SyncConflictResolver.swift`.

Three failure shapes have been observed:

1. **Remote deletion never applied locally.** Pre-PR1 the engine logged
   the deletion and dropped it. Fixed in PR1 by routing every deletion
   through `applyRemoteDeletion(tableName:recordId:)`. If you see this on
   a current build, the local row exists with `sync_status=0` and there's
   no tombstone — see "Force-replay" below.
2. **Field-level conflict resolved the wrong way.** Post-PR2 the resolver
   distinguishes server "no opinion" (key absent) from "explicit clear"
   (key present with `NSNull` or the `__deleted` sentinel). If a single
   field looks wrong on one device, check the merge inputs:
   `getBaseSnapshots(tableName:, recordIds:)` returns the saved
   snapshot at last sync.
3. **Engine started twice → duplicate observers → N pushes per write.**
   Post-PR2 `start()` is idempotent; pre-PR2 a stale build could push
   the same record many times and overwhelm the conflict resolver.

## Diagnose

1. Confirm both devices are on the same iCloud account
   (Settings → Apple ID → device name).
2. On each device, check `lastSyncIssue` and `status` on the
   `AutorotaSyncEngine` (visible via the sync prompt or settings panel
   if surfaced — otherwise add a temporary debug view).
3. Check the local SQLite directly:
   ```bash
   sqlite3 ~/Library/Application\ Support/AutorotaApp/autorota.db \
     "SELECT id, first_name, deleted, sync_status, last_modified FROM employees ORDER BY last_modified DESC LIMIT 20;"
   ```
   - `sync_status = 0` → pending push
   - `sync_status = 1` → synced
   - `deleted = 1` → soft-deleted (still pushed for tombstone)
4. Inspect tombstones (rows queued for remote deletion):
   ```bash
   sqlite3 ... "SELECT * FROM tombstones LIMIT 50;"
   ```
5. Use Console.app, filter by subsystem `com.toadmountain.autorota` and
   category `sync`. Look for `Failed to apply remote ...` and
   `Failed to schedule record changes`.

## Force-replay

If a single device is stuck and you can tolerate re-uploading its full
state to iCloud:

1. Quit the app.
2. Bump every row's `sync_status` to 0 so the next push includes them:
   ```sql
   UPDATE employees       SET sync_status = 0;
   UPDATE shift_templates SET sync_status = 0;
   UPDATE rotas           SET sync_status = 0;
   UPDATE shifts          SET sync_status = 0;
   UPDATE assignments     SET sync_status = 0;
   UPDATE roles           SET sync_status = 0;
   UPDATE employee_availability_overrides SET sync_status = 0;
   UPDATE shift_template_overrides        SET sync_status = 0;
   ```
3. Relaunch. The sync engine on `start()` will queue every pending row.

If both devices are corrupt, pick the canonical one, then on the
other device:

1. Quit the app.
2. Delete the local DB (it'll be quarantined — see
   [db-corruption-recovery.md](db-corruption-recovery.md)).
3. Relaunch. Accept the iCloud sync prompt — the engine will pull the
   canonical state from CloudKit.

## Nuclear: reset CloudKit zone

Last resort. Loses all server state for this user.

1. Sign out the iCloud account on every device (or just toggle sync off
   in the app on every device).
2. In the developer dashboard at https://icloud.developer.apple.com,
   find the `AutorotaZone` record zone and delete it.
3. Re-enable sync on the canonical device first; let it finish pushing
   before enabling on others.
