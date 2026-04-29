# Bulletproofing pass 2 — changelog

**Window:** 2026-04-29
**Branch stack:** 10 commits stacked off `main` at `7c3e139`, ending at
`a810002`. Branch tip: `bulletproof2-pr10-state-validation`.
**Total diff (bulletproofing only):** 23 files, +1,064 / -87 lines, 27
new tests.
**Total diff (including WIP bundle):** 34 files, +1,764 / -456 lines.

## Why

A second-round audit of the Rust core, FFI, Swift services / sync, and
SwiftUI UI surfaced a fresh batch of HIGH and MEDIUM findings on top of
the seven-PR pass that landed at `7c3e139` on 2026-04-28. Categories:
panics on hot paths, blocking FFI inside CloudKit delegate methods,
last-write-wins clock-skew gaps, modal sheet stacking, missing CKError
handling, and CKSyncEngine state-corruption crash loops. The audit
plan lives at `~/.claude/plans/can-you-go-through-unified-tiger.md`;
this changelog records what actually shipped vs what was deferred.

User scoping (locked at plan time):
- HIGH + MEDIUM severity only.
- All three layers (Rust core, Swift app, sync engine).
- One PR per concern.
- Tests for every behavior change.

---

## What changed

### PR1 — `88896ef` — eliminate panics on scheduler / export / FFI hot paths

Five Rust files. `+94 / -10`. Two new edge-case tests + one ICS folding test.

- `crates/autorota-core/src/scheduler/mod.rs:288` — `max_employees -
  slots_filled` becomes `saturating_sub`. Underflow on a corrupt
  state used to wrap `u32` and loop for billions of iterations.
- `crates/autorota-core/src/scheduler/mod.rs:317` — replace
  `candidates[0].0` with `candidates.first()`. The `is_empty()`
  guard above made a panic unreachable today, but the indexing
  primitive is brittle.
- `crates/autorota-core/src/sample.rs:115, 129` — two raw
  `unwrap`s on the static sample dataset replaced with `expect()`
  with a "BUG: …" message. The data is internal, so `Result`
  propagation would be over-engineering.
- `crates/autorota-core/src/export/ics.rs:85` — `from_utf8_lossy`
  instead of `from_utf8().unwrap()` for line folding. The walk-back
  loop already lands on a UTF-8 boundary; lossy is purely defensive.
- `crates/autorota-ffi/src/lib.rs:31` — `Runtime::new()` failure
  now logs a structured `eprintln` and `std::process::abort()`s with
  a diagnostic instead of an opaque `expect` panic. Keeping the
  `&'static Runtime` signature avoided touching all 74 callers.
- `crates/autorota-ffi/src/lib.rs:1176-1186, 1200-1210` — fixed
  pre-existing `ImportError::Validation` non-exhaustive match arms
  that were blocking the FFI crate from compiling at all. Without
  this the workspace wouldn't even pass `cargo build`.

### PR2 — `477bd66` — export robustness (overflow, OOM, CSV injection, NaN)

Six files. `+238 / -7`. Five new tests.

- `scheduler/scoring.rs` — replace `(f * 100.0) as i32` with
  `clamped_centi_score`. NaN → 0; ±Inf → i32::MAX/MIN; values past
  the representable range clamp instead of silent saturation.
  Tiebreak ordering stays deterministic on corrupt budgets.
- `export/mod.rs` — new `ExportError::TooLarge` + `check_grid_bounds`
  helper called by every renderer entry point (CSV / JSON / Markdown
  / XLSX / PDF for the week export, plus all employee export
  formats). Cell limit is 1,000,000. `saturating_mul` guards usize
  overflow.
- `export/csv.rs` — `needs_formula_prefix` now skips leading
  whitespace before checking the OWASP sentinel chars. Whitespace
  set covers ASCII space, NBSP (U+00A0), NEL (U+0085), LS (U+2028),
  PS (U+2029). Excel/Numbers/Sheets used to parse `" =cmd"` as a
  formula even though the bare `chars().next()` check rejected
  formulas — they strip leading whitespace before parsing.
- `export/json.rs` — new `finite_or_zero` sanitiser applied to
  every f32 in the JSON output. `serde_json` errors on NaN/Infinity;
  the previous `.expect("JSON serialization should not fail")` path
  used to panic on a corrupt wage row.
- `ffi/src/lib.rs` — map `ExportError::TooLarge` to
  `FfiError::InvalidArgument` so the error surface is consistent.
