#!/usr/bin/env bash
# Shared settings and helpers for every scenario.
set -euo pipefail

BENCH_ROOT="${BENCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BIN_DIR="${BIN_DIR:-$BENCH_ROOT/bin}"
RESULTS_DIR="${RESULTS_DIR:-$BENCH_ROOT/results}"
RUN_DIR="${RUN_DIR:-/tmp/goma-bench-run}"

# One gateway at a time, always on the same port, so no scenario can measure
# the cost of a neighbour. This mirrors the "one gateway at a time" rule the
# upstream v3 harness adopted after v2 measured five control planes fighting
# over the same CPUs.
GW_PORT="${GW_PORT:-8080}"
GW_URL="http://127.0.0.1:${GW_PORT}"

# Origin servers. 9001-9004 are the failover pool; 9101/9102 are the pair the
# route-change scenario flips between; 9001 doubles as the general backend.
BACKEND_PORTS=(9001 9002 9003 9004)
CHURN_PORTS=(9101 9102)

# goma        file provider, default 500 ms watch debounce
# goma-fast   file provider, debounce 0s (providers.file.debounce, Goma 1.1+)
# goma-reload file watch off, POST /gateway/reload after every write
# traefik     file provider, default 2 s providersThrottleDuration
# traefik-fast file provider, providersThrottleDuration 0s — goma-fast's counterpart
GATEWAYS_DEFAULT="goma goma-fast goma-reload traefik traefik-fast nginx haproxy"
GATEWAYS="${GATEWAYS:-$GATEWAYS_DEFAULT}"

# CPU placement. When GW_CPUS is set, the gateway runs pinned to those CPUs and
# everything else the harness starts (origins, fortio, probers, the sampler)
# should run on LOAD_CPUS — bench.sh re-execs itself under `taskset -c
# $LOAD_CPUS` to arrange that. Without it, the gateway, the load generator and
# the origins compete for the same cores and absolute throughput describes the
# contention, not the gateway. Unset, nothing is pinned (the original layout).
GW_CPUS="${GW_CPUS:-}"
LOAD_CPUS="${LOAD_CPUS:-}"

# Command prefix that pins to the gateway's CPUs: "${GW_PIN[@]}" cmd ... &
# An array rather than a function on purpose — a backgrounded function runs in
# a forked subshell, so $! would be that bash rather than the gateway, and
# every signal the harness sends would miss. taskset execs in place.
GW_PIN=()
if [[ -n "$GW_CPUS" ]]; then GW_PIN=(taskset -c "$GW_CPUS"); fi

# How many CPUs the gateway may use. nginx and HAProxy are told this many
# workers/threads; the Go gateways read their affinity mask on their own.
gw_cpu_count() {
  if [[ -n "$GW_CPUS" ]]; then taskset -c "$GW_CPUS" nproc; else nproc; fi
}

# iptables needs root. Inside the runner container we already are.
if [[ "$(id -u)" == "0" ]]; then SUDO=""; else SUDO="sudo"; fi

PAYLOAD_BYTES="${PAYLOAD_BYTES:-100}"

