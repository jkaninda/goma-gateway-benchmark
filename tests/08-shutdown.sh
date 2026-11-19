#!/usr/bin/env bash
# Scenario 8 — Graceful shutdown under a live connection.
#
# No upstream equivalent, but it is the same class of question the upstream
# report asks about reload behaviour: what does the gateway do when the platform
# tells it to stop while clients are still attached?
#
# Three cases per gateway:
#   early     SIGTERM the instant the listener accepts, before anything is served
#   idle      SIGTERM several seconds after the last request
#   attached  SIGTERM with a client's keep-alive connection still open
#
# A Kubernetes rolling update, a systemd restart and `docker stop` all send
# SIGTERM to a process that may be serving; a gateway that will not exit is
# SIGKILLed when the grace period runs out. "early" covers the other direction:
# a process killed right after it starts, which is what a failed readiness gate,
# a fast rollback or a crash loop produces.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$BENCH_ROOT/lib/gateways.sh"

GRACE="${SHUTDOWN_GRACE:-30}"   # how long to wait before calling it a hang
IDLE_GAP="${SHUTDOWN_IDLE_GAP:-3}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT"

csv="$OUT/shutdown.csv"
echo "gateway,case,exited,ms" >"$csv"

time_shutdown() {
  local gw="$1" label="$2"
  local t0 end result
  t0=$(date +%s%3N)
  kill -TERM "-$GW_PID" 2>/dev/null || kill -TERM "$GW_PID" 2>/dev/null || true
  end=$((SECONDS + GRACE))
  result=no
  while (( SECONDS < end )); do
    if ! port_open "$GW_PORT"; then result=yes; break; fi
    sleep 0.01
  done
  local ms=$(( $(date +%s%3N) - t0 ))
  printf '%s,%s,%s,%d\n' "$gw" "$label" "$result" "$ms" >>"$csv"
  log "    $label: exited=$result after ${ms} ms"
  # Always leave the port free for the next case.
  kill -KILL "-$GW_PID" 2>/dev/null || kill -KILL "$GW_PID" 2>/dev/null || true
  GW_PID=""
  sleep 1
}

for gw in $GATEWAYS; do
  log "shutdown: $gw"

  # --- early: SIGTERM as soon as the port is open ---
  gw_prepare "$gw"
  gw_route "$gw" 1 "http://127.0.0.1:9001"
  gw_exec "$gw"
  # Deliberately no health-endpoint wait here: the point is to signal at the
  # earliest moment the process is externally visible.
  wait_port "$GW_PORT" 20 || die "$gw did not listen"
  time_shutdown "$gw" early

  # --- idle: nothing has been served for a few seconds ---
  gw_prepare "$gw"
  gw_route "$gw" 1 "http://127.0.0.1:9001"
  gw_start "$gw"
  wait_url_200 "$GW_URL/r-1/" 30 || die "$gw: /r-1/ never served"
  sleep "$IDLE_GAP"
  time_shutdown "$gw" idle

  # --- attached: a client keep-alive connection is open right now ---
  gw_prepare "$gw"
  gw_route "$gw" 1 "http://127.0.0.1:9001"
  gw_start "$gw"
  wait_url_200 "$GW_URL/r-1/" 30 || die "$gw: /r-1/ never served"
  # A keep-alive client that made a request and is holding the connection open.
  # curl -K with a long-lived connection would do; the churn prober is simpler
  # and definitely still connected when it is killed.
  "$BIN_DIR/benchtool" churn -url "$GW_URL/r-1/" -duration 60s -connections 1 \
    -out /dev/null >/dev/null 2>&1 &
  churner=$!
  sleep 1
  kill -STOP "$churner" 2>/dev/null || true   # freeze it: connection open, no traffic
  time_shutdown "$gw" attached
  kill -CONT "$churner" 2>/dev/null || true
  kill "$churner" 2>/dev/null || true
done
log "shutdown: done"
