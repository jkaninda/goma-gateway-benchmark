#!/usr/bin/env python3
"""One-line progress summaries printed while the suite runs.

Not the report — scripts/summarize.py builds that from the same CSVs. This just
gives the operator something to watch, and fails quietly if a file is short.
"""
import csv
import statistics
import sys


def pct(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def rows(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def propagation(path):
    rs = rows(path)
    ok = [float(r["propagation_ms"]) for r in rs if float(r["propagation_ms"]) >= 0]
    timeouts = sum(1 for r in rs if float(r["propagation_ms"]) < 0)
    bad = sum(1 for r in rs if r.get("error_codes"))
    if not ok:
        print("    no successful propagations"); return
    print(f"    median {statistics.median(ok):.0f} ms  p99 {pct(ok, 0.99):.0f} ms  "
          f"max {max(ok):.0f} ms  routes answering non-404 while waiting: {bad}"
          + (f"  timeouts: {timeouts}" if timeouts else ""))


def resources(path):
    rs = rows(path)
    cpu = [float(r["cpu_cores"]) for r in rs]
    rss = [float(r["rss_mb"]) for r in rs]
    if not cpu:
        print("    no samples"); return
    print(f"    cpu mean {statistics.mean(cpu):.3f} peak {max(cpu):.3f} cores  "
          f"rss mean {statistics.mean(rss):.1f} peak {max(rss):.1f} MB  samples {len(cpu)}")


def passthrough(path):
    for r in rows(path):
        print("    " + "  ".join(f"{k}={v}" for k, v in r.items() if v != ""))


if __name__ == "__main__":
    kind, path = sys.argv[1], sys.argv[2]
    try:
        {"propagation": propagation, "resources": resources}.get(kind, passthrough)(path)
    except Exception as exc:  # a quicklook must never fail a run
        print(f"    (quicklook: {exc})")
