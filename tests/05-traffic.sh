#!/usr/bin/env bash
# Scenario 5 — Traffic performance.
#
# Upstream equivalent: "Traffic performance" (v3). fortio with uncapped QPS for
# a fixed duration per point, a 100-byte payload, a single origin, one gateway at
# a time. As upstream, this is only looking for large outliers: the load
# generator, the gateway and the origin share the same CPUs, so the absolute
# numbers describe this machine and nothing else.
#
# Each point gets a short warm-up that is thrown away, so connection setup and
# the gateway's first-request work do not land in the measured window.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$BENCH_ROOT/lib/gateways.sh"

CONNS="${TRAFFIC_CONNS:-1 8 32 128 256}"
DUR="${TRAFFIC_DURATION:-20s}"
WARM="${TRAFFIC_WARMUP:-5s}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT"

[[ -x "$BIN_DIR/fortio" ]] || die "fortio not found at $BIN_DIR/fortio"

for gw in $GATEWAYS; do
  log "traffic: $gw (connections: $CONNS, ${DUR} per point)"
  gw_prepare "$gw"
  gw_route "$gw" 1 "http://127.0.0.1:9001"
  gw_start "$gw"
  wait_url_200 "$GW_URL/r-1/" 30 || die "$gw: /r-1/ never served"

  csv="$OUT/traffic-$gw.csv"
  echo "connections,qps,p50_ms,p75_ms,p90_ms,p99_ms,p999_ms,codes,mean_body_bytes,load_cpu_busy" >"$csv"

  for c in $CONNS; do
    sample="$OUT/traffic-$gw-c$c-resources.csv"
    "$BIN_DIR/fortio" load -c "$c" -qps 0 -t "$WARM" -quiet -nocatchup "$GW_URL/r-1/" >/dev/null 2>&1 || true

    "$BIN_DIR/benchtool" sample -pid "$GW_PID" -interval 500ms -out "$sample" &
    sampler=$!
    json="$OUT/traffic-$gw-c$c.json"
    # How busy the load side (fortio + origin) was during the point. Near 1.0
    # means this point was capped by the load generator, not the gateway.
    load_snap=$(python3 "$BENCH_ROOT/scripts/cpubusy.py" snap "${LOAD_CPUS:-all}")
    "$BIN_DIR/fortio" load -c "$c" -qps 0 -t "$DUR" -nocatchup -quiet \
      -p "50,75,90,99,99.9" -json "$json" "$GW_URL/r-1/" \
      >"$OUT/traffic-$gw-c$c.log" 2>&1 || true
    load_busy=$(python3 "$BENCH_ROOT/scripts/cpubusy.py" since "${LOAD_CPUS:-all}" "$load_snap")
    kill "$sampler" 2>/dev/null || true

    python3 - "$json" "$c" "$load_busy" >>"$csv" <<'PY'
import json, sys
path, conns, load_busy = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    d = json.load(fh)
dh = d["DurationHistogram"]
pcts = {int(round(p["Percentile"] * 10)): p["Value"] * 1000 for p in dh.get("Percentiles", [])}
def g(key):
    return f'{pcts.get(key, float("nan")):.3f}'
codes = " ".join(f"{k}:{v}" for k, v in sorted(d.get("RetCodes", {}).items()))
# fortio calls the response-size histogram "Sizes".
body = d.get("Sizes", {}).get("Avg", 0)
print(f'{conns},{d["ActualQPS"]:.0f},{g(500)},{g(750)},{g(900)},{g(990)},{g(999)},{codes},{body:.0f},{load_busy}')
PY
  done

  gw_stop "$gw"
  python3 "$BENCH_ROOT/scripts/quicklook.py" traffic "$csv" >&2 || true
done
log "traffic: done"
