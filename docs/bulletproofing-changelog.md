# Bulletproofing pass — changelog

**Window:** 2026-04-28
**Scope:** seven PRs landed against `main` after `40d68c1`, executing the
prioritized hardening pass in `docs/bulletproofing-plan.md`.
**Total diff:** 32 files, +1,812 / -110 lines, 17 new tests.

## Why

A full-stack audit of the Rust core, FFI, Swift services / sync, SwiftUI
UI, and CI/release pipeline produced a P0–P7 punch list of correctness
bugs, sync hazards, validation gaps, and operational exposures. Findings
ranged from "import transactions silently no-op" (P0) to "no notarization
verify post-staple" (P6). This pass executes the prioritized fixes; the
audit lives at `docs/bulletproofing-plan.md` and the runbooks for ongoing
operations live at `docs/runbooks/`.

---

## What changed

### PR1 — `6c7dee3` — P0 correctness hotfix

Five user-visible correctness bugs and their regression tests:

- **Roster import transaction was a no-op.** The function opened a
  `tx` but the inner queries used `&pool`, so `tx.commit()` committed
  nothing and a mid-batch failure could not roll back. Refactored
  `insert_employee` / `get_employee` / `update_employee` to take
  `impl SqliteExecutor`, threaded `&mut *tx` through `apply_import`,
  added 3 regression tests including a transaction-respect white-box.
- **Remote deletions logged then dropped.** New core
  `apply_remote_deletion(table, id)` (soft-delete for employees /
  shift_templates, hard-delete elsewhere) plus FFI export, called from
  the sync engine's deletion loop. Local rows now disappear when CloudKit
  reports a peer deletion.
- **Silent merge drop in JSONSerialization.** `try?` replaced with a
  testable `encodeMergedFields` helper; failures propagate to the
  observable `lastSyncIssue` for UI banners instead of vanishing.
- **Force-unwraps in date arithmetic** (`RotaViewModel`,
  `ShiftHistoryViewModel`, `AnalyticsViewModel`) replaced with
  `guard let` early-returns.
- **App-init `fatalError` on DB open.** Now a two-pass recovery: try
  once, quarantine the file as `db.corrupt-<unix-ts>.sqlite` (plus
  WAL/SHM siblings), retry once, fall back to a new
  `DatabaseRecoveryView` (reset / email support) on the second failure.
  New helpers `autorotaDefaultDBURL()`,
  `autorotaQuarantineDatabase(at:)` in `AutorotaKit`.

Plus a `CLAUDE.md` errata (migration count `20 → 23`).

### PR2 — `9a7efa4` — P1 sync hardening

- **Conflict resolver — server-side "no opinion" vs explicit clear.**
  Server payload that omits a field used to clobber the local value
  because both produced `nil` from `dict[key]`. Now distinguishes
  absent (no opinion) from present-with-`NSNull` or `__deleted`
  sentinel (explicit clear).
- **Conflict resolver — typed equality.** Stringify fallback removed.
  Strict type-aware comparison only; `Bool` ⇄ `NSNumber` discriminated
  via `CFBooleanGetTypeID` so `true` no longer equals `NSNumber(1)`.
  Recursive equality for nested arrays / dicts.
- **Sync engine lifecycle.** `start()` is idempotent; previously a
  double-start registered two `.autorotaDataChanged` observers and
  produced N pushes per local mutation. Observer token now retained
  and removed in `stop()` / `deinit`.
- **O(n²) → O(n) tombstone lookup.** `getPendingTombstones()` hoisted
  out of the per-deletion loop and indexed as `[String: Int64]`.
- **`ExchangeRateService` hardening.** Silent `catch { }` replaced with
  `logger.warning` + observable `lastFetchError`. Hardcoded URL
  extracted to a static constant. New `ratesAreStale: Bool` (7-day
  threshold) so the UI can banner "rates may be outdated" without
  blanking the cached values.

Tests: 12-case three-way merge matrix.

### PR3 — `ae9d8de` — P2 validators + CSV injection escape

- **`models::validation` module.** `validate_employee` /
  `validate_shift_template` / `validate_shift` / `validate_availability`.
  Rejects: empty `first_name`, negative / NaN / infinite `hourly_wage`,
  out-of-range `max_daily_hours` and `target_weekly_hours`,
  `min_employees > max_employees`, zero-duration shifts, hour > 23.
  Wired into the FFI create/update entry points and into roster import
  per-row. 12 unit tests.
- **CSV formula injection.** `csv_escape` now neutralises OWASP
  prefixes (`=`, `+`, `-`, `@`, tab, CR) by inserting a leading `'`.
  Cells that ALSO need RFC 4180 quoting get both. 3 new tests.
- **`unreachable!()` after str match** in `import::roster::parse_roster`
  replaced with a defensive `Err`.

The wage `f32 → i64` minor units migration was deferred — boundary
validators now reject the failure modes (NaN, inf, negative) so the
remaining drift risk is theoretical, not present.

### PR4 — `94c74b3` — DB migration safety

