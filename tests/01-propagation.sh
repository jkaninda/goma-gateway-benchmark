#!/usr/bin/env bash
# Scenario 1 — Route propagation.
#
# Upstream equivalent: "Route propagation" (v3). N routes are declared one at a
# time and each is probed until the gateway serves it; the delay between the
# declaration and the first 200 is recorded, along with every non-404 answer
# seen while waiting.
#
# The non-404 count is the important column. A gateway that has not programmed
# a route yet should say 404. Answering 503 or 500 means it accepted the request
# into a listener whose upstream was not ready — a real outage for a client that
# retries on 404 but not on 503.
#
# The clock starts immediately before the route file is written, so it includes
# whatever the gateway needs to notice the change: a file-watch debounce for
# Goma and Traefik, a config reload for nginx and HAProxy.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$BENCH_ROOT/lib/gateways.sh"

ROUTES="${PROP_ROUTES:-100}"
PACING="${PROP_PACING:-0.1}"      # seconds between routes
TIMEOUT="${PROP_TIMEOUT:-30s}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT"

for gw in $GATEWAYS; do
  log "propagation: $gw ($ROUTES routes)"
  gw_prepare "$gw"
  # A warm-up route so the first measured route is not paying for the gateway's
  # cold start. The upstream harness excludes first-route propagation for the
  # same reason.
  gw_route "$gw" warm "http://127.0.0.1:9001"
  gw_start "$gw"
  wait_url_200 "$GW_URL/r-warm/" 30 || die "$gw: warm-up route never served"

  csv="$OUT/propagation-$gw.csv"
  fifo="$RUN_DIR/prop-$gw.fifo"
  rm -f "$fifo"; mkfifo "$fifo"

  sample="$OUT/propagation-$gw-resources.csv"
  "$BIN_DIR/benchtool" sample -pid "$GW_PID" -interval 500ms -out "$sample" &
  sampler=$!

  "$BIN_DIR/benchtool" probe -out "$csv" -timeout "$TIMEOUT" -interval 2ms <"$fifo" &
  prober=$!
  exec 9>"$fifo"

  for (( i = 1; i <= ROUTES; i++ )); do
    now=$(date +%s%N)
    gw_route "$gw" "$i" "http://127.0.0.1:9001"
    printf '{"index":%d,"at":%s,"url":"%s"}\n' "$i" "$now" "$GW_URL/r-$i/" >&9
    gw_commit "$gw"
    # Wait for the prober to finish this route before declaring the next, so
    # every measurement is of one route in isolation.
    local_end=$((SECONDS + 40))
    while (( SECONDS < local_end )); do
      grep -q "^$i," "$csv" 2>/dev/null && break
      sleep 0.005
    done
    sleep "$PACING"
  done

  exec 9>&-
  wait "$prober" 2>/dev/null || true
  kill "$sampler" 2>/dev/null || true
  rm -f "$fifo"

  gw_stop "$gw"

  python3 "$BENCH_ROOT/scripts/quicklook.py" propagation "$csv" >&2 || true
done
log "propagation: done"
