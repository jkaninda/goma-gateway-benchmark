#!/usr/bin/env python3
"""Busy fraction of a set of CPUs between two /proc/stat snapshots.

    snap=$(python3 cpubusy.py snap 0-1,4-7)     # "busy_ticks total_ticks"
    ...                                          # run the load
    python3 cpubusy.py since 0-1,4-7 "$snap"     # prints e.g. 0.734

The traffic scenario uses it on LOAD_CPUS: if the load generator and the
origin were near 100% busy, a gateway's throughput at that point was capped by
the load side, not by the gateway. "all" (or an empty list) means every CPU.
"""
import sys


def parse_list(spec):
    if not spec or spec == "all":
        return None
    cpus = set()
    for part in spec.split(","):
        if "-" in part:
            a, b = part.split("-")
            cpus.update(range(int(a), int(b) + 1))
        else:
            cpus.add(int(part))
    return cpus


def snapshot(cpus):
    busy = total = 0
    with open("/proc/stat") as fh:
        for line in fh:
            if not line.startswith("cpu") or line.startswith("cpu "):
                continue
            f = line.split()
            if cpus is not None and int(f[0][3:]) not in cpus:
                continue
            # user nice system idle iowait irq softirq steal (guest is in user)
            v = [int(x) for x in f[1:9]]
            idle = v[3] + v[4]
            total += sum(v)
            busy += sum(v) - idle
    return busy, total


if __name__ == "__main__":
    mode, cpus = sys.argv[1], parse_list(sys.argv[2])
    busy, total = snapshot(cpus)
    if mode == "snap":
        print(busy, total)
    else:
        b0, t0 = (int(x) for x in sys.argv[3].split())
        dt = total - t0
        print(f"{(busy - b0) / dt:.3f}" if dt > 0 else "")