- **Per-migration transaction wrapper.** Every migration script now
  runs through `run_migration_tx(pool, sql)` — `pool.begin()` plus
  `tx.commit()`. A partial DDL/DML failure rolls back instead of
  persisting a half-applied schema. Multi-statement blocks (006
  schema-create + two backfills; 016 fallback DROP + ALTER) share a
  single transaction.
- **`PRAGMA foreign_key_check` post-migrations.** After re-enabling
  `foreign_keys=ON`, abort `connect()` with a `Protocol` error listing
  the offending rows if any constraint is violated. Catches dangling
  refs that snuck in under the `foreign_keys=OFF` migration phase
  before they bite a runtime query.

Verified by every `test_pool()` call (276 tests run all 23 migrations
on every Rust test invocation).

### PR5 — `4f66f30` — Scheduler determinism

Two regression-guard tests in `tests/scheduler_determinism_test.rs`:

- 100 invocations against the same input must produce byte-identical
  output (compared via JSON serde).
- Reversing the employees vector OR the shifts vector must not change
  the output — picks should depend on score + tiebreak hash, not on
  insertion order.

The audit's claim of present non-determinism was unfounded for the
current code (every `HashMap` is used purely as a `.get()` lookup
table); the tests are a forward-looking regression guard.

### PR6 — `aaac8f5` — CI hardening

- **lefthook pre-push.** New `swift-test-macos` step runs
  `make swift-test-app-macos` when ViewModels / services / tests
  change. Trivial UI tweaks not gated.
- **Gatekeeper verify in `release.yml`.** After `xcrun stapler staple`,
  run `xcrun spctl --assess --type install --verbose=4` and fail the
  job if the output doesn't contain "accepted". Catches notarization
  regressions before users hit them.
- **iPhone SE compile-check job in `ci.yml`.** New
  `swift-iphone-se-compile` job runs `xcodebuild build` against the
  iPhone SE (3rd generation) simulator. Compile only, no tests, so
  the cost is one extra compilation. Catches layouts that overflow at
  4.7" / 375pt-wide.

Two P6 items deferred to future PRs: a real perf-baseline diff with
a > 10% regression alert (needs cache plumbing keyed by main SHA), and
a `cargo-fuzz` scheduler target (separate `fuzz/` crate + corpus +
weekly cron).

### PR7 — `e0a5c2e` — Operational runbooks

`docs/runbooks/` — four pages, action-first:

- `db-corruption-recovery.md` — what the app does automatically (the
  PR1 quarantine + retry flow), what to do when even the retry fails.
- `sync-divergence.md` — diagnose-then-remediate flow for the three
  observed failure shapes; includes a force-replay procedure
  (`UPDATE ... SET sync_status = 0`) and a nuclear CloudKit zone reset.
- `hot-fix-release.md` — captures the workflow used to ship PR1.
- `customer-data-extraction.md` — `.recover` + replay against a fresh
  DB, then export via the in-app sheet (now OWASP-safe per PR3).

---

## Test deltas

- Rust: **261 → 278** (+17). New: 3 import-rollback, 3 remote-deletion,
  12 validation, 3 CSV escape, 2 scheduler-determinism (and the
  validation module's 12 unit tests overlap with the +17 count).
- Swift: SyncConflictResolverTests added (12 cases), all green;
  `boolNotEqualToInt` caught a real bug in the discriminator that I
  fixed before shipping PR2.

## Pre-existing failures untouched

- `GatedAutorotaServiceTests/mutationsThrowWhenExpired()` —
  `LicenseGate.shared` singleton state leaks between tests. Not caused
  by this work; verified by running affected suites in isolation.
- `WeekNavigationPerfTests/testWeekNavigation_200Employees()` —
  perf-test flake (13s runtime).

Both flagged for follow-up.

## Intentional deferrals

- Wage `f32 → i64` minor-units migration (~150 touchpoints): boundary
  validators already reject NaN / infinity / negative on insert and
  update, which covers the integrity risk for fresh databases. Drop the
  migration entirely unless a real precision-drift incident materializes.
- Perf-job baseline diff with > 10% threshold alert: needs real
  baseline plumbing (cache `target/criterion/*/base/` keyed by main
  SHA, diff against PR head, comment on PR). Belongs in its own PR;
  flipping perf to fail-closed without a baseline would block on every
  flake.
- `cargo-fuzz` scheduler target: separate `fuzz/` crate, corpus,
  cron workflow. Out of scope here.
- P5 UI polish (localization sweep, Dynamic Type, weekday enum, a11y
  lint): the audit recommended dripping these in alongside other work,
  not blocking. None landed in this pass; the worklist still lives in
  `docs/bulletproofing-plan.md` § P5.

## How to ship this

Nothing has been pushed. When ready:

```bash
git push origin main
```

The seven commits land on `main` in order (`6c7dee3` first,
`e0a5c2e` last). PR1 is the only commit a hot-fix release would
include — see `docs/runbooks/hot-fix-release.md` for the procedure.