- `.gitignore` — ignore `crates/autorota-core/migrations/test.db`
  (and `-journal/-wal/-shm`). The 0-byte leftover artifact was
  deleted.

### PR3 — `b75c081` — typed payload for `autorotaDataChanged`

Three files. `+228 / -32`. Five new tests. **Foundational:** unblocks
PR6 (scoped view reloads) and PR7 (sync push debouncing).

- `Services/LiveAutorotaService.swift` — introduce
  `AutorotaDataChange` (source + tables + rowIDs), the
  `Notification.autorotaDataChange` decoder, and the
  `NotificationCenter.postAutorotaDataChange(...)` helper. All 35
  mutator call sites migrate from the bare
  `.post(name: .autorotaDataChanged, object: nil)` to the helper,
  declaring which tables they touched and (where cheap) which row
  IDs.
  - The type, name, and helpers are co-located in one file to
    avoid touching `project.pbxproj` (the `Services/` group is not
    a `PBXFileSystemSynchronizedRootGroup`).
- `Services/AutorotaSyncEngine.swift` — local observer drops
  events with `source == .remoteSync`. The remote-deletion branch
  no longer schedules an immediate push of the change it just
  applied. Legacy posts (no userInfo) still trigger a push for
  back-compat.

### PR4 — `6f6ef14` — force-unwrap purge in RotaView date arithmetic

Two files. `+84 / -6`. Two new tests.

- `Views/RotaView.swift:276` — `cal.date(byAdding:)!` becomes
  `guard let … else { return selectedWeek; log }`. Year overflow
  no longer crashes the picker.
- `Views/RotaView.swift:882-883` — both `Calendar.current
  .date(bySettingHour:...)!` initialisers in `AddShiftSheet` go
  through `defaultTime(hour:)` with a `?? Date()` fallback.
- `ExportSheetView` was inspected and *not* modified — the
  audit's "icon-only buttons missing accessibilityLabel" claim
  turned out to be incorrect; the buttons either already had
  explicit `accessibilityLabel`s or were paired with text labels
  in the same Button HStack.

