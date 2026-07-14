# Rust engine performance roadmap

Forward-looking plan for the next round of scheduler perf work, written after the
2026-07-14 pass that made `schedule_pure` ~3–4× faster (dense availability,
candidate-pool reuse, `ShiftCtx` hoisting, thin-LTO). See
`docs/sessions/2026-07-14-rust-engine-perf.md` for that work and
`docs/perf-testing.md` for how to run the benches.

Everything here must preserve **byte-identical scheduling output** — the
scheduler is deterministic and guarded by `tests/scheduler_invariants_test.rs`
plus the golden/determinism tests. Bench each change against a saved criterion
baseline (`--save-baseline` / `--baseline`).

## The headline: the bottleneck has moved

`schedule_pure` (the pure two-pass algorithm) is now ~4× faster. By Amdahl, the
real end-to-end cost of a "generate rota" call from the app is no longer
dominated by the algorithm — it has shifted onto the **async `schedule`
wrapper** (`crates/autorota-core/src/scheduler/mod.rs`, `schedule()`), which:

1. loads shifts / employees / assignments / overrides from SQLite,
2. **deserializes each employee's availability from a JSON string**
   (`Availability::from_json`, serde) — one per employee, and
3. inserts new assignments in a transaction.

None of this is measured: `docs/perf-testing.md` lists the async DB-roundtrip
bench as an explicit MVP non-goal. **That decision should be reversed** — it is
now the single highest-value *unmeasured* surface. Measure it before optimizing
anything else in this list, so priorities are driven by data rather than by the
pure micro-benches (which no longer represent a real call).

## Tier 1 — highest ROI

### 1. Index-based, hash-free `SchedulerState`

`SchedulerState` (`scheduler/mod.rs`) holds four `id`-keyed collections —
`weekly_hours: HashMap<i64,f32>`, `daily_hours: HashMap<(i64,NaiveDate),f32>`,
`shift_assignments: HashMap<i64,HashSet<i64>>`, `intervals: HashMap<i64,Vec<..>>`.
Now that availability probing is cheap, these `HashMap` lookups are the dominant
per-candidate cost in the inner loop (`is_eligible` alone does several).

Refactor the scheduler to work in terms of an employee **index** (position in the
`employees` slice) rather than `id`:

- `weekly_hours: Vec<f32>`, `intervals: Vec<Vec<(NaiveDateTime,NaiveDateTime)>>`,
  `shift_assignments` per shift as a `Vec<bool>`/bitset or `Vec<u32>` of indices,
  `daily_hours` keyed by `(emp_idx, day_offset_within_week)`.
- Build an `id → index` map **once** — needed only to ingest Pass-1 overrides
  (`existing_assignments` carry ids). Everything after works on indices.
- Candidate pools become `Vec<usize>` (or `Vec<(usize,&Employee)>`).

This removes hashing from the innermost loop entirely. Employee ids in real data
can have gaps (autoincrement + soft-deletes), so index ≠ id — the id→index map is
required, not optional. Estimated another **1.5–2×** on `schedule_pure`.

Guardrail: implement behind the same public signature, keep the map-based version
around briefly, and add the differential test in item 8 before deleting it.

### 2. Bench and optimize the async `schedule` path

Add a bench (criterion with `async_tokio`, already a dev-dep, or a tokio
`#[bench]`-style harness) that seeds a `SqlitePool` via
`testutil::corpus::seed_corpus_into_pool` and times the full
`schedule(&pool, rota_id)`. This captures query + deserialize + insert.

Likely finding: `Availability::from_json` per employee dominates. Options, in
increasing order of blast radius:

- Deserialize availability lazily / only for employees that survive a cheap
  pre-filter (rarely applicable — the scheduler needs all of them).
- Store availability as a **compact fixed-width blob** (168 bytes:
  `[[u8;24];7]`, 1 byte or 2 bits per cell) in a `BLOB` column instead of a JSON
  `TEXT` column, decoded with zero parsing. This is a DB-schema + migration
  change and touches the sync payload format — weigh against
  `project_dense_availability` (sync three-way merge compares serialized
  availability). Do the async bench first to confirm the cost is real before
  taking on a migration.

## Tier 2 — solid, contained

### 3. Pre-sort each shift's pool once, consume in order

`best_candidate` (`scheduler/mod.rs`) re-scans and re-scores the entire pool on
every slot. Within a single shift's fill, an **unpicked** candidate's
`(score, tiebreak)` and eligibility are invariant — only the just-picked
employee's hours/intervals change, and that employee leaves the pool. So:

- Sort the pool once per shift by `(score, tiebreak)` descending.
- Walk it in order, skipping already-picked and (in stage 1) role-mismatched
  candidates, until slots fill.

Turns per-shift fill from O(slots · pool) score computations into
O(pool · log pool) + O(pool). Must reproduce the exact `min_by` selection (first
maximal element — stable). The two-stage role logic needs care: stage 1 still
picks the largest-deficit role first, but now finds the first eligible holder in
the pre-sorted order rather than re-scoring.

### 4. Precompute per-run per-employee name + role mask

`record_assignment` calls `Employee::display_name()` — a `format!` heap
allocation — per assignment. `has_role` is a linear `Vec<String>` scan with
string compares in the role loops. At the top of `schedule_pure`, precompute:

- `names: Vec<String>` (one `display_name()` per employee), reused on assignment.
- `role_masks: Vec<u64>` with an interned `role → bit` index built from the
  closed role set; `has_role` becomes a bit test.

Keep the `String`-based public API on `Employee`; this is a scheduler-local view.
Low individual payoff but removes the only per-assignment allocation and the
string compares — cheap and clean once item 1 is already indexing by position.

## Tier 3 — larger / optional

### 5. Parallelize pool construction (rayon)

The difficulty/pool pass builds each shift's eligible pool independently against
a read-only post-Pass-1 state — embarrassingly parallel across shifts. The greedy
**fill** must stay sequential (a shift's assignment consumes hours that constrain
later shifts) to keep output deterministic, so only parallelize the pool build.
Adds a `rayon` dep and a deterministic `collect`. Measure against
`schedule_pure_weeks/12` (the largest corpus) first; for ~40 shifts the win is
marginal, but multi-week / large rosters could benefit.

### 6. FFI boundary micro-benches

Also an MVP non-goal today. With the core fast, UniFFI marshalling of large
assignment/employee vectors across the Swift boundary may now be a visible share
of a real call. Measure the per-call cost of the FFI conversions
(`employee_to_ffi`, `availability_to_slots`, assignment vecs) before optimizing.

## Harness / infra follow-ups

### 7. Persistent perf trend baseline

The CI gate added this session is same-run only (base vs PR on one runner) — it
catches a single PR's regression but has no history, so slow drift across many
small PRs is invisible. A stored `main` baseline (a `critcmp` artifact keyed by
commit, or `github-action-benchmark` with a gh-pages/cache store) would catch
drift. Currently a documented non-goal; revisit if drift shows up.

### 8. Differential test before the index refactor

Before item 1, add a test that runs both the current map-based `SchedulerState`
and the new index-based one over many random corpora
(`generate_corpus_with(..seed..)`) and asserts identical `ScheduleResult`
(assignments in order + warnings). Cheap insurance that the refactor is
output-preserving, beyond the fixed invariant suite.

## Suggested order

1. Item 2 (async bench) — get the data that confirms where real cost is.
2. Item 8 (differential test) — safety net.
3. Item 1 (index-based state) — biggest pure-algorithm win left.
4. Items 3 + 4 — contained follow-ons once indexing is in place.
5. Reassess Tier 3 / item 2's blob-storage change against fresh measurements.
