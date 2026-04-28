# Bulletproofing Plan

Short, prioritized hardening pass on existing code. No new features.
Findings from full-stack audit (Rust core, FFI, Swift services/sync, SwiftUI UI, CI/release).

---

## P0 — Correctness bugs (ship fix before next release)

### 1. Import transaction is a no-op
- `crates/autorota-core/src/import/roster.rs:67` — `let tx = pool.begin().await?;`
- Lines 75, 81, 86 call `queries::*_employee(pool, ...)` against the pool, **not** the tx.
- Commit at 91 is empty; rollback on mid-batch failure is impossible. Partial writes leak.

**Fix:** thread `&mut *tx` (or `tx.as_mut()`) through `get/insert/update_employee` calls; cover with a test that injects a failure on row N and asserts rows 0..N-1 are absent.

### 2. Remote deletions never applied
- `platforms/apple/Apps/AutorotaApp/Services/AutorotaSyncEngine.swift:226-229`
- Loop logs `Remote deletion:` then drops on the floor — never calls FFI to delete the row locally.
- Edited-elsewhere employee/shift stays alive after CloudKit deletes it. Permanent divergence.

**Fix:** call `applyRemoteDeletion(tableName:recordId:)` (add to FFI if missing). Add deleted-vs-edited test in `SyncConflictResolver` tests.

### 3. Silent merge drop
- `AutorotaSyncEngine.swift:208` — `try? JSONSerialization.data(...)` swallows error.
- If serialization fails, merged record is silently discarded. Conflict resolution "succeeds" without persisting.

**Fix:** propagate via `do/try/catch`; log + escalate to UI banner.

### 4. Date force-unwraps in hot path
- `RotaViewModel.swift:312, 339`, `ShiftHistoryViewModel.swift:67-68`, `AnalyticsViewModel.swift:168`
- `cal.date(byAdding:)!` and `empMap[key]!` will crash on bad data or stale cache. ISO8601 calendar is safe in practice but the pattern is fragile.

**Fix:** replace with `?? selectedWeekStart` / `guard let` early-return.

### 5. App-init `fatalError` with no recovery
- `AutorotaAppApp.swift:32` — DB init failure terminates with no UI.

**Fix:** show ErrorView with reset/repair option; log to a recoverable state (e.g. rename corrupt DB to `db.corrupt-<ts>`).

---

## P1 — Sync hardening

Group fix; one PR per layer.

### Conflict resolver
- `SyncConflictResolver.swift:44-48` — server-deleted field becomes nil indistinguishable from never-set.
- `SyncConflictResolver.swift:60-70` — `valuesEqual` stringifies; `1.0` and `1` collide; type drift.

**Fix:** explicit deletion sentinel (`{"__deleted":true}`); compare via `NSNumber.isEqual` for numerics, then string fallback only for strings.

### Sync engine lifecycle
- `AutorotaSyncEngine.swift:24-30` — observer registered in `start()`, never removed; double-start = duplicate observers.
- `:256-262` — O(n²) tombstone lookup in deletion loop.

**Fix:** guard re-entry; remove observer in `stop()`/`deinit`; batch-load tombstones once.

### Service notification audit
- `LiveAutorotaService.swift` — `diffRotaDetailed`/`diffRota` don't post `.autorotaDataChanged`. Fine if read-only but verify every mutator does post.

**Fix:** grep every `try ffiCall` in LiveAutorotaService; checklist mutators against notifications.

### Exchange rate fragility
- `ExchangeRateService.swift:43-44, 52-54` — hardcoded URL, errors silently swallowed, no stale-cache age limit.

**Fix:** stale-after threshold (e.g. 7 days) → show "rates may be outdated" banner; surface fetch error.

---

## P2 — Input validation pass (Rust core)

Single PR; centralise validators in `models/validation.rs`.

| Issue | Loc |
|---|---|
| Negative `hourly_wage` accepted | `models/employee.rs` |
| `min_employees > max_employees` accepted | `models/shift.rs` |
| Shift end ≤ start not validated; midnight wrap silent | `models/shift.rs:47-56` |
| Availability hour > 23 silently truncates | `models/availability.rs:91` |
| Zero-hour window returns "No" misleadingly | `models/availability.rs:112-123` |
| CSV formula injection (`=`/`+`/`-`/`@`) | `export/csv.rs:4-10` |
| `f32` wage drift across FFI | `autorota-ffi/types` |
| `unreachable!()` after exhaustive str match | `import/roster.rs:49` |
| `panic!`/`expect()` in JSON export on NaN | `export/json.rs:82,138` |

