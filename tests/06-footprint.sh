#!/usr/bin/env bash
# Scenario 6 — Idle footprint and start/stop behaviour.
#
# No upstream equivalent as its own scenario; it isolates the numbers the
# upstream route-scale table reported as "mean memory", without the churn, and
# adds two things that matter to anyone running one of these as a process:
#
#   time to first served request from exec
#   time to exit on SIGTERM
#
# Measured at 1, 100 and 1000 routes. A gateway whose memory scales with the
# route table shows up here; so does one that takes seconds to shut down.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$BENCH_ROOT/lib/gateways.sh"

STEPS="${FOOTPRINT_STEPS:-1 100 1000}"
SETTLE="${FOOTPRINT_SETTLE:-15}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT"

for gw in $GATEWAYS; do
  csv="$OUT/footprint-$gw.csv"
  echo "routes,startup_ms,idle_cpu_cores,idle_rss_mb,peak_rss_mb,threads,procs,shutdown_ms,needed_sigkill" >"$csv"

  for n in $STEPS; do
    log "footprint: $gw ($n routes)"
    gw_prepare "$gw"
    for (( i = 1; i <= n; i++ )); do
      gw_route "$gw" "$i" "http://127.0.0.1:${BACKEND_PORTS[$(( i % 4 ))]}"
    done

    # Startup: from exec to the first 200 on the last route in the table, which
    # is the point at which the gateway is actually usable.
    ensure_port_free "$GW_PORT"
    t0=$(date +%s%3N)
    gw_start "$gw"
    wait_url_200 "$GW_URL/r-$n/" 120 || die "$gw: route $n never served at $n routes"
    startup=$(( $(date +%s%3N) - t0 ))

    sample="$OUT/footprint-$gw-$n-resources.csv"
    "$BIN_DIR/benchtool" sample -pid "$GW_PID" -interval 500ms -out "$sample" &
    sampler=$!
    sleep "$SETTLE"
    kill "$sampler" 2>/dev/null || true
    sleep 0.3

    t0=$(date +%s%3N)
    gw_stop "$gw"
    shutdown=$(( $(date +%s%3N) - t0 ))

    python3 - "$sample" "$n" "$startup" "$shutdown" "${GW_STOP_ESCALATED:-0}" >>"$csv" <<'PY'
import csv, statistics, sys
path, n, startup, shutdown, killed = sys.argv[1:6]
with open(path, newline="") as fh:
    rows = list(csv.DictReader(fh))
if not rows:
    print(f"{n},{startup},,,,,,{shutdown},{killed}")
else:
    cpu = [float(r["cpu_cores"]) for r in rows]
    rss = [float(r["rss_mb"]) for r in rows]
    print(f'{n},{startup},{statistics.mean(cpu):.4f},{statistics.mean(rss):.2f},'
          f'{max(rss):.2f},{rows[-1]["threads"]},{rows[-1]["procs"]},{shutdown},{killed}')
PY
  done
  python3 "$BENCH_ROOT/scripts/quicklook.py" footprint "$csv" >&2 || true
done
log "footprint: done"
