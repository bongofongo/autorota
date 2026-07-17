# Performance testing — reference

Deep reference for what's covered and how to read results. For the CI-facing summary (how `perf.yml` behaves, the soft regression gate, one-time Xcode setup, troubleshooting), see [`ci-cd-guide.md`](ci-cd-guide.md#reading-perf-checks) — that's the better starting point if you just hit a red Perf check.

## TL;DR

```bash
make bench              # Rust criterion benches (~3 min)
make swift-perf-ios     # XCUITest cold launch + week nav + render (~2 min)
make perf-all           # Both
```

> The canonical Swift perf path is iOS Simulator (`swift-perf-ios`). `swift-perf-macos` exists but requires a one-time Accessibility grant (see `ci-cd-guide.md`) and is omitted from `perf-all` and CI.

Rust results: `target/criterion/report/index.html`. Swift results: latest `.xcresult` bundle in `~/Library/Developer/Xcode/DerivedData/AutorotaApp-*/Logs/Test/`.

## What's covered

### Rust criterion benches

| Bench file | Group | Sizes | Notes |
|---|---|---|---|
| `crates/autorota-core/benches/scheduler.rs` | `schedule_pure` | 50 / 200 / 500 employees | Employee axis, 1 week |
| `crates/autorota-core/benches/scheduler.rs` | `schedule_pure_weeks` | 1 / 4 / 12 weeks @ 200 | Week (shift) axis — the dimension that grows workload |
| `crates/autorota-core/benches/scheduler.rs` | `schedule_pure_enriched` | 50 / 200 / 500 | Two-stage multi-role / wildcard / overnight fill |
| `crates/autorota-core/benches/hotpath.rs` | `for_window` | 200 | Availability scan (hottest inner primitive) |
| `crates/autorota-core/benches/hotpath.rs` | `has_role` | 200 | Role filter |
| `crates/autorota-core/benches/save.rs` | `snapshot_serialize` | 50 / 200 / 500 | `serde_json::to_string(&SaveSnapshot)` |
| `crates/autorota-core/benches/save.rs` | `diff_snapshots` | 200 | Edit Log diff path |
| `crates/autorota-core/benches/export.rs` | `export_build_grid` | 50 / 200 / 500 | Pure grid build |
| `crates/autorota-core/benches/export.rs` | `export_text` | csv / json / markdown @ 200 | Pure renderers |
| `crates/autorota-core/benches/export.rs` | `export_xlsx` | 200 | `rust_xlsxwriter` |
| `crates/autorota-core/benches/export.rs` | `export_pdf_weekly` | 200 | `printpdf`, sample size 20 |

All benches share a deterministic synthetic corpus: `crates/autorota-core/src/testutil/corpus.rs` (`generate_corpus(employees, weeks, seed)`). Same `(employees, weeks, seed)` tuple → byte-identical output; `weeks == 1` is byte-identical to the legacy single-week corpus so historical baselines stay comparable. `generate_corpus_with(CorpusConfig { enriched_shifts: true, .. })` adds the multi-role/wildcard/overnight templates the enriched bench exercises.

The `for_window` micro-bench isolates the scheduler's hottest inner primitive so an algorithm-level speedup there is attributable rather than hidden inside the whole-algorithm number.

### Swift XCUITest perf tests

| File | Test | Metrics |
|---|---|---|
| `LaunchPerfTests.swift` | `testColdLaunch_50Employees` / `testColdLaunch_200Employees` | `XCTApplicationLaunchMetric`, `XCTMemoryMetric` |
| `LaunchPerfTests.swift` | `testWarmLaunch_200Employees` | `XCTApplicationLaunchMetric(waitUntilResponsive: true)` |
| `WeekNavigationPerfTests.swift` | `testWeekNavigation_200Employees` | `XCTClockMetric`, `XCTCPUMetric`, `XCTMemoryMetric` |
| `RotaRenderPerfTests.swift` | `testFirstRotaRender_200Employees` / `_500Employees` | `XCTClockMetric`, `XCTMemoryMetric` |