log()  { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }
die()  { printf '[%(%H:%M:%S)T] ERROR: %s\n' -1 "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# --- origin servers ---------------------------------------------------------

BACKENDS_OWNED=0

# Idempotent: if origins are already serving, adopt them rather than restarting.
# bench.sh starts them once for the whole suite, but each scenario is a separate
# bash process and may also be run on its own, so both have to call this. A
# scenario that adopts running origins must not stop them on the way out — that
# is what `BACKENDS_OWNED` is for, and getting it wrong leaves later scenarios
# proxying to nothing.
start_backends() {
  if backends_ready; then
    BACKENDS_OWNED=0
    return 0
  fi
  stop_backends
  BACKENDS_OWNED=1
  mkdir -p "$RUN_DIR/logs"
  # The pid file lives under RUN_DIR, so a run that starts after RUN_DIR was
  # wiped cannot stop the previous run's origins by pid. Free the ports
  # directly: an origin from an older binary still listening on 9001 would be
  # used silently by every scenario.
  for port in "${BACKEND_PORTS[@]}" "${CHURN_PORTS[@]}"; do ensure_port_free "$port"; done
  local i=1
  for port in "${BACKEND_PORTS[@]}"; do
    "$BIN_DIR/benchtool" backend -addr "127.0.0.1:$port" -id "b$i" -payload "$PAYLOAD_BYTES" \
      >"$RUN_DIR/logs/backend-$port.log" 2>&1 &
    echo $! >>"$RUN_DIR/backends.pids"
    i=$((i+1))
  done
  for port in "${CHURN_PORTS[@]}"; do
    "$BIN_DIR/benchtool" backend -addr "127.0.0.1:$port" -id "c$port" -payload "$PAYLOAD_BYTES" \
      >"$RUN_DIR/logs/backend-$port.log" 2>&1 &
    echo $! >>"$RUN_DIR/backends.pids"
  done
  wait_port "${BACKEND_PORTS[0]}" 10 || die "backends did not come up"
  wait_port "${CHURN_PORTS[0]}" 10 || die "churn backends did not come up"
}

# True when every origin this harness needs is already up and is a build that
# has the counter endpoint (an older binary answers it with its payload).
backends_ready() {
  local port
  for port in "${BACKEND_PORTS[@]}" "${CHURN_PORTS[@]}"; do
    port_open "$port" || return 1
  done
  [[ "$(curl -s --max-time 2 "http://127.0.0.1:${BACKEND_PORTS[0]}/_bench/stats")" == requests=* ]]
}

# Only stops origins this process started. Called from a scenario's EXIT trap,
# so it must be a no-op when the origins belong to the suite.
stop_backends_if_owned() {
  [[ "${BACKENDS_OWNED:-0}" == "1" ]] && stop_backends
  return 0
}

stop_backends() {
  if [[ -f "$RUN_DIR/backends.pids" ]]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$RUN_DIR/backends.pids"
    rm -f "$RUN_DIR/backends.pids"
  fi
  sleep 0.2
}

# A TCP connect test that always runs in a real child process. `(exec 3<>...)`
# looks equivalent but bash may optimise the subshell away and replace the
# running shell, which silently ends the script.
port_open() {
  timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

# Make sure nothing from an earlier run still owns the gateway port. A straggler
# there is the worst failure mode this harness has: the next gateway silently
# fails to bind and every request is answered by the previous one's routes.
ensure_port_free() {
  local port="$1"
  port_open "$port" || return 0
  local pids
  pids=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
  for pid in $pids; do
    log "port $port still held by pid $pid from an earlier run; terminating it"
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
  sleep 0.5
  port_open "$port" && die "could not free port $port"
  return 0
}

wait_port() {
  local port="$1" secs="${2:-15}"
  local end=$((SECONDS + secs))
  while (( SECONDS < end )); do
    if port_open "$port"; then return 0; fi
    sleep 0.01
  done
  return 1
}

# Polls at 10 ms. The startup and shutdown numbers in the footprint scenario are
# differences between two of these, so the poll interval is their resolution: at
# 100 ms every gateway that starts quickly looked identical.
wait_url_200() {
  local url="$1" secs="${2:-30}"
  local end=$((SECONDS + secs))
  while (( SECONDS < end )); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url")" == "200" ]]; then return 0; fi
    sleep 0.01
  done
  return 1
}

# --- resource sampling ------------------------------------------------------

# Resource sampling lives in `benchtool sample`, which scenarios start directly:
#
#   "$BIN_DIR/benchtool" sample -pid "$GW_PID" -interval 500ms -out "$csv" &
#
# It reads /proc rather than `docker stats` so it works in both runtimes, and it
# accumulates per-pid counters so that workers replaced by a reload still count.

csv_init() { printf '%s\n' "$2" >"$1"; }
