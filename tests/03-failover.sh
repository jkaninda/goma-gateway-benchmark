#!/usr/bin/env bash
# Scenario 3 — Backend failover.
#
# Upstream equivalent: "Backend failover" (v3). A pool of four healthy origins
# sits behind 16 distinct routes; one origin is made unreachable with an
# iptables REJECT --reject-with tcp-reset for 22 s, three times, while requests
# rotate over the paths at a steady rate.
#
# What matters is how many requests the gateway keeps handing to the dead origin
# while it is down, and how fast traffic comes back once it is healthy again.
# Sixteen routes rather than one is deliberate: a gateway that tracks upstream
# health per route rather than per upstream has to learn the same lesson sixteen
# times, which is what made Envoy Gateway's outlier detection ineffective
# upstream.
#
# Each gateway runs with its own default behaviour. No retry or health-check
# policy is added on top, so the numbers describe what a user gets out of the
# box — with one exception: HAProxy's servers carry `check inter 2s fall 2
# rise 2` (see lib/gateways.sh), which gives it active health checking that no
# other gateway here has. The README discloses it alongside the results.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$BENCH_ROOT/lib/gateways.sh"

PATHS="${FO_PATHS:-16}"
RPS="${FO_RPS:-200}"
CYCLES="${FO_CYCLES:-3}"
DOWN_S="${FO_DOWN:-22}"
UP_S="${FO_UP:-8}"
VICTIM_PORT="${BACKEND_PORTS[3]}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT"

DURATION=$(( CYCLES * (DOWN_S + UP_S) + 6 ))

blackhole_on() {
  # REJECT with a TCP reset, not DROP: a reset is what a crashed process or a
  # closed port looks like, and it is what the upstream harness used. DROP would
  # instead measure connect timeouts, a different failure mode.
  $SUDO iptables -I OUTPUT 1 -p tcp -d 127.0.0.1 --dport "$VICTIM_PORT" \
    -j REJECT --reject-with tcp-reset
}
blackhole_off() {
  $SUDO iptables -D OUTPUT -p tcp -d 127.0.0.1 --dport "$VICTIM_PORT" \
    -j REJECT --reject-with tcp-reset 2>/dev/null || true
}
blackhole_clear() {
  # Delete the rule until it is really gone: a scenario that aborts mid-cycle
  # would otherwise leave the victim unreachable for every later gateway.
  while $SUDO iptables -C OUTPUT -p tcp -d 127.0.0.1 --dport "$VICTIM_PORT" \
      -j REJECT --reject-with tcp-reset 2>/dev/null; do
    blackhole_off
  done
}

trap 'blackhole_clear' EXIT

for gw in $GATEWAYS; do
  log "failover: $gw ($PATHS paths, ${RPS}/s, ${CYCLES}x${DOWN_S}s down)"
  blackhole_clear
  gw_prepare "$gw"
  pool=()
  for p in "${BACKEND_PORTS[@]}"; do pool+=("http://127.0.0.1:$p"); done
  for (( i = 0; i < PATHS; i++ )); do
    gw_route_pool "$gw" "$i" "${pool[@]}"
  done
  gw_start "$gw"
  wait_url_200 "$GW_URL/r-0/" 30 || die "$gw: /r-0/ never served"
  # Let any health checker settle on "all four up" before the first cycle.
  sleep 5

  csv="$OUT/failover-$gw.csv"
  timeline="$OUT/failover-$gw-timeline.csv"
  sample="$OUT/failover-$gw-resources.csv"
  "$BIN_DIR/benchtool" sample -pid "$GW_PID" -interval 500ms -out "$sample" &
  sampler=$!

  "$BIN_DIR/benchtool" failover -base "$GW_URL" -prefix "/r" -paths "$PATHS" \
    -rps "$RPS" -duration "${DURATION}s" -connections 16 \
    -out "$csv" -timeline "$timeline" &
  driver=$!

  sleep 3
  for (( c = 0; c < CYCLES; c++ )); do
    blackhole_on
    sleep "$DOWN_S"
    blackhole_off
    sleep "$UP_S"
  done

  wait "$driver" 2>/dev/null || true
  kill "$sampler" 2>/dev/null || true
  blackhole_clear
  gw_stop "$gw"
  python3 "$BENCH_ROOT/scripts/quicklook.py" failover "$csv" >&2 || true
done
log "failover: done"
