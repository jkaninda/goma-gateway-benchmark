#!/usr/bin/env bash
# Goma Gateway benchmark — entry point.
#
#   ./scripts/docker-run.sh                       the usual way: everything, in the pinned runner image
#   ./bench.sh                                    everything, every gateway, on this Linux host
#   RUN_STEPS="traffic footprint" ./bench.sh      a subset of scenarios
#   GATEWAYS="goma traefik" ./bench.sh            a subset of gateways
#   RUN_ID=20261119t1200z ./bench.sh              add to an existing run
#   SCALE_ROUTES=200 SCALE_CHURN=60 ./bench.sh    turn the dials down
#   GW_CPUS=0-1 LOAD_CPUS=2-5 ./bench.sh          gateway on its own cores
#
# One gateway at a time, always. Results land in results/<RUN_ID>/ as CSV, plus
# versions.csv and env.txt describing what actually ran.
set -euo pipefail
BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BENCH_ROOT
source "$BENCH_ROOT/lib/common.sh"

# With pinning on, put the whole harness — origins, fortio, probers, sampler —
# on LOAD_CPUS by re-executing under taskset. Every child inherits the mask;
# only the gateway is moved, by gw_exec, onto GW_CPUS.
if [[ -n "$GW_CPUS" && -z "${BENCH_PINNED:-}" ]]; then
  [[ -n "$LOAD_CPUS" ]] || die "GW_CPUS is set but LOAD_CPUS is not"
  need taskset
  export BENCH_PINNED=1 GW_CPUS LOAD_CPUS
  exec taskset -c "$LOAD_CPUS" bash "$0" "$@"
fi

source "$BENCH_ROOT/lib/gateways.sh"

RUN_STEPS="${RUN_STEPS:-smoke propagation routechange failover routescale traffic pooling footprint shutdown}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dt%H%Mz)}"
export RUN_ID GATEWAYS
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT" "$RUN_DIR/logs"

need curl; need python3; need ss; need setsid; need timeout
case " $RUN_STEPS " in *" failover "*) need iptables ;; esac
for b in fortio benchtool; do
  [[ -x "$BIN_DIR/$b" ]] || die "missing $BIN_DIR/$b — run scripts/fetch-binaries.sh or use scripts/docker-run.sh"
done
for gw in $GATEWAYS; do
  case "$gw" in
    goma*)    [[ -x "$BIN_DIR/goma" ]]    || die "missing $BIN_DIR/goma" ;;
    traefik*) [[ -x "$BIN_DIR/traefik" ]] || die "missing $BIN_DIR/traefik" ;;
    nginx)    need nginx ;;
    haproxy)  need haproxy ;;
    *)        die "unknown gateway: $gw" ;;
  esac
done

# --- what ran ---------------------------------------------------------------
{
  echo "gateway,version"
  for gw in $GATEWAYS; do echo "$gw,$(gw_version "$gw")"; done
  echo "fortio,$("$BIN_DIR/fortio" version 2>&1 | head -1)"
} >"$OUT/versions.csv"

cpu_model() {
  local m="${BENCH_HOST_CPU:-}"
  [[ -n "$m" ]] && { echo "$m"; return; }
  m=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)
  [[ -n "$m" && "$m" != "-" ]] || m=$(lscpu 2>/dev/null | awk -F': +' '/^Model name/{print $2; exit}')
  echo "${m:-unknown}"
}

{
  echo "run_id: $RUN_ID"
  echo "date_utc: $(date -u +%FT%TZ)"
  echo "kernel: $(uname -sr)"
  echo "arch: $(uname -m)"
  echo "cpus: $(nproc --all)"
  echo "model: $(cpu_model)"
  echo "mem_total_mb: $(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo)"
  echo "runtime: ${BENCH_RUNTIME:-host}"
  echo "gw_cpus: ${GW_CPUS:-unpinned}"
  echo "gw_cpu_count: $(gw_cpu_count)"
  echo "load_cpus: ${LOAD_CPUS:-unpinned}"
  echo "gateways: $GATEWAYS"
  echo "steps: $RUN_STEPS"
  echo "payload_bytes: $PAYLOAD_BYTES"
  echo "prop_routes: ${PROP_ROUTES:-100}"
  echo "scale_routes: ${SCALE_ROUTES:-1000}"
  echo "scale_churn_s: ${SCALE_CHURN:-120}"
  echo "fo_cycles: ${FO_CYCLES:-3}"
  echo "fo_down_s: ${FO_DOWN:-22}"
  echo "traffic_conns: ${TRAFFIC_CONNS:-1 8 32 128 256}"
  echo "traffic_duration: ${TRAFFIC_DURATION:-20s}"
} >"$OUT/env.txt"

log "run $RUN_ID — gateways: $GATEWAYS — steps: $RUN_STEPS"
log "gateway CPUs: ${GW_CPUS:-unpinned} ($(gw_cpu_count)) — load CPUs: ${LOAD_CPUS:-unpinned}"
cat "$OUT/versions.csv" >&2

start_backends
trap 'stop_backends' EXIT

run_step() {
  local name="$1" script="$2"
  case " $RUN_STEPS " in *" $name "*) ;; *) return 0 ;; esac
  log "=== step: $name ==="
  local t0=$SECONDS
  bash "$BENCH_ROOT/tests/$script"
  log "=== step $name finished in $((SECONDS - t0))s ==="
}

run_step smoke       smoke.sh
run_step propagation 01-propagation.sh
run_step routechange 02-routechange.sh
run_step failover    03-failover.sh
run_step routescale  04-routescale.sh
run_step traffic     05-traffic.sh
run_step pooling     07-upstream-pooling.sh
run_step footprint   06-footprint.sh
run_step shutdown    08-shutdown.sh

log "building summary"
python3 "$BENCH_ROOT/scripts/summarize.py" "$OUT" >"$OUT/summary.md"
log "run $RUN_ID complete — $OUT/summary.md"
