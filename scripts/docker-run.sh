#!/usr/bin/env bash
# Build the runner image and run the benchmark inside it.
#
#   ./scripts/docker-run.sh                                   full suite
#   RUN_STEPS="smoke" ./scripts/docker-run.sh                 just the smoke test
#   GATEWAYS="goma-fast nginx" RUN_STEPS="traffic" ./scripts/docker-run.sh
#   GW_CPUS=0-1 LOAD_CPUS=2-5 ./scripts/docker-run.sh         choose the cores
#   GW_CPUS= ./scripts/docker-run.sh                          no pinning (original layout)
#   TRAEFIK_VERSION=v3.8.0 ./scripts/docker-run.sh            another version of one component
#
# Works on any Docker host with Linux containers — including Docker Desktop and
# OrbStack on macOS, which run them in a Linux VM. The container is privileged
# because the failover scenario adds iptables rules; it has no network beyond
# its own loopback (--network none), so those rules touch nothing else.
#
# Every bench.sh variable (RUN_ID, GATEWAYS, RUN_STEPS, SCALE_*, TRAFFIC_*, FO_*,
# PROP_*, ...) is passed through. Results land in results/<RUN_ID>/ on the host.
set -euo pipefail
# Host side runs under macOS's bash 3.2 too: empty arrays are expanded with
# ${a[@]+"${a[@]}"} because "${a[@]}" on an empty array trips set -u there.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Version overrides become build args; the defaults live in docker/Dockerfile.
build_args=()
tag=local
for v in GOMA_VERSION TRAEFIK_VERSION HAPROXY_VERSION NGINX_VERSION FORTIO_VERSION; do
  if [[ -n "${!v:-}" ]]; then
    build_args+=(--build-arg "$v=${!v}")
    tag="$tag-$(echo "$v" | cut -d_ -f1 | tr '[:upper:]' '[:lower:]')${!v}"
  fi
done
IMAGE="${IMAGE:-goma-bench-runner:$tag}"

# Gateway on two dedicated cores, everything else on four others. Two gateway
# cores keep the per-core numbers comparable with earlier 2-vCPU runs; four load
# cores are enough that fortio and the origin are not the bottleneck for any
# gateway measured here (check the traffic CPU columns if you change this).
GW_CPUS="${GW_CPUS-2-3}"
LOAD_CPUS="${LOAD_CPUS-4-7}"

docker build -q ${build_args[@]+"${build_args[@]}"} -f "$ROOT/docker/Dockerfile" -t "$IMAGE" "$ROOT" >/dev/null

cpuset=()
if [[ -n "$GW_CPUS" ]]; then
  cpuset=(--cpuset-cpus "$GW_CPUS,$LOAD_CPUS")
fi

env_args=()
for v in $(compgen -e | grep -E '^(RUN_ID|RUN_STEPS|GATEWAYS|PAYLOAD_BYTES|PROP_|CHANGE_|FO_|SCALE_|TRAFFIC_|POOL_|FOOTPRINT_|SHUTDOWN_)'); do
  env_args+=(-e "$v")
done

# The container sees the VM's CPUs, not what they run on; record the host's.
host_cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"

tty=()
[[ -t 1 ]] && tty=(-t)

exec docker run --rm ${tty[@]+"${tty[@]}"} \
  --privileged \
  --network none \
  --ulimit nofile=65536:65536 \
  ${cpuset[@]+"${cpuset[@]}"} \
  -e GW_CPUS="$GW_CPUS" -e LOAD_CPUS="$LOAD_CPUS" -e BENCH_HOST_CPU="$host_cpu" \
  ${env_args[@]+"${env_args[@]}"} \
  -v "$ROOT:/bench" \
  "$IMAGE"