**Fix plan:** validators on `TryFrom<dto>`; CSV cell-prefix escape (`'` prefix per OWASP); migrate wage to `i64` minor units (cents) crossing FFI.

---

## P3 — DB & migration safety

- `db/mod.rs:36, 46, 59...` — migrations run as bare `execute()`, no per-migration tx wrapper. Mid-migration failure = inconsistent schema.
- No replay test from migration 001 → 023 on populated fixture data.
- FK pragma re-enabled at line 27 after migrations; 006 inserts roles without FK check.

**Fix:** wrap each migration in `BEGIN`/`COMMIT`; add integration test `tests/db_migration_replay.rs` that loads a v1 dump fixture and replays to head.

---

## P4 — Determinism

- `scheduler/mod.rs:302` — tiebreak hash deterministic but iteration over `HashMap` upstream is not. Verify all scheduler `HashMap` iterations are sorted before scoring.
- `export/grid.rs:93-95` — column order depends on HashMap.

**Fix:** swap to `BTreeMap` or `IndexMap` where order is observable; add a property test: same input → identical output across 100 runs.

---

## P5 — UI polish (low risk, high coverage)

### Localization gaps
Hard-coded English strings outside `Localizable.xcstrings`:
- `AnalyticsView.swift:101-104, 129, 200, 223, 241, 268`
- `ShiftTemplateListView.swift:27, 69, 110, 149, 154`
- `RotaView.swift:65-67, 107, 118`
- `OnboardingView.swift:369-407` (mockup labels)
- `ExportSheetView.swift:172, 207, 236`

**Fix:** sweep with `String Catalog → Add Missing`; lint script in CI to flag `Text("...")` literals containing > 1 word.

### Dynamic Type / a11y
- Fixed `.font(.system(size: ...))`: `SyncPromptView:10,56`, `TierPickView:56`, `RosterImportView:72,125`, `AllAvailabilitiesSetView:9`, `FloatingTabBar:44`, `TierInfoModal:34` (size 6!)
- Icon-only buttons missing `.accessibilityLabel`: `OverridesTabView:219, 310`

**Fix:** swap to `.font(.largeTitle).symbolRenderingMode(.hierarchical)` or scale via `@ScaledMetric`; sweep accessibility with the SwiftUI Accessibility Inspector.

### Day-of-week strings
- `RotaViewModel`/`AnalyticsViewModel` use `["Mon","Tue",...]` arrays — breaks non-EN locales.

**Fix:** introduce a `Weekday` enum with localized display name.

---

## P6 — Test & CI hardening

| Gap | Action |
|---|---|
| No fuzz target on scheduler | add `cargo-fuzz` job; weekly cron |
| No migration replay test | see P3 |
| No sync conflict integration test (3-way merge cases) | add `SyncConflictResolverTests` matrix |
| Lefthook pre-push skips Swift tests | add `make swift-test-app-macos` to pre-push |
| `cargo audit` only weekly | trigger on Cargo.lock change |
| Perf job has `continue-on-error: true`, no baseline diff | wire criterion baseline + alert on >10% regression |
| No notarization verify post-staple | add `spctl -a -t exec` step |
| No iPhone SE in CI matrix | add small-screen variant to compile-check |

---

## P7 — Operational docs

Missing runbooks:
- DB corruption recovery (rename → recreate → import last good save)
- Sync divergence remediation (force-replay from snapshot)
- Hot-fix release flow
- Customer data extraction from old schema

**Fix:** `docs/runbooks/` folder; one page per scenario.

---

## Suggested rollout

1. **Week 1:** P0 fixes + tests. Patch release.
2. **Week 2:** P1 sync hardening. Telemetry on conflict outcomes.
3. **Week 3:** P2 validation + P3 migrations behind feature gate; backfill.
4. **Week 4:** P4 determinism + P6 CI.
5. **Background:** P5 (UI polish) + P7 (docs) ship continuously.

Effort estimate: ~3-4 dev weeks total. P0 alone is ~1-2 days.
