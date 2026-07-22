# Performance testing

The complete guide to autorota's perf testing: what exists, how the machinery
actually works, how to run and read everything, and how to add or retire a
test. For a one-page command cheatsheet, see [`perf-runbook.md`](perf-runbook.md).

**House rules, up front:**

1. **Perf is report-only.** No perf number ever fails a build — not locally, not
   in CI. Regressions show up in reports and job summaries for a human (or
   Claude) to investigate.
2. **We never record Xcode baselines.** See
   [Why we don't use Xcode baselines](#why-we-dont-use-xcode-baselines).
3. **Timing numbers come from release Rust.** The default perf XCFramework for
   the FFI suite is a release build (`make kit-perf-xcframework`); debug-Rust
   timings are 10–50× off and only good for checking that a test runs at all.

## The three layers

Each layer answers a different question. Pick the lowest layer that can observe
your change — lower layers are faster, more stable, and easier to interpret.

| Layer | Question it answers | Where | Runtime | Stability |
|---|---|---|---|---|
| **criterion** (Rust) | "Is the algorithm itself faster/slower?" | `crates/autorota-core/benches/` | ~10s quick / ~3 min full | Best — pure CPU, statistical engine |
| **Kit FFI perf** (XCTest) | "Is the app-visible call faster/slower?" (FFI + SQLite + serialization included) | `platforms/apple/AutorotaKit/Tests/AutorotaKitPerfTests/` | ~3s + one-time XCFramework build | Good — no UI, no simulator |
| **XCUITest perf** | "Does the user feel it?" (launch, first render, navigation) | `platforms/apple/Apps/AutorotaApp/AutorotaAppPerfTests/` | ~2 min on simulator | Weakest — whole-OS noise, sim variance |

Rule of thumb: scheduler/db/export changes → criterion first, Kit second.
Service-layer or FFI-shape changes → Kit. SwiftUI/launch-path changes →
XCUITest, and only when you actually need the user-perceived number.

The same deterministic corpus feeds all three layers
(`crates/autorota-core/src/testutil/corpus.rs`, `generate_corpus(employees,
weeks, seed)`): criterion calls it directly, the Kit suite and the XCUITest
suite reach it through the `seedPerfCorpus` FFI helper. That means a 200-employee
number in one layer is directly comparable to a 200-employee number in another —
e.g. criterion `schedule_pure/500` ≈ 1.5 ms vs Kit `testRunSchedule500Employees`
≈ 19 ms tells you the FFI + SQLite round-trip costs ~17 ms on top of the pure
algorithm.

## How XCTest `measure` actually works

This is the part Xcode never explains. A perf test is a normal test whose body
wraps the code under measurement:

```swift
func testRunSchedule200Employees() throws {
    try PerfHarness.freshSeededDb(employees: 200, label: "sched")   // setup — NOT timed
    let week = PerfHarness.nextSchedulableWeek()
    measure(metrics: [XCTClockMetric()]) {
        _ = try! runSchedule(weekStart: week)                       // timed
    }
}
```

- `measure` runs the block **5 times** (XCTMetric API default) and reports the
  average, standard deviation, and the individual values.
- Everything outside the block is free; everything inside is timed. Put
  fixture setup outside.
- The block must be self-repeatable: iteration 2 runs against whatever state
  iteration 1 left behind. (`runSchedule` is safe — it deletes proposed
  assignments and re-materialises shifts on every call.)
- **Metrics** decide what gets recorded:

| Metric | Measures | Use when |
|---|---|---|
| `XCTClockMetric` | wall-clock time | default for everything |
| `XCTMemoryMetric` | physical memory delta + peak | large allocations (PDF render, big fetches) |
| `XCTCPUMetric` | CPU time/cycles | spot busy-waiting vs real work |
| `XCTApplicationLaunchMetric` | app launch duration (XCUITest only) | launch tests |
| `XCTOSSignpostMetric` | duration of a signpost interval | measuring one phase inside a bigger flow |

Each run prints a log line the report script parses:

```
… measured [Clock Monotonic Time, s] average: 0.017, relative standard deviation: 0.222%, values: [0.017403, …]
```

## Why we don't use Xcode baselines

Xcode's built-in comparison mechanism ("Set Baseline" in the result inspector)
stores expected values **per device model** in the test plan and fails the test
on ~10% deviation. That design caused all the historical pain:

- Baselines recorded on one Mac/simulator are wrong on any other, so Xcode
  nags that the test "doesn't work anymore" and offers to delete or re-record
  it. That prompt is the baseline machinery complaining — it was never a
  statement about the test being broken.
- A baseline miss is a hard test failure, which turns normal hardware variance
  into red CI.

So: **never click Set Baseline**, and if Xcode offers to re-record or bin a
baseline, decline. This repo replaces baselines with an external report:
`make perf-report` aggregates all layers into one table and computes deltas
against `perf/history.jsonl` (recorded runs, per host). Comparison lives
outside Xcode, is informational, and can't fail a build.

## Running everything

```bash
# Layer 1 — criterion
make bench-quick BENCH=scheduler   # ~10s sanity run (BENCH: scheduler|hotpath|save|export)
make bench                         # full suite, ~3 min
cargo bench -p autorota-core --bench scheduler schedule_pure/200   # one case

# Layer 2 — Kit FFI perf (build the release perf XCFramework once per Rust change)
make kit-perf-xcframework
make kit-perf                      # ~3s; log teed to platforms/apple/AutorotaKit/.build/kit-perf.txt
make sync-merge-perf               # sync 3-way merge (app target; macOS, no simulator); log teed to .build/sync-merge-perf.txt

# Layer 3 — XCUITest (simulator; slow — run when you need user-perceived numbers)
make swift-perf-ios                # iPhone 17 Pro Max sim; writes ./perf-results.xcresult, then auto-runs perf-report

# The one table
make perf-report                   # aggregates whatever outputs exist
PERF_RECORD=1 make perf-report     # …and appends this run to perf/history.jsonl
```

Record (`PERF_RECORD=1`) when the numbers are worth comparing against later: a
clean run on `main` after an optimisation, or right before starting one. Deltas
in the report are always against the last recorded run on the same machine.

## Reading the results

### Criterion output

```
schedule_pure/200  time: [770.2 µs 777.7 µs 785.9 µs]
                   change: [+12.4% +14.1% +15.8%] (p = 0.00 < 0.05)
                   Performance has regressed.
```

- `time` is a 95% confidence interval `[low, mean, high]`.
- `change` compares against the previous run of the same bench on this machine.
  **Read the p-value first**: `p < 0.05` means the change is statistically real;
  `(p = 0.42 > 0.05)` means noise, ignore the percentages.
- A few "mild outliers" are normal, especially on busy machines.
- HTML report with charts: `target/criterion/report/index.html`.

Named baselines for a refactor:

```bash
cargo bench -p autorota-core --bench scheduler -- --save-baseline pre-refactor
# … make changes …
cargo bench -p autorota-core --bench scheduler -- --baseline pre-refactor
```

### XCTest output

`make perf-report` renders the parsed table. Reading the raw line: `average` is
the mean of 5 iterations; `relative standard deviation` under ~10% means a
usable number, above ~20% means rerun on a quieter machine before believing a
delta. First run after boot is always noisy — discard it.

## What's covered

### criterion (`crates/autorota-core/benches/`)

| Bench file | Group | Sizes | Notes |
|---|---|---|---|
| `scheduler.rs` | `schedule_pure` | 50 / 200 / 500 employees | Employee axis, 1 week |
| `scheduler.rs` | `schedule_pure_weeks` | 1 / 4 / 12 weeks @ 200 | Week (shift) axis |
| `scheduler.rs` | `schedule_pure_enriched` | 50 / 200 / 500 | Two-stage multi-role / wildcard / overnight fill |
| `hotpath.rs` | `for_window` | 200 | Availability scan (hottest inner primitive) |
| `hotpath.rs` | `has_role` | 200 | Role filter |
| `save.rs` | `snapshot_serialize` | 50 / 200 / 500 | `serde_json::to_string(&SaveSnapshot)` |
| `save.rs` | `diff_snapshots` | 200 | Edit Log diff path |
| `export.rs` | `export_build_grid` | 50 / 200 / 500 | Pure grid build |
| `export.rs` | `export_text` | csv / json / markdown @ 200 | Pure renderers |
| `export.rs` | `export_xlsx` | 200 | `rust_xlsxwriter` |
| `export.rs` | `export_pdf_weekly` | 200 | `printpdf`, sample size 20 |

### Kit FFI perf (`AutorotaKit/Tests/AutorotaKitPerfTests/`)

| File | Tests | What it exercises |
|---|---|---|
| `SchedulerPerfTests.swift` | `testRunSchedule{50,200,500}Employees` | full `runSchedule` pipeline through FFI + SQLite |
| `ExportPerfTests.swift` | CSV export + PDF preview @ 200 | export pipeline incl. PDF render (`XCTMemoryMetric` too) |
| `SavePerfTests.swift` | `createSave` + `diffSaveVsPrevious` @ 200 | Edit Log snapshot + diff (`XCTStorageMetric` on create — disk writes = battery/stall cost) |
| `FetchPerfTests.swift` | `getWeekSchedule` + `listEmployees` @ 500 | screen-load read paths (`XCTMemoryMetric` on the 500-struct FFI crossing) |
| `HistoryPerfTests.swift` | `listAllShiftHistory` @ 500 | Shift History / analytics query over all assignments |

`PerfHarness.swift` gives every test a fresh seeded database (`switchDb` — the
FFI pool is a process-wide OnceLock, so databases are swapped, never re-inited).
The suite is excluded from `make swift-test-package` and only runs via
`make kit-perf`.

`SyncMergePerfTests` (in `AutorotaAppTests`, not the Kit — `SyncConflictResolver`
lives in the app target) measures the three-way merge over 500 conflicting
records. It self-skips unless `AUTOROTA_PERF=1`, which `make sync-merge-perf`
sets via xcodebuild's `TEST_RUNNER_` env passthrough.

### XCUITest perf (`AutorotaAppPerfTests`)

| File | Test | Metrics |
|---|---|---|
| `LaunchPerfTests.swift` | `testColdLaunch_{50,200}Employees` | `XCTApplicationLaunchMetric`, `XCTMemoryMetric` |
| `LaunchPerfTests.swift` | `testWarmLaunch_200Employees` | `XCTApplicationLaunchMetric(waitUntilResponsive: true)` |
| `WeekNavigationPerfTests.swift` | `testWeekNavigation_200Employees` | `XCTClockMetric`, `XCTCPUMetric`, `XCTMemoryMetric` |
| `RotaRenderPerfTests.swift` | `testFirstRotaRender_{200,500}Employees` | `XCTClockMetric`, `XCTMemoryMetric` |
| `ScrollPerfTests.swift` | `testEmployeeListScroll_500Employees` | `XCTOSSignpostMetric.scrollDeceleration/DraggingMetric` — hitch rate, the felt jank |

The app interprets `--perf-seed-corpus <N>` as a launch argument and seeds an
ephemeral SQLite database with `N` synthetic employees before showing the UI
(`#if PERF_HELPERS` branch in `AutorotaAppApp.swift`); iCloud sync, onboarding,
and exchange-rate fetch are disabled so runs are reproducible. These tests run
under the `Perf` test plan (`Perf.xctestplan`), which the `AutorotaApp` scheme
references alongside the default `AutorotaApp.xctestplan` — plain test runs
never boot the perf runner.

## Adding a perf test

1. **Pick the layer** (see decision table above). Kit FFI is the usual answer.
2. **Kit FFI recipe:** add a test to `AutorotaKitPerfTests` —
   `PerfHarness.freshSeededDb(employees:label:)` in setup, `measure(metrics:
   [XCTClockMetric()])` around the one call you care about. Corpus constants:
   `PerfHarness.corpusWeek` (the seeded rota week), `.corpusRotaId`,
   `.nextSchedulableWeek()` (for `runSchedule`, which refuses past weeks).
3. **criterion recipe:** add a function to the matching bench file in
   `crates/autorota-core/benches/`, reuse `generate_corpus`. Register in the
   file's `criterion_group!`.
4. Run it twice (warm-up + real), then `PERF_RECORD=1 make perf-report` to
   record the starting point.

## Retiring a perf test

Delete the test function (and its row in the tables above). Nothing else —
there are no baselines to clean up, and `perf/history.jsonl` keeps old entries
harmlessly. If Xcode ever prompts about a "missing baseline" for a deleted
test, that's stale UI state; the repo carries no baseline data.

## Non-goals

- Instruments `.tracetemplate` automation — open Instruments by hand.
- Memory ceilings as hard CI gates — memory stays informational.
- Hosted trend dashboards (`bencher.dev`, `github-action-benchmark`) —
  `perf/history.jsonl` + CI artifacts cover today's needs.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Kit perf target fails to **link**: undefined `…seed_perf_corpus…` | XCFramework built without perf helpers → `make kit-perf-xcframework` |
| Kit perf numbers look 10–50× slow | debug XCFramework → rebuild with `make kit-perf-xcframework` (release) |
| `runSchedule` throws "cannot generate schedule for current or past weeks" | use `PerfHarness.nextSchedulableWeek()`, not the corpus week |
| `UNIQUE constraint failed: roles.name` in a perf test | database reused across seeds — always go through `PerfHarness.freshSeededDb` |
| XCUITest runner "Early unexpected exit … never finished bootstrapping" on macOS | perf runner booted without sandbox/signing overrides — run `make swift-perf-macos`, never plain `xcodebuild test` with the perf target |
| Xcode offers to re-record or delete a baseline | decline; this repo never uses Xcode baselines (see above) |
| `testWarmLaunch_200Employees` fails with "Received unexpected number of metrics: 0 in iteration N" | known `XCTApplicationLaunchMetric(waitUntilResponsive:)` simulator flake — an iteration misses the launch signpost. Rerun; the report pools whatever iterations landed (`n` column shows how many) |
| macOS test build fails: "'scrollDecelerationMetric' is unavailable in macOS" | scroll signpost metrics are iOS-only — keep scroll tests wrapped in `#if os(iOS)` (see `ScrollPerfTests.swift`) |
| ±100% swings on every metric | machine warm-up or thermal throttling — rerun on a quiet, plugged-in machine |
| Unstable long benches (`export_pdf_weekly`) | `sample_size` capped at 20 in the bench file; raise locally if needed |
