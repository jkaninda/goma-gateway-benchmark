#!/usr/bin/env bash
# Scenario 4 — Route scale.
#
# Upstream equivalent: "Route scale" (v3). A large route table is created and
# then churned continuously for several minutes while CPU and memory are
# sampled. Upstream this was 1,000 HTTPRoutes across 10 namespaces with 1,000
# pods; here it is N route definitions pointing at a small pool of origins,
# which keeps the routing table honest without needing 1,000 processes.
#
# Three phases, timestamped in phases.csv so the sampler output can be split:
#   create   N routes declared, one commit per batch
#   churn    a slice of the table is repointed over and over
#   settle   no changes at all, to see whether memory is given back
#
# A canary route is probed at a low, fixed rate throughout, so a gateway that
# stops serving traffic while it digests a config change shows up as errors
# rather than staying invisible in the CPU graph.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$BENCH_ROOT/lib/gateways.sh"

ROUTES="${SCALE_ROUTES:-1000}"
BATCH="${SCALE_BATCH:-50}"
CHURN_S="${SCALE_CHURN:-120}"
CHURN_SLICE="${SCALE_CHURN_SLICE:-25}"
CHURN_GAP="${SCALE_CHURN_GAP:-0.5}"
SETTLE_S="${SCALE_SETTLE:-30}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT"

for gw in $GATEWAYS; do
  log "route scale: $gw ($ROUTES routes, ${CHURN_S}s churn, ${SETTLE_S}s settle)"
  gw_prepare "$gw"
  gw_route "$gw" canary "http://127.0.0.1:9001"
  gw_start "$gw"
  wait_url_200 "$GW_URL/r-canary/" 30 || die "$gw: canary route never served"

  sample="$OUT/routescale-$gw-resources.csv"
  phases="$OUT/routescale-$gw-phases.csv"
  canary="$OUT/routescale-$gw-canary.csv"
  csv="$OUT/routescale-$gw.csv"

  "$BIN_DIR/benchtool" sample -pid "$GW_PID" -interval 500ms -out "$sample" &
  sampler=$!

  echo "phase,start_ms,end_ms" >"$phases"
  now_ms() { date +%s%3N; }

  # 10 s of baseline before anything is created, for the "idle with 1 route" row.
  t0=$(now_ms); sleep 10; echo "baseline,$t0,$(now_ms)" >>"$phases"

  # --- create ---------------------------------------------------------------
  t0=$(now_ms)
  for (( i = 1; i <= ROUTES; i++ )); do
    gw_route "$gw" "$i" "http://127.0.0.1:${BACKEND_PORTS[$(( i % 4 ))]}"
    if (( i % BATCH == 0 )); then gw_commit "$gw"; fi
  done
  gw_commit "$gw"
  # Wait until the last route is actually reachable before calling create done.
  wait_url_200 "$GW_URL/r-$ROUTES/" 120 || log "  warning: $gw never served route $ROUTES"
  echo "create,$t0,$(now_ms)" >>"$phases"

  # --- churn ----------------------------------------------------------------
  # The canary runs for exactly the churn phase, so its error count answers one
  # question: does this gateway keep serving an untouched route while the rest
  # of the table is being rewritten under it?
  "$BIN_DIR/benchtool" churn -url "$GW_URL/r-canary/" -duration "${CHURN_S}s" \
    -connections 1 -out "$canary" &
  canary_pid=$!

  t0=$(now_ms)
  churn_end=$((SECONDS + CHURN_S))
  n=0
  while (( SECONDS < churn_end )); do
    for (( j = 0; j < CHURN_SLICE; j++ )); do
      idx=$(( (n * CHURN_SLICE + j) % ROUTES + 1 ))
      gw_route "$gw" "$idx" "http://127.0.0.1:${BACKEND_PORTS[$(( (n + j) % 4 ))]}"
    done
    gw_commit "$gw"
    n=$(( n + 1 ))
    sleep "$CHURN_GAP"
  done
  echo "churn,$t0,$(now_ms)" >>"$phases"
  wait "$canary_pid" 2>/dev/null || true

  # --- settle ---------------------------------------------------------------
  t0=$(now_ms); sleep "$SETTLE_S"; echo "settle,$t0,$(now_ms)" >>"$phases"

  # --- delete ---------------------------------------------------------------
  t0=$(now_ms)
  gw_drop_routes "$gw" '[0-9]*'
  gw_commit "$gw"
  sleep 15
  echo "deleted,$t0,$(now_ms)" >>"$phases"

  kill "$sampler" 2>/dev/null || true
  gw_stop "$gw"

  printf 'routes,churn_seconds,churn_batches\n%d,%d,%d\n' "$ROUTES" "$CHURN_S" "$n" >"$csv"
  python3 "$BENCH_ROOT/scripts/quicklook.py" resources "$sample" >&2 || true
done
log "route scale: done"
