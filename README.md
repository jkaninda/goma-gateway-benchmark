# Goma Gateway benchmark

A port of [NoOverflow/gateway-api-bench](https://github.com/NoOverflow/gateway-api-bench)
([README-v3](https://github.com/NoOverflow/gateway-api-bench/blob/main/README-v3.md)) to
[Goma Gateway](https://github.com/jkaninda/goma-gateway), with Traefik, nginx and HAProxy
as reference points.

It measures **Goma Gateway 1.2.1** against Traefik 3.7.19, nginx 1.30.7 and HAProxy 3.4.8,
on route propagation, live route changes, backend failover, route-table scale, traffic,
upstream connection reuse, idle footprint and shutdown.

- [What this is, and what it is not](#what-this-is-and-what-it-is-not)
- [Setup](#setup)
- [Methodology](#methodology)
- [Results](#results)
  - [Route propagation](#route-propagation)
  - [Route changes](#route-changes)
  - [Backend failover](#backend-failover)
  - [Route scale](#route-scale)
  - [Traffic performance](#traffic-performance)
  - [Upstream connection reuse](#upstream-connection-reuse)
  - [Idle footprint](#idle-footprint)
  - [Graceful shutdown](#graceful-shutdown)
- [Summary of findings](#summary-of-findings)
- [Limitations](#limitations)
- [What to do next](#what-to-do-next)
- [Reproducing](#reproducing)
- [License](#license)

## What this is, and what it is not

The upstream benchmark measures **Kubernetes Gateway API implementations**: it installs
controllers on a cluster, creates `Gateway` and `HTTPRoute` resources, and watches what
the controllers and their data planes do. Goma Gateway is a standalone proxy configured by
files or by a provider, so the suite cannot be pointed at it.

What ports cleanly is the *set of questions*. Every scenario asks what the upstream one
asks, against the mechanism each gateway actually has:

| Upstream scenario | Here |
|---|---|
| Route propagation (create HTTPRoute, probe until 200) | Write a route file, probe until 200 |
| Route changes (rewrite one HTTPRoute repeatedly) | Rewrite one route file repeatedly |
| Backend failover (blackhole one pod behind 16 routes) | Blackhole one origin behind 16 routes |
| Route scale (1,000 routes, churn) | 1,000 routes, 120 s of churn |
| Traffic performance (fortio, uncapped, per connection count) | Same, same tool |
| Attached routes / ListenerSet scale | **Dropped**: Gateway API status machinery with no counterpart |
| — | Upstream connection reuse |
| — | Idle footprint, startup time, and behaviour on SIGTERM |

It is not a Kubernetes benchmark: nothing here describes Goma under
[goma-operator](https://github.com/jkaninda/goma-operator). Absolute throughput describes
this machine only. The control-plane numbers and the per-core ratios travel; raw req/s
does not.

## Setup

Two full runs on the same host, back to back on 2026-11-19:
[`results/run-1`](results/run-1/summary.md) and [`results/run-2`](results/run-2/summary.md).
The tables below are run-1. Where run-2 differs by more than a few percent, both are
shown.

| Component | Version | How it is driven |
|---|---|---|
| Goma Gateway | 1.2.1 | `goma`: file provider, `watch: true`, default 500 ms debounce |
| Goma Gateway | 1.2.1 | `goma-fast`: same, `providers.file.debounce: 0s` |
| Goma Gateway | 1.2.1 | `goma-reload`: `watch: false` + `POST /gateway/reload` after each write |
| Traefik | 3.7.19 | `traefik`: file provider, `watch: true`, default 2 s `providersThrottleDuration` |
| Traefik | 3.7.19 | `traefik-fast`: same, `providersThrottleDuration: 0s` |
| nginx | 1.30.7 | config directory + `SIGHUP` |
| HAProxy | 3.4.8 | regenerated config + `SIGUSR2` |
| fortio | 1.77.0 | load generator (same tool as upstream) |

Every binary is an upstream release, copied out of the project's official container image
into one runner image ([`docker/Dockerfile`](docker/Dockerfile)).

**Host**: KVM virtual machine, 8 vCPU (AMD EPYC), 16 GB RAM, AlmaLinux 10.3 (kernel 6.12),
Docker 29.10, x86_64. **The gateway is pinned to 2 dedicated vCPUs** (CPUs 2–3); the
origins, fortio, the probers and the sampler run on the other 6 (CPUs 0–1, 4–7). nginx and
HAProxy get 2 workers / threads; the Go gateways size `GOMAXPROCS` from their affinity
mask. One gateway runs at a time, always on the same port.

Every gateway is configured as thinly as it can be: one HTTP entry point, no TLS, no
middleware, no caching, no compression, no access log, metrics off. Routes are `/r-<n>/`
with the prefix stripped before proxying. Goma's passive health checks are left on, as
they are by default.

Goma appears three times and Traefik twice on purpose. Each extra row is the same binary
with one setting changed, so the default policy (a watch debounce, a provider throttle)
can be told apart from what the gateway actually costs to apply a change. `goma` vs
`traefik` is the defaults comparison; `goma-fast` vs `traefik-fast` is the tuned one;
`goma-reload` has no Traefik counterpart.

## Methodology

- **The gateway does not share cores with the load.** With everything on the same CPUs,
  fortio and the origin take CPU from whichever gateway is being measured, and absolute
  throughput mostly describes that fight. The harness re-executes itself under
  `taskset -c $LOAD_CPUS` and starts only the gateway on `GW_CPUS`.
- **The load side is checked, not assumed.** Each traffic point records how busy the six
  load CPUs were. The highest reading in either run was 80%, so no throughput number here
  is a load-generator ceiling.
- **"Commit" is defined so that neither family is charged for the other's design.** Goma
  and Traefik watch a directory; nginx and HAProxy do nothing until signalled. The harness
  starts the clock, writes the route file (atomic rename), and immediately signals the
  gateways that need it. Everything after that (debounce, throttle, parse, worker respawn)
  is inside the measurement.
- **A dropped reload signal is not a slow reload.** HAProxy ignores a `SIGUSR2` that
  arrives during a reload, so the harness waits for HAProxy to log each reload before
  returning, and that wait is charged to HAProxy.
- **CPU is accumulated per pid.** nginx and HAProxy replace workers on every reload; a
  sampler that sums the live tree (or reads `docker stats`) drops the CPU of every worker
  that exited between samples. `benchtool sample` keeps the final reading of retired pids.
- **"Zero errors during route changes" must mean something happened.** The route flips
  between two origins an odd number of times; the prober records which origin answered in
  each 100 ms bucket and counts how many times the answer changed. That count is a column.
- **Every gateway answers 404 for a route that does not exist.** HAProxy gets an explicit
  404 default backend, since its default 503 would score as a "5xx on an unprogrammed
  route".
- **Origins are long-lived processes on fixed ports**, so a failed request cannot be blamed
  on a cold or terminating backend.
- **Defaults, with three disclosures** (repeated under [limitations](#limitations)):
  HAProxy's servers carry `check inter 2s fall 2 rise 2` (active health checks nobody else
  has); nginx's defaults give it passive eviction plus retry on the next upstream; nginx's
  upstreams set `keepalive 32`, because without it nginx opens a connection per request.
- **Smoke first.** Each run begins by checking that every configuration starts, serves a
  route, hot-adds a second, repoints one, answers 404 for an undefined route and
  load-balances a pool. All seven passed in both runs.

## Results

Full tables: [`results/run-1/summary.md`](results/run-1/summary.md) and
[`results/run-2/summary.md`](results/run-2/summary.md), generated from the CSVs in each
directory by `scripts/summarize.py`.

### Route propagation

100 routes are declared one at a time; each is probed every 2 ms until it answers 200. The
clock starts immediately before the route file is written. Any non-404 answer while
waiting counts as a defect.

|  | Median (ms) | p99 (ms) | Max (ms) | Non-404 while waiting |
|---|---:|---:|---:|---:|
| Goma (file watch) | 508 | 513 | 513 | 0 |
| **Goma (debounce 0s)** | **7** | 11 | 12 | 0 |
| **Goma (reload API)** | **12** | 16 | 17 | 0 |
| Traefik | 1,896 | 2,014 | 2,018 | 0 |
| Traefik (throttle 0s) | 47 | 108 | 112 | 0 |
| nginx | 108 | 111 | 112 | 0 |
| HAProxy | 30 | 40 | 43 | 0 |

Run-2 medians were within 1 ms of these for every configuration.

- ✅ With the debounce turned off, Goma programs a new route in **7 ms median**, the
  fastest in the set. The reload API is right behind at 12 ms, including its HTTP round
  trip. Upstream measured 14 ms for Agentgateway and 24 ms for Envoy Gateway on their own
  hardware.
- The default (508 ms) is the 500 ms debounce plus about 8 ms of work.
- Turning off Traefik's throttle brings it from 1.9 s to 47 ms. Tuned, both Go gateways sit
  well inside nginx's 108 ms reload.
- **No gateway answered 5xx on a route that was not ready.** All seven configurations
  return 404 until the route is live.

### Route changes

One route is rewritten 11 times while four clients probe it continuously, in two passes:
changes 0.2 s apart and 1.5 s apart. "Changes seen" counts how often the answering origin
actually changed.

|  | 0.2 s apart: errors | 0.2 s: changes seen (of 11) | 1.5 s apart: errors | 1.5 s: changes seen (of 11) |
|---|---:|---:|---:|---:|
| Goma (file watch) | 0 | **1** | 0 | 11 |
| Goma (debounce 0s) | 0 | 11 | 0 | 11 |
| Goma (reload API) | 0 | 11 | 0 | 11 |
| Traefik | 0 | **1** | 0 | **5** |
| Traefik (throttle 0s) | 0 | 11 | 0 | 11 |
| nginx | 0 | 11 | 0 | 11 |
| HAProxy | 0 | 11 | 0 | 11 |

Identical in run-2. Between 78k and 392k requests per cell, every one a 200.

- ✅ **Every gateway served every request through every change, in every mode.** Upstream
  this is the scenario where Nginx Gateway Fabric returned 500 for 58.7% of requests.
- ⚠️ Goma's default turns eleven writes 0.2 s apart into one change. Its debounce is capped
  at 4× (2 s) while writes keep arriving, and 11 writes in 2.2 s fit inside about one
  window. With the debounce at 0 or with the reload API, every change lands.
- Traefik's default 2 s throttle drops more than half of the changes even 1.5 s apart.

### Backend failover

Four origins behind 16 routes. One origin is made unreachable (iptables
`REJECT --reject-with tcp-reset`) for 22 s, three times with 8 s back up in between,
while requests rotate over the paths at 200/s. Each gateway runs with its own defaults.

|  | Requests | Failed | Failed % | Longest failure streak | Codes |
|---|---:|---:|---:|---:|---|
| **Goma (all modes)** | 19,200 | **10** | **0.05%** | 1 s | 502 |
| Traefik | 19,200 | 3,306 | 17.22% | 23 s | 502 |
| Traefik (throttle 0s) | 19,200 | 3,304 | 17.21% | 23 s | 502 |
| nginx | 19,200 | 0 | 0.00% | – | – |
| HAProxy | 16,338 | 96 | 0.59% | 2 s | connection error |

Run-2: Goma 10 in every mode again, Traefik 3,303 and 3,299, nginx 0, HAProxy 94 of 16,996.

- ✅ **Goma's passive health check holds failures to 10 requests in 90 s.** The timeline
  shows how: 2 failures when the origin dies (`maxFails: 2`), then exactly one every 10 s
  for the rest of the test, as each ejection expires and one request is let through to
  test the origin. 2 + 1 + 1 for the first outage, 1 + 1 + 1 for each of the next two.
- The price is that a recovered origin stays out until its ejection expires. Here each
  test request happened to land in the next outage, so Goma sent the blackholed origin
  about 290 requests over the whole test, against about 6,300 for each healthy one.
- nginx loses nothing because it *retries* the failed request on another upstream
  (`proxy_next_upstream`). Goma ejects but does not retry, so the request that discovers a
  dead origin fails.
- ❌ Traefik round-robins onto the dead origin for the full 22 s, every cycle: a quarter of
  all requests fail while one of four origins is down. This is what upstream gave Envoy
  Gateway an ❌ for.
- HAProxy's active checks take the origin out within one 2 s check interval. Its failures
  are client-side connection errors rather than HTTP statuses, and requests stuck on the
  dead server held up the closed-loop driver, so HAProxy completed fewer requests than the
  19,200 scheduled.

### Route scale

1,000 routes created in batches of 50, then 120 s of continuous churn (25 routes repointed
per batch, two batches per second), then 30 s of quiet, then every route deleted. A canary
route that is never touched is probed throughout the churn.

| Phase |  | Mean CPU (cores) | Peak CPU | Mean RSS (MB) | Peak RSS (MB) |
|---|---|---:|---:|---:|---:|
| 120 s of churn | Goma (file watch) | 0.79 | 0.86 | 72 | 116 |
| | Goma (debounce 0s) | 0.89 | 1.18 | 92 | 148 |
| | Goma (reload API) | 0.78 | 0.86 | 74 | 118 |
| | Traefik | 1.62 | 1.70 | 128 | 134 |
| | Traefik (throttle 0s) | 1.64 | 1.78 | 128 | 135 |
| | nginx | 0.18 | 0.32 | 169 | 247 |
| | HAProxy | 0.29 | 0.50 | 63 | 102 |
| 30 s quiet after churn | Goma (file watch) | 0.004 | 0.20 | 96 | 108 |
| | Goma (debounce 0s) | 0.005 | 0.24 | 140 | 140 |
| | Goma (reload API) | 0.007 | 0.38 | 51 | 51 |
| | Traefik | **1.38** | 1.44 | 126 | 132 |
| | Traefik (throttle 0s) | **1.41** | 1.46 | 125 | 127 |
| | nginx | 0.002 | 0.10 | 151 | 151 |
| | HAProxy | 0.027 | 0.36 | 60 | 60 |

Mean CPU during churn and quiet agreed with run-2 to within 0.01 cores for every gateway.
Goma's memory after churn did not: 59–66 MB in run-2 for the two watch modes against
96–140 MB here, so read that column as "where the Go heap happened to be".

The canary served **0 errors** for every gateway in both runs (between 291k and 559k
requests each). Batches applied in the fixed 120 s: 223–225 for the file watchers, 215–216
for nginx, 200–202 for `goma-reload` and HAProxy, whose synchronous commit makes each
batch slower.

- ✅ Goma absorbs 50 route changes per second across a 1,000-route table for about 0.8 of a
  core, half of Traefik's 1.6, and drops to ~0 the moment churn stops.
- `goma-fast` pays for applying every file event individually: the highest peak CPU and
  memory of the Goma modes. The default debounce exists for this.
- ❌ Traefik keeps **about 1.4 cores busy for the entire quiet phase**, with no configuration
  changing, in both runs and at both throttle settings. It stops only after the routes are
  deleted.
- nginx is cheapest on CPU but holds the most memory: 247 MB peak while old workers drain,
  151 MB after churn.

### Traffic performance

fortio, uncapped, 20 s per point after a discarded 5 s warm-up, 100-byte response body,
one origin. The gateway has 2 vCPUs to itself.

**Throughput (req/s)**

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma | 3,986 | 19,967 | 36,157 | 39,074 | 32,548 |
| Goma (debounce 0s) | 4,009 | 20,216 | 36,856 | 39,839 | 33,169 |
| Traefik | 3,879 | 19,198 | 36,334 | 41,503 | 36,404 |
| Traefik (throttle 0s) | 3,956 | 19,318 | 37,918 | 39,634 | 35,023 |
| nginx | 5,891 | 43,687 | 139,585 | 115,969 | 58,545 |
| HAProxy | 5,706 | 42,307 | 128,837 | 145,776 | 160,479 |

**Throughput per core of gateway CPU (req/s per core)**

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma | 5,210 | 15,649 | 21,654 | 22,456 | 18,918 |
| Goma (debounce 0s) | 5,226 | 15,973 | 22,053 | 22,950 | 19,244 |
| Traefik | 4,957 | 14,915 | 21,621 | 23,726 | 21,286 |
| Traefik (throttle 0s) | 5,062 | 14,966 | 22,502 | 22,665 | 20,362 |
| nginx | 19,637 | 47,170 | 110,647 | 80,620 | 35,084 |
| HAProxy | 15,305 | 36,247 | 88,806 | 95,679 | 101,800 |

**p99 latency (ms)**

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma | 0.99 | 1.97 | 3.24 | 10.88 | 22.82 |
| Goma (debounce 0s) | 0.99 | 1.94 | 3.21 | 10.86 | 21.68 |
| Traefik | 0.99 | 2.20 | 3.89 | 11.24 | 20.54 |
| Traefik (throttle 0s) | 0.99 | 2.20 | 3.80 | 11.41 | 22.32 |
| nginx | 0.99 | 0.99 | 1.00 | 11.18 | 46.05 |
| HAProxy | 0.99 | 0.99 | 1.00 | 2.91 | 4.55 |

**Peak throughput, both runs (req/s)**

|  | run-1 | run-2 |
|---|---:|---:|
| Goma | 39,074 | 36,949 |
| Goma (debounce 0s) | 39,839 | 38,107 |
| Goma (reload API) | 37,404 | 36,675 |
| Traefik | 41,503 | 41,761 |
| Traefik (throttle 0s) | 39,634 | 38,468 |
| nginx | 139,585 | 137,543 |
| HAProxy | 160,479 | 153,387 |

Goma's three modes differ only in how they reload configuration, not in how they proxy, so
the spread between them (up to 6% at a given point) is the noise floor of this host. The
reload-API rows are in the full summaries.

- **Goma and Traefik are level.** Both run at 21–24k req/s per core at 32–128 connections,
  with the same p99. Traefik's default build is 6–13% ahead at its peak (128 connections)
  in the two runs; the tuned pair is within 1%.
- ❌ Both are **4–5× behind HAProxy and nginx per core** (about 22k against 89–111k at 32
  connections). That gap belongs to Go reverse proxies as a class as much as to Goma:
  Traefik sits in the same place.
- No gateway returned a single non-200 at any connection count, in either run.
- **The load side was not the limit.** The six load CPUs were at most 57% busy while
  driving Goma and Traefik, and at most 80% for nginx and HAProxy, which pushed 3–4× more
  traffic through the same load setup. Neither Go gateway used its full 2 cores (both
  peaked at about 1.75).
- nginx falls off at 256 connections (about 59k req/s and a 46 ms p99, against about 139k
  at 32), in both runs, while the load CPUs sat at 42%. Its pool also opened about 1,380
  new upstream connections in the pooling test, consistent with the harness-set
  `keepalive 32` being outgrown at high concurrency. Not investigated further.

### Upstream connection reuse

The origin counts accepted TCP connections. Counters are reset after a warm-up, so this is
*new* upstream connections during a 10 s, 32-connection window.

|  | Requests | New upstream connections |
|---|---:|---:|
| Goma | 371,681 | **0** |
| Traefik | 364,035 | 0 |
| nginx | 1,383,095 | 1,384 |
| HAProxy | 1,230,996 | 188 |

Run-2: Goma and Traefik 0, nginx 1,379, HAProxy 243.

Goma pools upstream connections correctly. nginx's count is the pool the harness bounded
(`keepalive 32`) being recycled, about one new connection per 1,000 requests; HAProxy's
includes its health checks.

### Idle footprint

**Resident memory when idle (MB), range over both runs**

|  | 1 route | 100 routes | 1,000 routes | Processes |
|---|---:|---:|---:|---:|
| Goma (file watch) | 22.8 | 25.9–28.3 | 56.6–63.8 | 1 |
| Goma (reload API) | 20.5–22.4 | 24.7–25.1 | 48.5–52.8 | 1 |
| Traefik | 93.0–94.1 | 98.0 | 106.8–110.8 | 1 |
| nginx | 22.9–23.2 | 29.1–29.8 | 88.8–89.1 | 3 |
| HAProxy | 46.6–50.4 | 48.3–51.3 | 62.9–63.1 | 2 |

nginx and HAProxy are summed over their processes, so shared pages are counted more than
once.

**Time from exec to serving the last route in the table (ms), range over both runs**

|  | 1 route | 100 routes | 1,000 routes |
|---|---:|---:|---:|
| Goma (file watch) | 70–83 | 61–83 | 107–110 |
| Traefik | 84–101 | 66–99 | 219–381 |
| nginx | 24–25 | 24–28 | 36–50 |
| HAProxy | 41–45 | 42–48 | 82–88 |

- ✅ Goma is the smallest gateway in the set at rest: about 21–23 MB with one route, a
  quarter of Traefik's 93 MB and level with nginx. It starts and serves 1,000 routes in
  about 110 ms.

### Graceful shutdown

SIGTERM at three moments: the instant the listener opens, when idle, and while a client
keep-alive connection is held open. Time until the port is released, range over both runs.

|  | Signalled at startup | Idle | Client connection open |
|---|---:|---:|---:|
| **Goma (all modes)** | 2–15 ms | 2–17 ms | 2–15 ms |
| Traefik | 2–3 ms | 2–3 ms | 2–3 ms |
| nginx | 26–39 ms | 27–40 ms | 29–41 ms |
| HAProxy | 2 ms | 2 ms | 3 ms |

✅ Every gateway exits promptly in every case, including a SIGTERM that arrives the instant
the listener opens. Differences below about 20 ms are at the 10 ms polling floor of the
measurement and should not be ranked.

## Summary of findings

|  | Goma 1.2.1 | Traefik 3.7 | nginx 1.30 | HAProxy 3.4 |
|---|---|---|---|---|
| Route propagation | ⚠️ 508 ms default; ✅ 7 ms with debounce 0s, 12 ms by API | ❌ 1.9 s default; ✅ 47 ms with throttle 0s | ✅ 108 ms | ✅ 30 ms |
| 5xx on a route not yet programmed | ✅ never | ✅ never | ✅ never | ✅ never |
| Errors during route changes | ✅ none | ✅ none | ✅ none | ✅ none |
| Rapid changes applied (0.2 s apart) | ⚠️ 1 of 11 by default; ✅ 11 tuned | ❌ 1 of 11 by default; ✅ 11 tuned | ✅ all | ✅ all |
| Backend failover (defaults) | ✅ 0.05% failed | ❌ 17.2% failed | ✅ 0% | ✅ 0.6% (active checks) |
| Route scale (1,000 + churn) | ✅ 0.8 cores, idle after | ❌ 1.6 cores, 1.4 cores idle after | ✅ CPU, ⚠️ memory | ✅ |
| Throughput per core | ⚠️ ~22k (level with Traefik) | ⚠️ ~22–24k | ✅ up to 111k | ✅ up to 102k |
| Upstream pooling | ✅ | ✅ | ✅ | ✅ |
| Idle footprint (1 route) | ✅ 23 MB | ❌ 93 MB | ✅ 23 MB | ✅ 47 MB |
| SIGTERM just after start | ✅ | ✅ | ✅ | ✅ |

## Limitations

**Config asymmetries that move numbers**

- HAProxy gets active health checks (`check inter 2s fall 2 rise 2`) and nobody else does.
  It is why HAProxy scores 0.6% on failover rather than ~17%, why it has non-zero CPU in
  the quiet phase, and part of why it opens upstream connections in the pooling test.
- nginx's upstream pool size is set by the harness (`keepalive 32`).
- `goma-reload` has no Traefik counterpart; Traefik has no push-reload endpoint.

**Measurement caveats**

- The host is a virtual machine. Pinning keeps the gateway off the load generator's vCPUs,
  but other tenants of the physical host can still affect it. The two runs agree within
  1 ms on propagation medians, exactly on failover and change counts, within 0.01 cores on
  route-scale CPU, and within about 6% on throughput.
- Two runs show which numbers are stable; they are not enough to put confidence intervals
  on the ones that are not.
- RSS is summed across the process tree, so nginx (3 processes) and HAProxy (2) are
  overstated against the single-process Go gateways. Go's RSS after heavy churn depends on
  where the garbage collector is and varied by up to 2× between runs.
- Startup and shutdown are differences between two 10 ms polls: anything under ~20 ms is at
  the floor. Treat those tables as an order of magnitude.
- The failover driver is closed-loop (16 workers, 3 s timeout). With TCP resets most
  failures are immediate, but a gateway that stalls records fewer requests and fewer
  failures than it would under open-loop load (see HAProxy).
- Timelines bucket requests by completion time, so recovery is smeared later by about one
  request duration.
- The churn loop runs for a fixed time; a gateway with a slower commit gets through fewer
  batches (`goma-reload` and HAProxy: about 200 of 225).
- In the create phase nginx and HAProxy are committed every 50 routes, while the file
  watchers see up to 1,000 individual events.

**Scope**

- No TLS, no middleware, no HTTP/2, no request bodies, one origin in the traffic test.
- Nothing here measures a Kubernetes deployment.

## What to do next

1. **Throughput per core is Goma's gap**: 4–5× behind HAProxy and nginx, level with
   Traefik. `GOMA_PPROF_ADDR` makes the next step cheap: profile a 32-connection run and
   look at what is left per request.
2. **Retry on the next backend after a connection failure.** Passive ejection keeps
   failover to 10 failed requests in 90 s; those are the requests that discover a dead
   origin. Retrying them on a healthy peer, for idempotent requests, as nginx does by
   default, would take it to zero.
3. **Consider a lower default debounce.** With the 4× cap and atomic writes, the default
   500 ms buys little that a 50–100 ms window would not. Propagation at 7 ms vs 508 ms is
   the largest difference any single setting makes in this benchmark.
4. **Find out what Traefik is doing for 1.4 cores** in the quiet phase after churn. Not a
   Goma problem, but it reproduces in every run and is worth reporting upstream.

## Reproducing

```sh
./scripts/docker-run.sh              # builds the runner image, runs everything (~65 min)
```

The published runs used every CPU of the 8-vCPU host:

```sh
RUN_ID=run-1 GW_CPUS=2-3 LOAD_CPUS=0-1,4-7 ./scripts/docker-run.sh
```

Results land in `results/<run-id>/` as CSV plus a generated `summary.md`, with
`versions.csv` and `env.txt` recording exactly what ran and where. Any Docker host with
Linux containers works, including Docker Desktop or OrbStack on macOS. The container is
privileged (for the failover scenario's iptables rule) and has no network beyond its own
loopback. To run on a Linux host directly instead, see [HARNESS.md](HARNESS.md).

| Variable | Default | |
|---|---|---|
| `RUN_STEPS` | all | `RUN_STEPS="traffic footprint" ./scripts/docker-run.sh` |
| `GATEWAYS` | `goma goma-fast goma-reload traefik traefik-fast nginx haproxy` | one gateway at a time regardless |
| `RUN_ID` | UTC timestamp | reuse one to add scenarios to an existing run |
| `GW_CPUS` / `LOAD_CPUS` | `2-3` / `4-7` | needs 8 CPUs as set; `GW_CPUS=` turns pinning off |
| `GOMA_VERSION`, `TRAEFIK_VERSION`, `HAPROXY_VERSION`, `NGINX_VERSION`, `FORTIO_VERSION` | see `docker/Dockerfile` | build the runner with another version |
| `PROP_ROUTES` | 100 | routes in the propagation test |
| `SCALE_ROUTES` / `SCALE_CHURN` | 1000 / 120 s | route-scale size and churn duration |
| `TRAFFIC_CONNS` / `TRAFFIC_DURATION` | `1 8 32 128 256` / 20 s | |
| `FO_CYCLES` / `FO_DOWN` | 3 / 22 s | failover outage pattern |

`python3 scripts/summarize.py results/<run-id>` regenerates a report from its CSVs without
re-running anything. `RUN_STEPS=smoke` alone checks that every configuration starts,
serves, hot-adds, repoints, 404s and load-balances: run it first after changing a version.

See [HARNESS.md](HARNESS.md) for how the pieces fit together and how to add a gateway.

## License

Apache License 2.0. See [LICENSE](LICENSE).