The app interprets `--perf-seed-corpus <N>` as a launch argument and seeds an ephemeral SQLite database with `N` synthetic employees + a week of shifts before showing the UI. iCloud sync, onboarding, exchange-rate fetch are skipped. The seed defaults to `0xA070C0FFEE`; override with `--perf-seed <hex>`.

## How to run

### Rust

```bash
make bench-scheduler          # one bench file
make bench                    # all three
cargo bench -p autorota-core --bench scheduler -- --quick  # ~10s smoke
cargo bench -p autorota-core --bench scheduler schedule_pure/200  # one case
```

Output goes to `target/criterion/`. `target/criterion/report/index.html` is the human-readable view.

### Swift

```bash
make swift-perf-xcframework   # rebuild XCFramework with PERF_HELPERS=1
make swift-perf-ios           # iPhone 17 Pro Max simulator (canonical)
make swift-perf-macos         # macOS XCUITest — needs TCC grant, see ci-cd-guide.md
```

Behind the scenes: `PERF_HELPERS=1 bash scripts/build_xcframework.sh --debug` then `xcodebuild test -testPlan Perf -only-testing:AutorotaAppPerfTests SWIFT_ACTIVE_COMPILATION_CONDITIONS='PERF_HELPERS' …`.

## Reading the results

### Criterion

For each group, criterion reports:

- **`time`**: `[low, mean, high]` — 95% confidence interval over the sample.
- **`thrpt`**: throughput, derived from `Throughput::Elements`.
- **`change`** (after the first run): percent delta vs. the previous baseline. `[+/-X% (p = Y)]`.
- **Outlier classification**: low/high mild and severe. A handful of high-mild outliers is normal on shared CI runners.

A regression that needs investigation:

> `change: [+12.4% +14.1% +15.8%] (p = 0.00 < 0.05)` — performance has regressed.

vs. noise:

> `change: [-2.1% +0.8% +3.5%] (p = 0.42 > 0.05)` — no change in performance detected.

### XCTest measure blocks

In Xcode's test report, each `measure` block shows:

- **Average / std dev** across 10 iterations (default).
- **Baseline delta** if a baseline was recorded.
- Per-metric breakdown — clock time, memory peak, CPU.

To set a baseline: in Xcode, open the test result, click the metric, choose **Set Baseline**. Baselines persist in the xctestplan and are committed to the repo (`AutorotaAppPerfTests/Baselines/`).

## MVP non-goals

These are intentionally out of scope for the first cut. Re-open if a regression makes one necessary:

- **Instruments `.tracetemplate` checked in.** Open Instruments by hand for now.
- **FFI overhead micro-benches.** UniFFI per-call cost across the boundary.
- **Memory ceilings as hard CI gates.** Today memory is informational only.
- **Trend dashboard.** No `bencher.dev` / `github-action-benchmark` integration.
- **`save_restore_roundtrip` async DB bench.** Snapshot serialization covers the dominant cost; the round-trip is sqlite I/O.
- **DB query timings for individual hot queries.** The whole-pipeline benches surface query cost in aggregate.

## Refreshing baselines

xctestplan baselines drift as code changes legitimately make things faster or slower. Suggested cadence:

- **Quarterly** — open the latest passing perf run on `main`, set new baselines for any test whose green-mean has shifted ≥10% in either direction, commit the xctestplan diff.
- **After a known optimisation** — set the baseline immediately so future PRs are compared against the new floor.

Criterion auto-saves a baseline on every run; to compare against a named baseline:

```bash
cargo bench -p autorota-core --bench scheduler -- --save-baseline pre-refactor
# … make changes …
cargo bench -p autorota-core --bench scheduler -- --baseline pre-refactor
```

## Troubleshooting

See the [Troubleshooting index](ci-cd-guide.md#troubleshooting-index) in `ci-cd-guide.md` for the perf-related entries (missing XCTest target, Accessibility permission, sandbox errors, missing `seedPerfCorpus` symbol). One additional one not CI-specific:

**XCTest baseline shows ±100% delta on every run**: machine warmup. First run on a freshly booted Mac is always noisy — discard and re-record the baseline.

**Sample sizes are too small at 500 employees**: criterion adapts sample size automatically. For long benches (`export_pdf_weekly`) we cap `sample_size` to 20 explicitly; tweak that knob in the bench file if results are unstable.
