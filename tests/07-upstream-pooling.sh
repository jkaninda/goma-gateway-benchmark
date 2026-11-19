#!/usr/bin/env bash
# Scenario 7 — Upstream connection reuse.
#
# No upstream equivalent as a scenario, but it is the explanation the upstream
# v3 report reached for its biggest data-plane outlier: "Nginx Gateway Fabric
# does not pool upstream connections unless an UpstreamSettingsPolicy asks for
# it, so every request opens a new TCP connection to the backend."
#
# The origin counts accepted connections as well as requests, so this reports
# requests per upstream connection directly. A ratio near 1 means the gateway
# opens a connection per request; a high ratio means it keeps them alive.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$BENCH_ROOT/lib/gateways.sh"

CONNS="${POOL_CONNS:-32}"
DUR="${POOL_DURATION:-10s}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT"

csv="$OUT/pooling.csv"
echo "gateway,client_connections,requests,upstream_connections" >"$csv"

for gw in $GATEWAYS; do
  log "upstream pooling: $gw ($CONNS client connections, $DUR)"
  gw_prepare "$gw"
  gw_route "$gw" 1 "http://127.0.0.1:9001"
  gw_start "$gw"
  wait_url_200 "$GW_URL/r-1/" 30 || die "$gw: /r-1/ never served"

  # Warm up first, so connections opened while the gateway settles are not
  # counted against it, then reset the origin's counters.
  "$BIN_DIR/fortio" load -c "$CONNS" -qps 0 -t 3s -quiet "$GW_URL/r-1/" >/dev/null 2>&1 || true
  curl -s "http://127.0.0.1:9001/_bench/stats?reset=1" >/dev/null

  "$BIN_DIR/fortio" load -c "$CONNS" -qps 0 -t "$DUR" -quiet "$GW_URL/r-1/" >/dev/null 2>&1 || true
  stats=$(curl -s "http://127.0.0.1:9001/_bench/stats")
  reqs=${stats#requests=}; reqs=${reqs%% *}
  upstream=${stats##*connections=}; upstream=${upstream//[$'\n\r']/}
  # An origin left over from an older build answers the counter path with its
  # normal payload; refuse to invent a number from that.
  [[ "$reqs" =~ ^[0-9]+$ && "$upstream" =~ ^[0-9]+$ ]] \
    || die "origin on 9001 did not answer /_bench/stats with counters (got: ${stats:0:40})"

  # This very request was accepted by the counting listener before the handler
  # read the counter, so one of the connections is the harness's own. Without
  # subtracting it, a gateway that opened none reports 1 and the ratio becomes
  # "all requests over one connection", which is not a measurement.
  upstream=$(( upstream > 0 ? upstream - 1 : 0 ))
  printf '%s,%s,%s,%s\n' "$gw" "$CONNS" "$reqs" "$upstream" >>"$csv"
  log "    $reqs requests, $upstream new upstream connections"

  gw_stop "$gw"
done
log "upstream pooling: done"
