# Perf runbook — one page

Commands only. Concepts, metrics, and troubleshooting live in
[`perf-testing.md`](perf-testing.md).

## Daily commands

| Command | What | Cost | Output lands in |
|---|---|---|---|
| `make bench-quick BENCH=scheduler` | quick criterion sanity (one bench) | ~10s | `target/criterion/` |
| `make bench` | all criterion benches | ~3 min | `target/criterion/` (+ `report/index.html`) |
| `make kit-perf-xcframework` | release PERF_HELPERS XCFramework | ~3–5 min, once per Rust change | `platforms/apple/AutorotaKit/XCFrameworks/` |
| `make kit-perf` | FFI hot-path suite | ~3s | `platforms/apple/AutorotaKit/.build/kit-perf.txt` |
| `make sync-merge-perf` | sync 3-way merge perf (macOS) | ~1 min | `.build/sync-merge-perf.txt` (feeds report) |
| `make perf-report` | one table from all of the above | ~1s | stdout + `perf-report.md` / `.json` |
| `PERF_RECORD=1 make perf-report` | …and record run to history | ~1s | `perf/history.jsonl` (committed) |
| `make swift-perf-ios` | XCUITest launch/render/nav/scroll-hitch on sim | ~5 min | `./perf-results.xcresult` (feeds report, auto-runs it) |

`BENCH` options: `scheduler`, `hotpath`, `save`, `export`.

## The loop for "did my change help?"

```bash
PERF_RECORD=1 make perf-report      # 1. record the before (run benches first if stale)
# … make the change …
make bench-quick BENCH=scheduler    # 2. re-run the affected layer
make kit-perf                       #    (and/or)
make perf-report                    # 3. read the Δ column
```

Δ is vs the last **recorded** run on this machine. Criterion additionally
prints its own `change: … (p = …)` line — trust it only when `p < 0.05`.

## When to use which layer

- Changed Rust algorithm/db/export code → `bench-quick`, then `kit-perf` to
  confirm the app-visible call moved too.
- Changed service layer / FFI shapes → `kit-perf`.
- Changed SwiftUI launch/render paths and you need the felt number →
  `make swift-perf-ios` (slow, noisy — last resort, not routine).

## Rules

- Perf never blocks a build. Red perf CI = read the report, not revert.
- Never record Xcode baselines (decline any "Set/re-record baseline" prompt).
- FFI timings only count from a release build (`make kit-perf-xcframework`).

## Guided walkthrough (live session outline)

To learn the system end-to-end, do this once with Claude:

1. Pick a hot path not yet covered (e.g. an analytics query).
2. Write a Kit `measure()` test together in `AutorotaKitPerfTests`.
3. `make kit-perf` → find your line, read average and stddev.
4. `PERF_RECORD=1 make perf-report` → record it.
5. Intentionally pessimise the code (add a sleep or O(n²) loop), rerun, and
   watch the Δ column catch it. Revert.