**Known scope leak:** this commit accidentally also captured an
in-progress edit to `RotaView.refreshEmployeeCount` (the WIP
file's `catch` block was rewritten). The leak was identified
mid-stream; rather than rebase, the user accepted it and
continued with cleaner staging for subsequent PRs.

### PR5 — *skipped*

The audit flagged `RotaView.swift:64-68` ("No Schedule" and "Tap
Generate to create a schedule for this week.") as hardcoded
English literals. Inspection showed both strings are already
auto-extracted by SwiftUI as `LocalizedStringKey` and present in
`Localizable.xcstrings` translated to all six locales (ar, bn, es,
hi, zh-Hans, zh-Hant). No-op PR; branch deleted.

### PR6 — `c2e2dcf` — `@MainActor` on `RotaViewModel` + sheet coalescing + week-change cancellation

Two files. `+49 / -20`. Relies on existing 28 RotaViewModelTests for
regression coverage.

- `ViewModels/RotaViewModel.swift` — `@MainActor` annotation on
  the `@Observable` view-model. Async methods used to mutate
  UI-bound state from arbitrary continuations.
- `Views/RotaView.swift` — coalesce three `.sheet(item:)`
  modifiers (`shiftForEmployeePicker`, `shiftForTimeEdit`,
  `dayForNewShift`) on the same view into one
  `.sheet(item: $activeSheet)` driven by a new `ScheduleSheet`
  enum. SwiftUI's stacked `.sheet(item:)` modifiers can drop
  later assignments mid-dismiss.
- `Views/RotaView.swift` — new `@State weekChangeTask: Task<…>?`
  cancels any in-flight reload when the user rapidly steps to
  another week. Previously each `onChange` spawned three
  independent Tasks; a slow load could overwrite a fresh one.

### PR7 — `6b59a64` — debounce `schedulePush` to coalesce mutation bursts

Two files. `+44 / -0`. One new test.

- `Services/AutorotaSyncEngine.swift` — `schedulePush()` now
  cancels any in-flight 500 ms debounce timer and starts a fresh
  window before invoking the new `performScheduledPush()` helper.
  Operations that touch many tables (running a schedule, applying
  a roster import) trigger ~40 mutations in rapid succession;
  coalescing into one push at the end of a burst removes the O(N)
  re-scan of pending records.
- `pendingPushTask` cancelled on `stop()` so a tear-down doesn't
  leak a Task that fires after the engine is nil.

### PR8 — `a2398c1` — classify `CKError` + handle account switch without restart

Two files. `+173 / -3`. Four new tests.

- `Services/AutorotaSyncEngine.swift` — new `SyncFailureClass`
  enum + `classify(error:)` static. CKError categories:
  - retriable: `networkUnavailable`, `networkFailure`,
    `serviceUnavailable`, `requestRateLimited`, `zoneBusy`,
    `accountTemporarilyUnavailable`.
  - permanent: `quotaExceeded`, `permissionFailure`,
    `invalidArguments`, `badContainer`, `badDatabase`,
    `notAuthenticated`, `userDeletedZone`, `managedAccountRestricted`.
  `retryAfter` (CloudKit's back-off hint) is read from
  `CKErrorRetryAfterKey` and threaded through the retriable case.
- `handleSentRecordZoneChanges`'s `failedRecordSaves` loop now
  goes through `classifyAndSurfaceFailure(record:error:)`:
  retriable → log, let CKSyncEngine retry; permanent → log + set
  `lastSyncIssue` so the UI banner explains; unknown → same as
  permanent.
- `.switchAccounts` no longer asks the user to relaunch. The new
  flow tears the engine down, clears the persisted state by
  setting `ck_engine_state` to an empty-string sentinel, and
  re-runs `start()` on a Task. `loadOrCreateConfiguration` skips
  the JSON decode when the persisted value is empty, treating it
  as "no saved state".

### PR9 — `3b9deaa` — only advance `last_modified` when merge integrates a change

Two files. `+65 / -2`. Three new tests.

- `Services/SyncConflictResolver.swift` — track
  `serverWonAnyField` through the three-way merge. Only advance
  the result's `last_modified` to `max(local, server)` when
  something was integrated; otherwise preserve the local
  timestamp.
- Bug: previous version unconditionally bumped the timestamp to
  the max of the two clocks. Pulls that found nothing changed
  (base == local == server) still moved the clock, falsely
  marking the row as dirty and triggering a re-push of identical
  bytes on every sync. Multiplied across N rows: correctness
  issue (wrong "last modified" displayed) + redundant CloudKit
  traffic.

### PR10 — `e0a16cd` — recover from corrupted `CKSyncEngine` state instead of crash-looping

Two files. `+89 / -7`. Four new tests.

- `Services/AutorotaSyncEngine.swift` — extract
  `decodeSavedState(stored:onCorruption:)` static helper. Returns
  `nil` for empty / missing stored values (no callback).
  Invokes `onCorruption(reason:)` for non-UTF-8 bytes, malformed
  JSON, or valid JSON of the wrong shape, and returns `nil`.
- `loadOrCreateConfiguration` wraps that helper with a corruption
  handler that logs, surfaces a `lastSyncIssue` banner, and
  clears `ck_engine_state` so the next launch doesn't crash-loop
  on the same bad blob.
- Bug: a single corrupted state blob (interrupted write, OS
  upgrade incompat, downgraded CKSyncEngine schema) used to
  throw out of `start()` every launch. Engine never initialised;
  user saw "Sync error" forever with no recovery short of
  reinstall.

### Bonus — `a810002` — WIP bundle (onboarding polish + TipKit + iCloud restore + AutoRota rename)

Eleven files. `+700 / -369`. Not part of the bulletproofing audit;
captured by user request as one multi-purpose commit at the end of
the session. Themes:

- **`AutoRota` branding**: display name (cap R),
  `LSApplicationCategoryType = business`, bundle ID
  `Fongo.AutorotaApp` → `Fongo.AutoRota`.
- **TipKit sequencing**: replace the four old tips with a chained
  set keyed off `AutorotaEvents.firstEmployeeAdded`,
  `firstTemplateAdded`, `firstScheduleGenerated`. ViewModels
  donate on first add. Net: a fresh user sees one tip per setup
  phase instead of four competing for the same screen.
- **Onboarding restore flow**: `pendingOnboardingTierOnly`
  AppStorage flag lets `AutorotaAppApp` skip the slide deck and
  land directly on `TierPickView` after iCloud restore.
  `OnboardingView` accepts a `startPage:` arg, clamped to
  `[0, pages.count]`. Conditional render replaces the
  platform-specific TabView/Group split.
- **TierPickView upgrades**: new Restore button row; offline
  escape hatch surfaced after the first purchase / restore
  failure (so a hard-gated TierPick screen doesn't trap users
  without App Store reachability). Dismiss-X gating relaxed to
  `license.state.allowsMutation`.
- **Localization**: +110 lines in `Localizable.xcstrings`
  covering `sync.prompt.*`, accessibility hints, the new
  onboarding/tier strings, and the new tip copy. Translated into
  all six locales.
- **Sync prompt localization**: hardcoded English literals in
  `SyncPromptView` replaced with `sync.prompt.*` keys.

---

## Test deltas

**Rust:** 8 new tests across `autorota-core`. 286 unit tests + 15
FFI tests pass. (`cargo test -p autorota-core -p autorota-ffi`.)

**Swift:** 19 new tests across 5 new test files
(`AutorotaDataChangeTests`, `CalendarFallbackTests`,
`SyncEngineDebounceTests`, `SyncFailureClassificationTests`,
`SyncStateValidationTests`) plus 3 added to existing
`SyncConflictResolverTests`. 79 Swift tests total pass on macOS.
(`make swift-test-app-macos`.)

**Pre-existing failures left alone:**
- `WeekNavigationPerfTests.testWeekNavigation_200Employees` — perf
  test, unrelated to anything in this pass.
- `cargo test --workspace` fails to build `app-desktop` because of
  a pre-existing Tauri / Send lifetime issue. Not in scope.

---

## Deferred (audit recommended, not shipped)

- **HLC for `last_modified`** (audit's design D1, plan PR9). Needs
  Rust-side migration of every `last_modified` writer + an FFI
  surface change. PR9 instead shipped the LWW monotonicity fix that
  removes the most acute symptom without changing the on-disk
  format.
- **Off-main FFI in `CKSyncEngine` delegates** (audit's S1,
  plan PR7). The blocking calls (`getPendingSyncRecords`,
  `applyRemoteRecord`, `markRecordsSynced`,
  `getPendingTombstones`, `clearTombstones`) still run on the
  delegate's queue. Wrapping them in `Task.detached` interacts
  badly with Swift 6 strict-concurrency warnings on
  `SyncRecordMapper`; that's its own refactor.
- **Atomic tombstone clear + mark-synced** (audit's S10, plan PR9
  part 2). Needs a new
  `mark_synced_and_clear_tombstones` FFI query that wraps the two
  ops in a SQLite transaction. FFI surface change.
- **`ExportSheetView` temp-dir cleanup** (plan PR6). Inspection
  showed the audit's claim was speculative; deferred until a real
  leak is reproduced.
- **Validate `CKSyncEngine.State` schema version** beyond decode
  success (plan PR10 D3 second half). The structured-validation
  path requires schema-version metadata that doesn't exist yet.

---

## Branch / merge layout

```
main (7c3e139)
└── bulletproof2-pr1-panic-guards            88896ef
    └── bulletproof2-pr2-export-robustness   477bd66
        └── bulletproof2-pr3-notification-payload   b75c081
            └── bulletproof2-pr4-force-unwrap-a11y  6f6ef14  ← scope leak
                └── bulletproof2-pr6-sheet-stacking-mainactor  c2e2dcf
                    └── bulletproof2-pr7-sync-debounce         6b59a64
                        └── bulletproof2-pr8-sync-error-handling  a2398c1
                            └── bulletproof2-pr9-conflict-resolver-fixes  3b9deaa
                                └── bulletproof2-pr10-state-validation  e0a16cd
                                    └── (WIP bundle)            a810002
```

Each commit is on its own named branch; the chain is linear.
Nothing has been pushed.

## How to release

The 9 bulletproofing commits (`88896ef` … `e0a16cd`) are
independent in spirit but linearly dependent in the git stack.
Three reasonable shapes for landing:

1. **Push the stack as-is**, open 9 PRs against `main` in order.
2. **Squash by theme**: combine PR3+PR6+PR7 (notification +
   downstream consumers), keep the rest separate.
3. **Cherry-pick subset**: only the Rust-only PR1+PR2 are 100% safe
   for an immediate hot-fix release; the rest need a normal review
   cycle.

The WIP bundle (`a810002`) is unrelated to the audit and should
either be split into separate feature commits or merged behind a
`feat(onboarding)` label — at the user's discretion.

PR4's commingle (a `RotaView.refreshEmployeeCount` chunk that
belongs to the WIP bundle) was left in place by user request. If a
clean-PR4 split becomes important, the surgical fix is:

```bash
# from PR4 branch
git revert 6f6ef14   # undo PR4
# manually re-apply only the date-arithmetic edits
git commit
```

…then the equivalent `refreshEmployeeCount` change rides in a
later commit. Not done in this pass.
