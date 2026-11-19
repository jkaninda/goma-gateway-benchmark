#!/usr/bin/env python3
"""Turn a results/<run-id>/ directory of CSVs into summary.md.

Every number in the report comes from here, so the report can be regenerated
from the raw CSVs without re-running anything.
"""
import csv
import os
import statistics
import sys

ORDER = ["goma", "goma-fast", "goma-reload", "traefik", "traefik-fast", "nginx", "haproxy"]
LABEL = {
    "goma": "Goma (file watch)",
    "goma-fast": "Goma (file watch, debounce 0s)",
    "goma-reload": "Goma (reload API)",
    "traefik": "Traefik",
    "traefik-fast": "Traefik (throttle 0s)",
    "nginx": "nginx",
    "haproxy": "HAProxy",
}


def rows(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as fh:
        return [r for r in csv.DictReader(fh) if any(v.strip() for v in r.values())]


def pct(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    k = (len(values) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def fnum(v, digits=0, dash="–"):
    if v is None or v != v:  # None or NaN
        return dash
    return f"{v:,.{digits}f}"


def table(header, body_rows):
    out = ["| " + " | ".join(header) + " |",
           "|" + "|".join(["---"] + ["---:"] * (len(header) - 1)) + "|"]
    for r in body_rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out) + "\n"


class Run:
    def __init__(self, d):
        self.d = d
        self.gateways = [g for g in ORDER if self._has(g)]

    def _has(self, gw):
        return any(f.endswith(f"-{gw}.csv") or f == f"footprint-{gw}.csv"
                   for f in os.listdir(self.d))

    def p(self, *parts):
        return os.path.join(self.d, *parts)

    # ---------------------------------------------------------------- env ---
    def env(self):
        path = self.p("env.txt")
        if not os.path.exists(path):
            return {}
        out = {}
        for line in open(path):
            if ":" in line:
                k, v = line.split(":", 1)
                out[k.strip()] = v.strip()
        return out

    def versions(self):
        return {r["gateway"]: r["version"] for r in rows(self.p("versions.csv"))}

    # -------------------------------------------------------- propagation ---
    def propagation(self):
        data = {}
        for gw in self.gateways:
            rs = rows(self.p(f"propagation-{gw}.csv"))
            if not rs:
                continue
            ms = [float(r["propagation_ms"]) for r in rs]
            ok = [v for v in ms if v >= 0]
            data[gw] = {
                "n": len(rs),
                "median": statistics.median(ok) if ok else None,
                "p99": pct(ok, 0.99) if ok else None,
                "max": max(ok) if ok else None,
                "timeouts": sum(1 for v in ms if v < 0),
                "bad": sum(1 for r in rs if r.get("error_codes", "").strip()),
                "codes": " ".join(sorted({c for r in rs
                                          for c in r.get("error_codes", "").split()})),
            }
        return data

    # -------------------------------------------------------- routechange ---
    def routechange(self):
        """Returns {pass_name: {gateway: row}} for whichever passes exist."""
        data = {}
        for name in ("fast", "slow"):
            per_gw = {}
            for gw in self.gateways:
                rs = rows(self.p(f"routechange-{name}-{gw}.csv"))
                if rs:
                    per_gw[gw] = rs[0]
            if per_gw:
                data[name] = per_gw
        return data

    # ----------------------------------------------------------- failover ---
    def failover(self):
        data = {}
        for gw in self.gateways:
            rs = rows(self.p(f"failover-{gw}.csv"))
            if not rs:
                continue
            row = dict(rs[0])
            tl = rows(self.p(f"failover-{gw}-timeline.csv"))
            # Longest run of consecutive seconds with at least one failure: how
            # long the gateway kept feeding the dead origin in one go.
            worst = cur = 0
            for t in tl:
                if int(t["failed"]) > 0:
                    cur += 1
                    worst = max(worst, cur)
                else:
                    cur = 0
            row["worst_streak_s"] = worst
            row["seconds_with_failures"] = sum(1 for t in tl if int(t["failed"]) > 0)
            data[gw] = row
        return data

    # ---------------------------------------------------------- routescale --
    def routescale(self):
        data = {}
        for gw in self.gateways:
            res = rows(self.p(f"routescale-{gw}-resources.csv"))
            phases = {r["phase"]: (int(r["start_ms"]), int(r["end_ms"]))
                      for r in rows(self.p(f"routescale-{gw}-phases.csv"))}
            if not res or not phases:
                continue
            def window(name):
                if name not in phases:
                    return []
                a, b = phases[name]
                return [r for r in res if a <= int(r["unix_ms"]) <= b]
            entry = {"phases": {}}
            for name in ("baseline", "create", "churn", "settle", "deleted"):
                w = window(name)
                if not w:
                    continue
                cpu = [float(r["cpu_cores"]) for r in w]
                rss = [float(r["rss_mb"]) for r in w]
                entry["phases"][name] = {
                    "seconds": (phases[name][1] - phases[name][0]) / 1000,
                    "cpu_mean": statistics.mean(cpu),
                    "cpu_peak": max(cpu),
                    "rss_mean": statistics.mean(rss),
                    "rss_peak": max(rss),
                    "rss_end": rss[-1],
                }
            can = rows(self.p(f"routescale-{gw}-canary.csv"))
            entry["canary"] = can[0] if can else None
            meta = rows(self.p(f"routescale-{gw}.csv"))
            entry["meta"] = meta[0] if meta else None
            data[gw] = entry
        return data

    # ------------------------------------------------------------- traffic --
    def traffic(self):
        data = {}
        for gw in self.gateways:
            rs = rows(self.p(f"traffic-{gw}.csv"))
            if rs:
                data[gw] = {r["connections"]: r for r in rs}
        return data

    def traffic_cpu(self, gw, conns):
        rs = rows(self.p(f"traffic-{gw}-c{conns}-resources.csv"))
        if not rs:
            return None
        return statistics.mean(float(r["cpu_cores"]) for r in rs)

    # ----------------------------------------------------------- footprint --
    def footprint(self):
        data = {}
        for gw in self.gateways:
            rs = rows(self.p(f"footprint-{gw}.csv"))
            if rs:
                data[gw] = {r["routes"]: r for r in rs}
        return data


def render(run):
    env, vers = run.env(), run.versions()
    gws = run.gateways
    out = [f"# Goma Gateway benchmark — run `{env.get('run_id', '?')}`\n"]

    out.append("## What ran\n")
    out.append(table(["Component", "Version"],
                     [[LABEL.get(g, g), vers.get(g, "?")] for g in gws]
                     + [["fortio", vers.get("fortio", "?")]]))
    host = "Host: {cpus} vCPU ({model}, {arch}), {mem} MB RAM, {kernel}, runtime: {rt}.".format(
        cpus=env.get("cpus", "?"), model=env.get("model", "?"), arch=env.get("arch", "?"),
        mem=env.get("mem_total_mb", "?"), kernel=env.get("kernel", "?"),
        rt=env.get("runtime", "host"))
    gw_cpus = env.get("gw_cpus", "unpinned")
    if gw_cpus and gw_cpus != "unpinned":
        host += (f" The gateway is pinned to CPUs {gw_cpus} ({env.get('gw_cpu_count', '?')} cores); "
                 f"origins, fortio and the probers run on CPUs {env.get('load_cpus', '?')}.")
    else:
        host += " Nothing is pinned: load generator, gateway and origins share every CPU."
    out.append(host + "\n")

    # --- propagation --------------------------------------------------------
    prop = run.propagation()
    if prop:
        out.append("\n## Route propagation\n")
        out.append(table(["", "Median (ms)", "p99 (ms)", "Max (ms)",
                          "Routes answering non-404 while waiting", "Timeouts"],
                         [[LABEL.get(g, g), fnum(prop[g]["median"]), fnum(prop[g]["p99"]),
                           fnum(prop[g]["max"]), prop[g]["bad"], prop[g]["timeouts"]]
                          for g in gws if g in prop]))

    # --- route change -------------------------------------------------------
    rc = run.routechange()
    if rc:
        out.append("\n## Route changes\n")
        titles = {"fast": "Rapid changes", "slow": "Spaced-out changes"}
        for name, per_gw in rc.items():
            out.append(f"\n### {titles.get(name, name)}\n")
            body = []
            for g in gws:
                if g not in per_gw:
                    continue
                r = per_gw[g]
                flips = r.get("observed_flips", "")
                body.append([LABEL.get(g, g), fnum(float(r["requests"])),
                             fnum(float(r["errors"])), r["error_pct"],
                             r.get("codes", "") or "–",
                             r.get("served_by", "") or "–",
                             flips or "–"])
            total_changes = max((int(r.get("observed_flips") or 0)
                                 for r in per_gw.values()), default=0)
            out.append(table(["", "Requests", "Errors", "Error %", "Codes",
                              "Origins hit",
                              f"Changes seen by clients (of {total_changes})"], body))

    # --- failover -----------------------------------------------------------
    fo = run.failover()
    if fo:
        out.append("\n## Backend failover\n")
        out.append(table(["", "Requests", "Failed", "Failed %",
                          "Longest unbroken failure streak (s)", "Seconds with failures",
                          "Codes"],
                         [[LABEL.get(g, g), fnum(float(fo[g]["requests"])),
                           fnum(float(fo[g]["failed"])), fo[g]["failed_pct"],
                           fo[g]["worst_streak_s"], fo[g]["seconds_with_failures"],
                           fo[g].get("codes", "") or "–"]
                          for g in gws if g in fo]))

    # --- route scale --------------------------------------------------------
    rsc = run.routescale()
    if rsc:
        n = (rsc[gws[0]]["meta"] or {}).get("routes", "?") if gws[0] in rsc else "?"
        out.append(f"\n## Route scale ({n} routes)\n")
        for phase, title in (("create", "Creating the table"),
                             ("churn", "Churning the table"),
                             ("settle", "Steady state after churn"),
                             ("deleted", "After deleting every route")):
            body = []
            for g in gws:
                p = rsc.get(g, {}).get("phases", {}).get(phase)
                if not p:
                    continue
                body.append([LABEL.get(g, g), fnum(p["seconds"], 1),
                             fnum(p["cpu_mean"], 3), fnum(p["cpu_peak"], 2),
                             fnum(p["rss_mean"], 1), fnum(p["rss_peak"], 1)])
            if body:
                out.append(f"\n### {title}\n")
                out.append(table(["", "Seconds", "Mean CPU (cores)", "Peak CPU (cores)",
                                  "Mean RSS (MB)", "Peak RSS (MB)"], body))
        body = []
        for g in gws:
            m = rsc.get(g, {}).get("meta")
            if m:
                body.append([LABEL.get(g, g), m.get("routes", "–"),
                             m.get("churn_seconds", "–"), m.get("churn_batches", "–")])
        if body:
            out.append("\n### Churn batches completed in the fixed window\n")
            out.append("The churn loop runs for a fixed time, so a gateway whose commit is "
                       "expensive gets through fewer batches — and therefore applies fewer "
                       "changes — than one whose commit returns immediately.\n")
            out.append(table(["", "Routes", "Churn seconds", "Batches applied"], body))

        body = []
        for g in gws:
            c = rsc.get(g, {}).get("canary")
            if not c:
                continue
            body.append([LABEL.get(g, g), fnum(float(c["requests"])),
                         fnum(float(c["errors"])), c["error_pct"],
                         c.get("codes", "") or "–"])
        if body:
            out.append("\n### An untouched route, probed throughout the churn\n")
            out.append(table(["", "Requests", "Errors", "Error %", "Codes"], body))

    # --- traffic ------------------------------------------------------------
    tr = run.traffic()
    if tr:
        conns = sorted({c for g in tr for c in tr[g]}, key=int)
        out.append("\n## Traffic performance\n")
        out.append("\n### Throughput (req/s)\n")
        out.append(table([""] + [f"{c} conn" for c in conns],
                         [[LABEL.get(g, g)] + [fnum(float(tr[g][c]["qps"])) if c in tr[g] else "–"
                                               for c in conns] for g in gws if g in tr]))
        out.append("\n### p50 latency (ms)\n")
        out.append(table([""] + [f"{c} conn" for c in conns],
                         [[LABEL.get(g, g)] + [fnum(float(tr[g][c]["p50_ms"]), 2) if c in tr[g] else "–"
                                               for c in conns] for g in gws if g in tr]))
        out.append("\n### p99 latency (ms)\n")
        out.append(table([""] + [f"{c} conn" for c in conns],
                         [[LABEL.get(g, g)] + [fnum(float(tr[g][c]["p99_ms"]), 2) if c in tr[g] else "–"
                                               for c in conns] for g in gws if g in tr]))
        out.append("\n### Gateway CPU during each point (cores)\n")
        out.append("Gateway CPU is sampled during each point and requests per second are "
                   "divided by it. Absolute throughput depends on the host and on whether "
                   "the gateway was pinned away from the load generator; this ratio "
                   "travels better between machines.\n")
        body = []
        for g in gws:
            if g not in tr:
                continue
            cells = []
            for c in conns:
                cpu = run.traffic_cpu(g, c)
                cells.append(fnum(cpu, 2) if cpu else "–")
            body.append([LABEL.get(g, g)] + cells)
        out.append(table([""] + [f"{c} conn" for c in conns], body))

        if any(tr[g][c].get("load_cpu_busy") for g in tr for c in tr[g]):
            out.append("\n### Load-side CPU busy during each point (%)\n")
            out.append("Share of the load CPUs (fortio and the origin) in use. Near 100% means "
                       "that point was capped by the load generator rather than the gateway.\n")
            body = []
            for g in gws:
                if g not in tr:
                    continue
                cells = []
                for c in conns:
                    v = tr[g].get(c, {}).get("load_cpu_busy")
                    cells.append(fnum(float(v) * 100) if v else "–")
                body.append([LABEL.get(g, g)] + cells)
            out.append(table([""] + [f"{c} conn" for c in conns], body))

        out.append("\n### Throughput per core of gateway CPU (req/s per core)\n")
        body = []
        for g in gws:
            if g not in tr:
                continue
            cells = []
            for c in conns:
                cpu = run.traffic_cpu(g, c)
                if c in tr[g] and cpu:
                    cells.append(fnum(float(tr[g][c]["qps"]) / cpu))
                else:
                    cells.append("–")
            body.append([LABEL.get(g, g)] + cells)
        out.append(table([""] + [f"{c} conn" for c in conns], body))

        body = []
        for g in gws:
            if g not in tr:
                continue
            bad = []
            for c in conns:
                codes = tr[g].get(c, {}).get("codes", "")
                for part in codes.split():
                    code, _, cnt = part.partition(":")
                    if code != "200":
                        bad.append(f"{c} conn: {part}")
            body.append([LABEL.get(g, g), "; ".join(bad) if bad else "none"])
        out.append("\n### Non-200 responses under load\n")
        out.append(table(["", "Observed"], body))

    # --- upstream pooling ---------------------------------------------------
    pool = {r["gateway"]: r for r in rows(run.p("pooling.csv"))}
    if pool:
        out.append("\n## Upstream connection reuse\n")
        out.append("Counters are reset after a warm-up, so this column is *new* upstream "
                   "connections opened during the measured window. A gateway that does not "
                   "pool would open roughly one per request.\n")
        out.append(table(["", "Client connections", "Requests",
                          "New upstream connections"],
                         [[LABEL.get(g, g), pool[g]["client_connections"],
                           fnum(float(pool[g]["requests"])),
                           fnum(float(pool[g]["upstream_connections"]))]
                          for g in gws if g in pool]))

    # --- footprint ----------------------------------------------------------
    fp = run.footprint()
    if fp:
        steps = sorted({s for g in fp for s in fp[g]}, key=int)
        out.append("\n## Idle footprint\n")
        out.append("\n### Resident memory when idle (MB)\n")
        out.append("RSS is summed across the process tree, so a multi-process gateway "
                   "(nginx, HAProxy) has its shared pages counted once per process and is "
                   "overstated relative to the single-process Go gateways. Process counts "
                   "are in the table below.\n")
        out.append(table([""] + [f"{s} route(s)" for s in steps],
                         [[LABEL.get(g, g)] + [fnum(float(fp[g][s]["idle_rss_mb"]), 1)
                                               if s in fp[g] and fp[g][s]["idle_rss_mb"] else "–"
                                               for s in steps] for g in gws if g in fp]))
        out.append("\n### Processes\n")
        out.append(table([""] + [f"{s} route(s)" for s in steps],
                         [[LABEL.get(g, g)] + [fp[g][s]["procs"] if s in fp[g] else "–"
                                               for s in steps] for g in gws if g in fp]))
        out.append("\n### Time from exec to serving the last route in the table (ms)\n")
        out.append("The harness polls every 10 ms, so values in the low tens of "
                   "milliseconds are at the measurement floor.\n")
        out.append(table([""] + [f"{s} route(s)" for s in steps],
                         [[LABEL.get(g, g)] + [fnum(float(fp[g][s]["startup_ms"]))
                                               if s in fp[g] else "–"
                                               for s in steps] for g in gws if g in fp]))
        body = []
        for g in gws:
            if g not in fp:
                continue
            cells = []
            for s in steps:
                r = fp[g].get(s)
                if not r:
                    cells.append("–")
                    continue
                mark = " (SIGKILL)" if r.get("needed_sigkill") == "1" else ""
                cells.append(fnum(float(r["shutdown_ms"])) + mark)
            body.append([LABEL.get(g, g)] + cells)
        out.append("\n### Time to release the port after SIGTERM (ms)\n")
        out.append(table([""] + [f"{s} route(s)" for s in steps], body))

    # --- shutdown -----------------------------------------------------------
    sd = {}
    for r in rows(run.p("shutdown.csv")):
        sd.setdefault(r["gateway"], {})[r["case"]] = r
    if sd:
        out.append("\n## Graceful shutdown\n")
        out.append("SIGTERM the moment the listener opens, SIGTERM when idle, and SIGTERM "
                   "while a client keep-alive connection is open. \"did not exit\" means the "
                   "process was still holding the port when the grace period ran out.\n")
        body = []
        for g in gws:
            if g not in sd:
                continue
            cells = []
            for case in ("early", "idle", "attached"):
                r = sd[g].get(case)
                if not r:
                    cells.append("–")
                elif r["exited"] == "yes":
                    cells.append(f'{float(r["ms"]):,.0f} ms')
                else:
                    cells.append(f'**did not exit** ({float(r["ms"]):,.0f} ms)')
            body.append([LABEL.get(g, g)] + cells)
        out.append(table(["", "Signalled at startup", "Idle", "Client connection open"], body))

    out.append("\n---\n\nGenerated by `scripts/summarize.py` from the CSVs in this directory.\n")
    return "\n".join(out)


if __name__ == "__main__":
    print(render(Run(sys.argv[1])))
