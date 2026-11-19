#!/usr/bin/env bash
# Smoke test: every gateway must start, serve a route, hot-add a second route,
# and repoint an existing route. If this fails, no scenario result is meaningful.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$BENCH_ROOT/lib/gateways.sh"

mkdir -p "$RUN_DIR/logs"
start_backends
trap 'gw_stop "${gw:-}" 2>/dev/null || true; stop_backends_if_owned' EXIT

for gw in $GATEWAYS; do
  log "smoke: $gw ($(gw_version "$gw"))"
  gw_prepare "$gw"
  # Routes written before start are read at boot; no commit needed for that.
  gw_route "$gw" 1 "http://127.0.0.1:9001"
  gw_start "$gw"

  wait_url_200 "$(gw_health_url "$gw")" 15 || die "$gw: health endpoint never answered 200"
  wait_url_200 "$GW_URL/r-1/" 20 || { tail -25 "$(gw_dir "$gw")/logs/gw.log" >&2; die "$gw: /r-1/ never answered 200"; }

  # Poll rather than assert once: nginx keeps old workers alive for a moment
  # after a reload, so a single request can legitimately land on the previous
  # configuration. Settling is what is being checked here, not the first answer.
  expect_backend() {
    local url="$1" want="$2" id=""
    for _ in $(seq 80); do
      id=$(curl -s -D- -o /dev/null "$url" | awk -F': ' '/[Xx]-[Bb]ackend-[Ii]d/{gsub(/\r/,"");print $2}')
      [[ "$id" == "$want" ]] && return 0
      sleep 0.25
    done
    die "$gw: $url served by '$id', expected $want"
  }

  expect_backend "$GW_URL/r-1/" b1

  # hot-add
  gw_route "$gw" 2 "http://127.0.0.1:9002"; gw_commit "$gw"
  wait_url_200 "$GW_URL/r-2/" 20 || die "$gw: hot-added /r-2/ never served"
  expect_backend "$GW_URL/r-2/" b2

  # repoint an existing route
  gw_route "$gw" 1 "http://127.0.0.1:9003"; gw_commit "$gw"
  expect_backend "$GW_URL/r-1/" b3

  # a path with no route must 404, never 5xx
  # Must be 404. Answering 5xx for a route that does not exist is exactly the
  # defect the propagation scenario scores, so a gateway that does it here would
  # make that scenario measure the harness's own configuration instead.
  code=$(curl -s -o /dev/null -w '%{http_code}' "$GW_URL/r-999/")
  [[ "$code" == "404" ]] || die "$gw answers $code for an undefined route, expected 404"

  # load-balanced pool
  gw_route_pool "$gw" 3 "http://127.0.0.1:9001" "http://127.0.0.1:9002"; gw_commit "$gw"
  wait_url_200 "$GW_URL/r-3/" 20 || die "$gw: pooled /r-3/ never served"
  seen=$(for _ in $(seq 20); do curl -s -D- -o /dev/null "$GW_URL/r-3/" | awk -F': ' '/[Xx]-[Bb]ackend-[Ii]d/{gsub(/\r/,"");print $2}'; done | sort -u | tr '\n' ' ')
  log "  ok: pool served by [$seen], undefined route -> $code"

  gw_stop "$gw"
done
log "smoke: all gateways OK"
