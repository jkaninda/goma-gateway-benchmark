# How the harness works

```
bench.sh                    entry point: picks steps, records versions/env, runs scenarios
docker/Dockerfile           the runner image: every gateway + fortio + benchtool, pinned
scripts/docker-run.sh       build the runner image and run bench.sh in it (the usual way in)
lib/common.sh               ports, origins, CPU pinning, port hygiene
lib/gateways.sh             the per-gateway adapters — the only file that knows config formats
gateways/<name>/*.tmpl      base configuration per gateway variant
tests/smoke.sh              start / serve / hot-add / repoint / 404 / pool, for every gateway
tests/0N-*.sh               one scenario each
tools/benchtool/            Go: origin server, probers, load driver, /proc sampler
scripts/summarize.py        CSVs -> summary.md
scripts/fetch-binaries.sh   bare-Linux alternative to the image: goma, traefik, fortio, benchtool
results/<run-id>/           raw CSVs + generated summary
```

## Two ways to run it

**In the runner image** (`scripts/docker-run.sh`). Any Docker host with Linux
containers, including Docker Desktop and OrbStack on macOS. The image takes Goma,
Traefik, HAProxy and fortio binaries from each project's official image and is based
on the official nginx image, so every version is an upstream release and the same on
amd64 and arm64. Versions are set once, as `ARG`s in `docker/Dockerfile`; override one
for a single run with, for example, `TRAEFIK_VERSION=v3.8.0 ./scripts/docker-run.sh`. The container is
`--privileged` (for the failover scenario's iptables rule) and `--network none`, so the
rule only ever touches the container's own loopback.

**Directly on a Linux host** (`./bench.sh`). Run `scripts/fetch-binaries.sh` first (it
fills `bin/`, which is git-ignored), and
install nginx and HAProxy from their projects' own repositories. Needs root for
iptables, plus `taskset`, `ss`, `setsid`, `timeout`.

## CPU placement

With `GW_CPUS` and `LOAD_CPUS` set (the image runner sets `2-3` and `4-7` by default),
`bench.sh` re-executes itself under `taskset -c $LOAD_CPUS`, so the origins, fortio,
the probers and the sampler all inherit that mask. Only the gateway is moved, by
`gw_exec`, onto `GW_CPUS`. nginx and HAProxy are given one worker / thread per gateway
CPU; Go gateways size `GOMAXPROCS` from their affinity mask on their own.

Without pinning (`GW_CPUS=`), everything shares every CPU, and on a small machine
absolute throughput then mostly measures the load generator and the gateway fighting
over the same cores.

## The gateway interface

Scenarios never know which gateway they are driving. They use these calls, all in
`lib/gateways.sh`:

| Call | Meaning |
|---|---|
| `gw_prepare <gw>` | fresh config tree, no routes |
| `gw_exec <gw>` | launch it pinned, in its own session; set `$GW_PID`; wait for nothing |
| `gw_start <gw>` | `gw_exec`, then wait for the port and the health endpoint |
| `gw_stop <gw>` | SIGTERM the process group, escalate to SIGKILL, wait for the port |
| `gw_route <gw> <id> <target>` | declare `/r-<id>/` proxied to `<target>`, prefix stripped |
| `gw_route_pool <gw> <id> <t...>` | same, load-balanced over several origins |
| `gw_commit <gw>` | make written route files take effect |
| `gw_drop_routes <gw> [glob]` | remove route definitions |

`gw_route` writes a file (atomically, via rename). `gw_commit` is where the families
differ: a no-op for the file watchers (`goma`, `goma-fast`, `traefik`, `traefik-fast`), a
synchronous `POST /gateway/reload` for `goma-reload`, `SIGHUP` for nginx,
regenerate-and-`SIGUSR2` (and wait for HAProxy to log the reload) for HAProxy.
Scenarios always call `gw_route` then `gw_commit`, with the measurement clock started
before `gw_route`.

## Gateway variants

| Name | What differs |
|---|---|
| `goma` | Goma defaults: file provider, `watch: true`, 500 ms debounce |
| `goma-fast` | `providers.file.debounce: 0s` |
| `goma-reload` | `watch: false`; harness calls `POST /gateway/reload` after each write |
| `traefik` | Traefik defaults: file provider, `providersThrottleDuration` 2 s |
| `traefik-fast` | `providersThrottleDuration: 0s` — the counterpart of `goma-fast` |
| `nginx` | config directory, `SIGHUP` |
| `haproxy` | regenerated single file, `SIGUSR2` to the master |

## Adding a gateway

Add a case to each `case "$gw" in` block in `lib/gateways.sh` — `gw_prepare`, `gw_exec`,
`gw_health_url`, `gw_route_pool`, `gw_commit`, `gw_drop_routes`, `gw_route_count`,
`gw_version` — plus a template under `gateways/<name>/`, a binary in
`docker/Dockerfile`, the binary check in `bench.sh`, and an entry in `ORDER`/`LABEL` in
`scripts/summarize.py`. Then:

```sh
GATEWAYS=<name> RUN_STEPS=smoke ./scripts/docker-run.sh
```

Smoke must pass before any scenario result from that gateway means anything. It checks
that the gateway starts, serves a route, hot-adds a second one, repoints an existing
one, answers 404 (not 5xx) for an undefined route, and load-balances a pool.

## benchtool

One static binary, no dependencies outside the standard library.

| Subcommand | Job |
|---|---|
| `backend` | origin server; echoes `X-Backend-Id`, counts requests and accepted connections |
| `probe` | reads `{"index","at","url"}` records on stdin, times each route to its first 200 |
| `churn` | hammers one URL, reports codes, which origin answered per 100 ms bucket, and how many times that changed |
| `failover` | rate-limited load over N paths, per-second timeline of successes and failures |
| `sample` | CPU and RSS of a process tree from `/proc`, accumulated per pid across worker turnover |

## Things that will bite you

- **A backgrounded shell function is a forked subshell.** `f args &` makes `$!` the
  subshell's pid, not the program's, and every signal the harness sends then misses the
  gateway. Pinning is done with a command-prefix array (`"${GW_PIN[@]}" setsid ...`)
  because `taskset` and `setsid` both exec in place.
- **`kill -SIGNAL ""` and `kill -SIGNAL 0` signal your own process group.** Both kill the
  harness. `gw_signal` guards against it.
- **HAProxy's master relays signals to its process group.** A `SIGUSR2` sent to a master
  that shares your group takes you down with it. Every gateway is started under `setsid`.
- **HAProxy drops a `SIGUSR2` that arrives during a reload.** `gw_commit` waits for
  `Loading success` in its log before returning, and that wait is charged to HAProxy.
- **`pkill -f <pattern>` matches the shell running your command.** If the pattern appears
  anywhere in your own command line, you kill yourself. The harness kills by pid only.
- **Editing a shell script while bash is executing it corrupts the running script.** bash
  reads from a byte offset; an edit that shifts bytes makes it resume mid-token. The
  runner image mounts the repository, so this applies there too: never patch a scenario
  during a run.
- **`(exec 3<>/dev/tcp/...)` can replace the running shell** instead of forking, silently
  ending the script. `port_open` uses `timeout 1 bash -c` instead.
- **Summing a process tree's CPU at each sample loses every process that exited in
  between.** nginx and HAProxy replace workers on every reload, so this reports reload
  cost as roughly zero, and the delta can go negative. `benchtool sample` accumulates
  per-pid and keeps the last reading of processes that are gone. `docker stats` has the
  same bug, which is one reason the image runs the gateways as processes inside one
  container rather than one container per gateway.
- **An origin or gateway left over from a previous run silently answers for the new
  one.** `ensure_port_free` reclaims every port before use; the pid file alone is not
  enough, because wiping `RUN_DIR` orphans it.
- **macOS ships bash 3.2.** `scripts/docker-run.sh` runs on the host, so it avoids
  `"${a[@]}"` on possibly-empty arrays under `set -u`. Everything else runs in the
  image's bash 5.
