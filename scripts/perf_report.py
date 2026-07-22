#!/usr/bin/env python3
"""Aggregate perf results into one report. Stdlib only.

Inputs (each optional — the report covers whatever exists):
  - Criterion:  target/criterion/**/new/estimates.json
  - Kit suite:  platforms/apple/AutorotaKit/.build/kit-perf.txt
                (teed `swift test` output with XCTest "measured [...]" lines)
  - UI suite:   an .xcresult bundle passed via --xcresult

Outputs:
  - Markdown table on stdout (and perf-report.md / perf-report.json under
    --out-dir, default repo root)
  - With PERF_RECORD=1 (or --record): appends a run line to perf/history.jsonl

Deltas are informational, computed against the most recent recorded history
entry from the same host. This script NEVER fails on a regression — perf is
report-only in this repo (see docs/perf-testing.md).
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


# ── Collectors ────────────────────────────────────────────────────────────────

def collect_criterion(root: Path) -> list[dict]:
    """Read every */new/estimates.json under target/criterion."""
    results = []
    crit = root / "target" / "criterion"
    if not crit.is_dir():
        return results
    for est in sorted(crit.rglob("new/estimates.json")):
        bench_dir = est.parent.parent
        bench_json = est.parent / "benchmark.json"
        name = None
        if bench_json.exists():
            try:
                name = json.loads(bench_json.read_text()).get("full_id")
            except (json.JSONDecodeError, OSError):
                pass
        if not name:
            name = str(bench_dir.relative_to(crit))
        try:
            data = json.loads(est.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        mean_ns = data.get("mean", {}).get("point_estimate")
        std_ns = data.get("std_dev", {}).get("point_estimate")
        if mean_ns is None:
            continue
        results.append({
            "suite": "criterion",
            "test": name,
            "metric": "time",
            "mean_s": mean_ns / 1e9,
            "stddev_s": (std_ns or 0) / 1e9,
            "n": None,
        })
    return results


# XCTest measurement line, e.g.:
# Test Case '-[AutorotaKitPerfTests.SchedulerPerfTests testRunSchedule200Employees]'
#   measured [Clock Monotonic Time, s] average: 0.123, relative standard
#   deviation: 4.567%, values: [0.1, 0.2, ...], ...
MEASURED_RE = re.compile(
    r"Test Case '-\[(?P<cls>[\w.]+) (?P<test>\w+)\]' measured "
    r"\[(?P<metric>[^\]]+)\] average: (?P<avg>[\d.]+), "
    r"relative standard deviation: (?P<rsd>[\d.]+)%"
    r"(?:.*?values: \[(?P<values>[^\]]*)\])?"
)


def collect_xctest_log(log: Path, suite: str) -> list[dict]:
    """Parse `measured [...]` lines from a teed swift test / xcodebuild log."""
    results = []
    if not log.is_file():
        return results
    for m in MEASURED_RE.finditer(log.read_text(errors="replace")):
        # The logged average is truncated to 3 decimals (sub-ms values print
        # as 0.000) — recompute from the full-precision values list.
        avg = float(m.group("avg"))
        n = None
        if m.group("values"):
            vals = [float(v) for v in m.group("values").split(",") if v.strip()]
            if vals:
                n = len(vals)
                avg = sum(vals) / n
        results.append({
            "suite": suite,
            "test": f"{m.group('cls').split('.')[-1]}.{m.group('test')}",
            "metric": m.group("metric"),
            "mean_s": avg,
            "stddev_s": avg * float(m.group("rsd")) / 100.0,
            "n": n,
        })
    return results


def collect_xcresult(bundle: Path) -> list[dict]:
    """Extract measurements via `xcresulttool get test-results metrics`
    (Xcode 16+ structured output: tests → runs → metrics with raw
    measurements). Failures collect nothing rather than erroring — the UI
    suite is optional input.
    """
    if not bundle.exists():
        return []
    try:
        out = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "metrics",
             "--path", str(bundle)],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if out.returncode != 0 or not out.stdout.strip():
        print(f"note: no metrics extracted from {bundle}", file=sys.stderr)
        return []
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return []

    results = []
    for t in data:
        test = t.get("testIdentifier", "unknown").replace("()", "").replace("/", ".")
        # Pool measurements across runs/devices per metric display name.
        pooled: dict[str, dict] = {}
        for run in t.get("testRuns", []):
            for m in run.get("metrics", []):
                name = m.get("displayName") or m.get("identifier") or "metric"
                unit = m.get("unitOfMeasurement", "")
                slot = pooled.setdefault(name, {"unit": unit, "values": []})
                slot["values"].extend(
                    float(v) for v in m.get("measurements", [])
                )
        for name, slot in pooled.items():
            vals = slot["values"]
            if not vals:
                continue
            mean = sum(vals) / len(vals)
            var = sum((x - mean) ** 2 for x in vals) / len(vals)
            # ", s" suffix keeps the report's time-unit detection consistent
            # with the XCTest log lines.
            results.append({
                "suite": "ui",
                "test": test,
                "metric": f"{name}, {slot['unit']}" if slot["unit"] else name,
                "mean_s": mean,
                "stddev_s": var ** 0.5,
                "n": len(vals),
            })
    return results


# ── History & report ──────────────────────────────────────────────────────────

def host_fingerprint() -> str:
    return f"{platform.node()}/{platform.machine()}"


def load_last_run(history: Path, host: str) -> dict:
    """Most recent recorded results per (suite, test, metric) for this host."""
    last: dict[tuple, dict] = {}
    if not history.is_file():
        return last
    for line in history.read_text().splitlines():
        try:
            run = json.loads(line)
        except json.JSONDecodeError:
            continue
        if run.get("host") != host:
            continue
        for r in run.get("results", []):
            last[(r["suite"], r["test"], r["metric"])] = r
    return last


def fmt_time(seconds: float) -> str:
    if seconds < 1e-6:
        return f"{seconds * 1e9:.0f} ns"
    if seconds < 1e-3:
        return f"{seconds * 1e6:.1f} µs"
    if seconds < 1:
        return f"{seconds * 1e3:.2f} ms"
    return f"{seconds:.3f} s"


def build_markdown(results: list[dict], last: dict) -> str:
    lines = [
        "# Perf report",
        "",
        f"_{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} · "
        f"{host_fingerprint()} · informational only, never a gate_",
        "",
        "| Suite | Test | Metric | Mean | ±σ | n | Δ vs last recorded |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in results:
        prev = last.get((r["suite"], r["test"], r["metric"]))
        if prev and prev.get("mean_s"):
            delta = (r["mean_s"] - prev["mean_s"]) / prev["mean_s"] * 100
            delta_s = f"{delta:+.1f}%"
        else:
            delta_s = "—"
        # Time metrics end in ", s" (XCTest) or are criterion benches; memory
        # metrics carry their own unit (kB) in the metric name.
        is_time = r["metric"].endswith(", s") or r["suite"] == "criterion" \
            or "time" in r["metric"].lower()
        mean = fmt_time(r["mean_s"]) if is_time else f"{r['mean_s']:,.1f}"
        sd = fmt_time(r["stddev_s"]) if is_time else f"{r['stddev_s']:,.1f}"
        n = r["n"] if r["n"] is not None else "—"
        lines.append(
            f"| {r['suite']} | {r['test']} | {r['metric']} | {mean} | {sd} | {n} | {delta_s} |"
        )
    if len(lines) == 7:
        lines.append("| — | no results found | | | | | |")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--xcresult", type=Path,
                    default=REPO / "perf-results.xcresult",
                    help=".xcresult bundle from a UI perf run (default: ./perf-results.xcresult if present)")
    ap.add_argument("--kit-log", type=Path,
                    default=REPO / "platforms/apple/AutorotaKit/.build/kit-perf.txt")
    ap.add_argument("--sync-log", type=Path,
                    default=REPO / ".build/sync-merge-perf.txt",
                    help="teed log of a sync-merge-perf run (default: .build/sync-merge-perf.txt if present)")
    ap.add_argument("--out-dir", type=Path, default=REPO)
    ap.add_argument("--record", action="store_true",
                    help="append this run to perf/history.jsonl (also PERF_RECORD=1)")
    args = ap.parse_args()

    results = collect_criterion(REPO)
    results += collect_xctest_log(args.kit_log, "kit")
    results += collect_xctest_log(args.sync_log, "app")
    results += collect_xcresult(args.xcresult)
    results.sort(key=lambda r: (r["suite"], r["test"], r["metric"]))

    history = REPO / "perf" / "history.jsonl"
    host = host_fingerprint()
    last = load_last_run(history, host)

    md = build_markdown(results, last)
    print(md)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "perf-report.md").write_text(md)
    (args.out_dir / "perf-report.json").write_text(json.dumps(results, indent=2) + "\n")

    if args.record or os.environ.get("PERF_RECORD") == "1":
        if not results:
            print("note: nothing to record", file=sys.stderr)
        else:
            history.parent.mkdir(parents=True, exist_ok=True)
            sha = subprocess.run(
                ["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"],
                capture_output=True, text=True,
            ).stdout.strip() or "unknown"
            entry = {
                "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "sha": sha,
                "host": host,
                "results": results,
            }
            with history.open("a") as f:
                f.write(json.dumps(entry) + "\n")
            print(f"recorded to {history.relative_to(REPO)}", file=sys.stderr)

    return 0  # report-only: never signals regression via exit code


if __name__ == "__main__":
    sys.exit(main())
