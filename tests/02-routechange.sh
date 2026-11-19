#!/usr/bin/env bash
# Scenario 2 — Route changes.
#
# Upstream equivalent: "Route changes" (v3). One route is rewritten repeatedly
# while it is probed continuously. Every non-2xx answer is an error the gateway
# introduced by applying a configuration change; a gateway that reloads
# correctly serves every request through the churn.
#
# The route is flipped between two origins that are both healthy and both
# already listening, so a failed request cannot be blamed on a cold backend —
# the difference from the upstream v2 run, which accidentally measured requests
# landing on a terminating pod.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$BENCH_ROOT/lib/gateways.sh"

CHANGES="${CHANGE_COUNT:-11}"
PROBERS="${CHANGE_PROBERS:-4}"

# Two passes, because one gap cannot answer both questions.
#
#   An odd number of changes is used so the final state differs from the initial
#   one: with an even number, a gateway that coalesces every change into a single
#   late reload lands back where it started and looks as if nothing happened.
#
#   fast (0.2 s)  changes arrive faster than any coalescing window. A gateway
#                 with a debounce or throttle never applies them while the churn
#                 lasts, which the "origins hit" column exposes: if only one
#                 origin ever answers, that run measured nothing being applied.
#   slow (1.5 s)  every change is far enough apart to be applied on its own, so
#                 errors here are genuinely reload-induced.
PASSES="${CHANGE_PASSES:-fast:0.2 slow:1.5}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT"

for pass_spec in $PASSES; do
  name="${pass_spec%%:*}"
  GAP="${pass_spec##*:}"
  # Probe past the last change by 4 s, so a reload that lands after the final
  # write is still inside the measured window.
  DURATION=$(python3 -c "print(f'{$CHANGES * $GAP + 4:.1f}s')")

  for gw in $GATEWAYS; do
    log "route change [$name]: $gw ($CHANGES changes, ${GAP}s apart)"
    gw_prepare "$gw"
    gw_route "$gw" 1 "http://127.0.0.1:${CHURN_PORTS[0]}"
    gw_start "$gw"
    wait_url_200 "$GW_URL/r-1/" 30 || die "$gw: /r-1/ never served before churn"

    csv="$OUT/routechange-$name-$gw.csv"
    sample="$OUT/routechange-$name-$gw-resources.csv"
    "$BIN_DIR/benchtool" sample -pid "$GW_PID" -interval 250ms -out "$sample" &
    sampler=$!

    "$BIN_DIR/benchtool" churn -url "$GW_URL/r-1/" -duration "$DURATION" \
      -connections "$PROBERS" -out "$csv" \
      -timeline "$OUT/routechange-$name-$gw-timeline.csv" &
    churner=$!

    sleep 0.5
    for (( c = 0; c < CHANGES; c++ )); do
      if (( c % 2 == 0 )); then
        gw_route "$gw" 1 "http://127.0.0.1:${CHURN_PORTS[1]}"
      else
        gw_route "$gw" 1 "http://127.0.0.1:${CHURN_PORTS[0]}"
      fi
      gw_commit "$gw"
      sleep "$GAP"
    done

    wait "$churner" 2>/dev/null || true
    kill "$sampler" 2>/dev/null || true
    gw_stop "$gw"
    python3 "$BENCH_ROOT/scripts/quicklook.py" churn "$csv" >&2 || true
  done
done
log "route change: done"
