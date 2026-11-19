# Goma Gateway benchmark — run `run-1`

## What ran

| Component | Version |
|---|---:|
| Goma (file watch) | 1.2.1 |
| Goma (file watch, debounce 0s) | 1.2.1 |
| Goma (reload API) | 1.2.1 |
| Traefik | 3.7.19 |
| Traefik (throttle 0s) | 3.7.19 |
| nginx | 1.30.7 |
| HAProxy | 3.4.8-1b15b69 |
| fortio | 1.77.0 |

Host: 8 vCPU (AMD EPYC Processor (with IBPB), x86_64), 15730 MB RAM, Linux 6.12.0-264.16.1.el10_3.x86_64, runtime: docker. The gateway is pinned to CPUs 2-3 (2 cores); origins, fortio and the probers run on CPUs 0-1,4-7.


## Route propagation

|  | Median (ms) | p99 (ms) | Max (ms) | Routes answering non-404 while waiting | Timeouts |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 508 | 513 | 513 | 0 | 0 |
| Goma (file watch, debounce 0s) | 7 | 11 | 12 | 0 | 0 |
| Goma (reload API) | 12 | 16 | 17 | 0 | 0 |
| Traefik | 1,896 | 2,014 | 2,018 | 0 | 0 |
| Traefik (throttle 0s) | 47 | 108 | 112 | 0 | 0 |
| nginx | 108 | 111 | 112 | 0 | 0 |
| HAProxy | 30 | 40 | 43 | 0 | 0 |


## Route changes


### Rapid changes

|  | Requests | Errors | Error % | Codes | Origins hit | Changes seen by clients (of 11) |
|---|---:|---:|---:|---:|---:|---:|
| Goma (file watch) | 83,209 | 0 | 0.00 | 200:83209 | c9101:41123 c9102:42086 | 1 |
| Goma (file watch, debounce 0s) | 78,676 | 0 | 0.00 | 200:78676 | c9101:17363 c9102:61313 | 11 |
| Goma (reload API) | 78,522 | 0 | 0.00 | 200:78522 | c9101:19729 c9102:58793 | 11 |
| Traefik | 79,781 | 0 | 0.00 | 200:79781 | c9101:25891 c9102:53890 | 1 |
| Traefik (throttle 0s) | 82,255 | 0 | 0.00 | 200:82255 | c9101:20844 c9102:61411 | 11 |
| nginx | 116,225 | 0 | 0.00 | 200:116225 | c9101:28295 c9102:87930 | 11 |
| HAProxy | 109,441 | 0 | 0.00 | 200:109441 | c9101:31111 c9102:78330 | 11 |


### Spaced-out changes

|  | Requests | Errors | Error % | Codes | Origins hit | Changes seen by clients (of 11) |
|---|---:|---:|---:|---:|---:|---:|
| Goma (file watch) | 269,229 | 0 | 0.00 | 200:269229 | c9101:111447 c9102:157782 | 11 |
| Goma (file watch, debounce 0s) | 264,889 | 0 | 0.00 | 200:264889 | c9101:104686 c9102:160203 | 11 |
| Goma (reload API) | 265,405 | 0 | 0.00 | 200:265405 | c9101:102945 c9102:162460 | 11 |
| Traefik | 263,265 | 0 | 0.00 | 200:263265 | c9101:76179 c9102:187086 | 5 |
| Traefik (throttle 0s) | 260,971 | 0 | 0.00 | 200:260971 | c9101:104676 c9102:156295 | 11 |
| nginx | 392,352 | 0 | 0.00 | 200:392352 | c9101:153476 c9102:238876 | 11 |
| HAProxy | 362,691 | 0 | 0.00 | 200:362691 | c9101:147630 c9102:215061 | 11 |


## Backend failover

|  | Requests | Failed | Failed % | Longest unbroken failure streak (s) | Seconds with failures | Codes |
|---|---:|---:|---:|---:|---:|---:|
| Goma (file watch) | 19,200 | 10 | 0.05 | 1 | 9 | 200:19190 502:10 |
| Goma (file watch, debounce 0s) | 19,200 | 10 | 0.05 | 1 | 9 | 200:19190 502:10 |
| Goma (reload API) | 19,200 | 10 | 0.05 | 1 | 9 | 200:19190 502:10 |
| Traefik | 19,200 | 3,306 | 17.22 | 23 | 68 | 200:15894 502:3306 |
| Traefik (throttle 0s) | 19,200 | 3,304 | 17.21 | 23 | 69 | 200:15896 502:3304 |
| nginx | 19,200 | 0 | 0.00 | 0 | 0 | 200:19200 |
| HAProxy | 16,338 | 96 | 0.59 | 2 | 6 | conn_error:96 200:16242 |


## Route scale (1000 routes)


### Creating the table

|  | Seconds | Mean CPU (cores) | Peak CPU (cores) | Mean RSS (MB) | Peak RSS (MB) |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 1.6 | 0.093 | 0.14 | 22.8 | 22.8 |
| Goma (file watch, debounce 0s) | 1.2 | 1.660 | 1.72 | 46.2 | 49.4 |
| Goma (reload API) | 1.8 | 0.447 | 0.62 | 45.9 | 51.2 |
| Traefik | 2.1 | 1.320 | 1.32 | 106.9 | 107.9 |
| Traefik (throttle 0s) | 1.3 | 1.900 | 1.92 | 119.0 | 122.4 |
| nginx | 1.8 | 0.067 | 0.10 | 42.1 | 44.6 |
| HAProxy | 1.4 | 0.150 | 0.16 | 53.6 | 55.9 |


### Churning the table

|  | Seconds | Mean CPU (cores) | Peak CPU (cores) | Mean RSS (MB) | Peak RSS (MB) |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 119.9 | 0.791 | 0.86 | 72.2 | 116.0 |
| Goma (file watch, debounce 0s) | 120.1 | 0.889 | 1.18 | 92.1 | 148.4 |
| Goma (reload API) | 119.7 | 0.781 | 0.86 | 74.4 | 117.6 |
| Traefik | 119.8 | 1.618 | 1.70 | 127.8 | 133.8 |
| Traefik (throttle 0s) | 120.4 | 1.637 | 1.78 | 127.5 | 134.5 |
| nginx | 120.0 | 0.176 | 0.32 | 168.8 | 246.8 |
| HAProxy | 119.3 | 0.288 | 0.50 | 63.1 | 101.6 |


### Steady state after churn

|  | Seconds | Mean CPU (cores) | Peak CPU (cores) | Mean RSS (MB) | Peak RSS (MB) |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 30.0 | 0.004 | 0.20 | 95.8 | 107.8 |
| Goma (file watch, debounce 0s) | 30.0 | 0.005 | 0.24 | 140.2 | 140.2 |
| Goma (reload API) | 30.0 | 0.007 | 0.38 | 50.6 | 50.6 |
| Traefik | 30.0 | 1.377 | 1.44 | 125.6 | 132.3 |
| Traefik (throttle 0s) | 30.0 | 1.409 | 1.46 | 124.6 | 127.2 |
| nginx | 30.0 | 0.002 | 0.10 | 150.9 | 150.9 |
| HAProxy | 30.0 | 0.027 | 0.36 | 59.7 | 60.0 |


### After deleting every route

|  | Seconds | Mean CPU (cores) | Peak CPU (cores) | Mean RSS (MB) | Peak RSS (MB) |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 15.0 | 0.001 | 0.02 | 109.0 | 110.9 |
| Goma (file watch, debounce 0s) | 15.0 | 0.005 | 0.14 | 98.8 | 98.8 |
| Goma (reload API) | 15.0 | 0.001 | 0.02 | 50.6 | 50.6 |
| Traefik | 15.0 | 0.203 | 1.36 | 116.6 | 128.1 |
| Traefik (throttle 0s) | 15.0 | 0.203 | 1.44 | 107.1 | 109.3 |
| nginx | 15.0 | 0.000 | 0.00 | 124.4 | 124.4 |
| HAProxy | 15.1 | 0.003 | 0.06 | 50.7 | 60.0 |


### Churn batches completed in the fixed window

The churn loop runs for a fixed time, so a gateway whose commit is expensive gets through fewer batches — and therefore applies fewer changes — than one whose commit returns immediately.

|  | Routes | Churn seconds | Batches applied |
|---|---:|---:|---:|
| Goma (file watch) | 1000 | 120 | 225 |
| Goma (file watch, debounce 0s) | 1000 | 120 | 225 |
| Goma (reload API) | 1000 | 120 | 200 |
| Traefik | 1000 | 120 | 224 |
| Traefik (throttle 0s) | 1000 | 120 | 225 |
| nginx | 1000 | 120 | 216 |
| HAProxy | 1000 | 120 | 201 |


### An untouched route, probed throughout the churn

|  | Requests | Errors | Error % | Codes |
|---|---:|---:|---:|---:|
| Goma (file watch) | 383,969 | 0 | 0.00 | 200:383969 |
| Goma (file watch, debounce 0s) | 359,403 | 0 | 0.00 | 200:359403 |
| Goma (reload API) | 386,628 | 0 | 0.00 | 200:386628 |
| Traefik | 310,897 | 0 | 0.00 | 200:310897 |
| Traefik (throttle 0s) | 296,145 | 0 | 0.00 | 200:296145 |
| nginx | 557,278 | 0 | 0.00 | 200:557278 |
| HAProxy | 462,811 | 0 | 0.00 | 200:462811 |


## Traffic performance


### Throughput (req/s)

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 3,986 | 19,967 | 36,157 | 39,074 | 32,548 |
| Goma (file watch, debounce 0s) | 4,009 | 20,216 | 36,856 | 39,839 | 33,169 |
| Goma (reload API) | 4,006 | 20,045 | 35,565 | 37,404 | 32,511 |
| Traefik | 3,879 | 19,198 | 36,334 | 41,503 | 36,404 |
| Traefik (throttle 0s) | 3,956 | 19,318 | 37,918 | 39,634 | 35,023 |
| nginx | 5,891 | 43,687 | 139,585 | 115,969 | 58,545 |
| HAProxy | 5,706 | 42,307 | 128,837 | 145,776 | 160,479 |


### p50 latency (ms)

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 0.59 | 0.53 | 0.73 | 2.81 | 6.95 |
| Goma (file watch, debounce 0s) | 0.59 | 0.53 | 0.72 | 2.73 | 6.88 |
| Goma (reload API) | 0.59 | 0.53 | 0.75 | 2.93 | 6.99 |
| Traefik | 0.58 | 0.54 | 0.70 | 2.57 | 5.93 |
| Traefik (throttle 0s) | 0.59 | 0.54 | 0.68 | 2.69 | 6.11 |
| nginx | 0.55 | 0.52 | 0.51 | 0.75 | 1.89 |
| HAProxy | 0.56 | 0.51 | 0.51 | 0.70 | 1.57 |


### p99 latency (ms)

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 0.99 | 1.97 | 3.24 | 10.88 | 22.82 |
| Goma (file watch, debounce 0s) | 0.99 | 1.94 | 3.21 | 10.86 | 21.68 |
| Goma (reload API) | 0.99 | 1.95 | 3.22 | 11.07 | 21.95 |
| Traefik | 0.99 | 2.20 | 3.89 | 11.24 | 20.54 |
| Traefik (throttle 0s) | 0.99 | 2.20 | 3.80 | 11.41 | 22.32 |
| nginx | 0.99 | 0.99 | 1.00 | 11.18 | 46.05 |
| HAProxy | 0.99 | 0.99 | 1.00 | 2.91 | 4.55 |


### Gateway CPU during each point (cores)

Gateway CPU is sampled during each point and requests per second are divided by it. Absolute throughput depends on the host and on whether the gateway was pinned away from the load generator; this ratio travels better between machines.

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 0.77 | 1.28 | 1.67 | 1.74 | 1.72 |
| Goma (file watch, debounce 0s) | 0.77 | 1.27 | 1.67 | 1.74 | 1.72 |
| Goma (reload API) | 0.77 | 1.29 | 1.68 | 1.74 | 1.72 |
| Traefik | 0.78 | 1.29 | 1.68 | 1.75 | 1.71 |
| Traefik (throttle 0s) | 0.78 | 1.29 | 1.69 | 1.75 | 1.72 |
| nginx | 0.30 | 0.93 | 1.26 | 1.44 | 1.67 |
| HAProxy | 0.37 | 1.17 | 1.45 | 1.52 | 1.58 |


### Load-side CPU busy during each point (%)

Share of the load CPUs (fortio and the origin) in use. Near 100% means that point was capped by the load generator rather than the gateway.

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 11 | 36 | 51 | 53 | 50 |
| Goma (file watch, debounce 0s) | 11 | 36 | 51 | 53 | 49 |
| Goma (reload API) | 11 | 36 | 51 | 53 | 50 |
| Traefik | 11 | 36 | 52 | 57 | 50 |
| Traefik (throttle 0s) | 11 | 36 | 53 | 57 | 54 |
| nginx | 16 | 68 | 80 | 67 | 42 |
| HAProxy | 15 | 64 | 76 | 76 | 76 |


### Throughput per core of gateway CPU (req/s per core)

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 5,210 | 15,649 | 21,654 | 22,456 | 18,918 |
| Goma (file watch, debounce 0s) | 5,226 | 15,973 | 22,053 | 22,950 | 19,244 |
| Goma (reload API) | 5,229 | 15,548 | 21,176 | 21,509 | 18,890 |
| Traefik | 4,957 | 14,915 | 21,621 | 23,726 | 21,286 |
| Traefik (throttle 0s) | 5,062 | 14,966 | 22,502 | 22,665 | 20,362 |
| nginx | 19,637 | 47,170 | 110,647 | 80,620 | 35,084 |
| HAProxy | 15,305 | 36,247 | 88,806 | 95,679 | 101,800 |


### Non-200 responses under load

|  | Observed |
|---|---:|
| Goma (file watch) | none |
| Goma (file watch, debounce 0s) | none |
| Goma (reload API) | none |
| Traefik | none |
| Traefik (throttle 0s) | none |
| nginx | none |
| HAProxy | none |


## Upstream connection reuse

Counters are reset after a warm-up, so this column is *new* upstream connections opened during the measured window. A gateway that does not pool would open roughly one per request.

|  | Client connections | Requests | New upstream connections |
|---|---:|---:|---:|
| Goma (file watch) | 32 | 371,681 | 0 |
| Goma (file watch, debounce 0s) | 32 | 348,084 | 0 |
| Goma (reload API) | 32 | 368,047 | 0 |
| Traefik | 32 | 364,035 | 0 |
| Traefik (throttle 0s) | 32 | 374,900 | 0 |
| nginx | 32 | 1,383,095 | 1,384 |
| HAProxy | 32 | 1,230,996 | 188 |


## Idle footprint


### Resident memory when idle (MB)

RSS is summed across the process tree, so a multi-process gateway (nginx, HAProxy) has its shared pages counted once per process and is overstated relative to the single-process Go gateways. Process counts are in the table below.

|  | 1 route(s) | 100 route(s) | 1000 route(s) |
|---|---:|---:|---:|
| Goma (file watch) | 22.8 | 28.3 | 63.8 |
| Goma (file watch, debounce 0s) | 22.6 | 25.9 | 62.2 |
| Goma (reload API) | 20.5 | 24.7 | 48.5 |
| Traefik | 94.1 | 98.0 | 106.8 |
| Traefik (throttle 0s) | 92.0 | 97.9 | 108.2 |
| nginx | 23.2 | 29.1 | 89.1 |
| HAProxy | 46.6 | 48.3 | 62.9 |


### Processes

|  | 1 route(s) | 100 route(s) | 1000 route(s) |
|---|---:|---:|---:|
| Goma (file watch) | 1 | 1 | 1 |
| Goma (file watch, debounce 0s) | 1 | 1 | 1 |
| Goma (reload API) | 1 | 1 | 1 |
| Traefik | 1 | 1 | 1 |
| Traefik (throttle 0s) | 1 | 1 | 1 |
| nginx | 3 | 3 | 3 |
| HAProxy | 2 | 2 | 2 |


### Time from exec to serving the last route in the table (ms)

The harness polls every 10 ms, so values in the low tens of milliseconds are at the measurement floor.

|  | 1 route(s) | 100 route(s) | 1000 route(s) |
|---|---:|---:|---:|
| Goma (file watch) | 70 | 83 | 107 |
| Goma (file watch, debounce 0s) | 36 | 63 | 86 |
| Goma (reload API) | 57 | 120 | 120 |
| Traefik | 101 | 66 | 219 |
| Traefik (throttle 0s) | 52 | 81 | 175 |
| nginx | 24 | 24 | 36 |
| HAProxy | 41 | 42 | 82 |


### Time to release the port after SIGTERM (ms)

|  | 1 route(s) | 100 route(s) | 1000 route(s) |
|---|---:|---:|---:|
| Goma (file watch) | 2 | 3 | 16 |
| Goma (file watch, debounce 0s) | 3 | 16 | 16 |
| Goma (reload API) | 3 | 3 | 3 |
| Traefik | 4 | 4 | 3 |
| Traefik (throttle 0s) | 3 | 3 | 2 |
| nginx | 39 | 39 | 40 |
| HAProxy | 4 | 3 | 4 |


## Graceful shutdown

SIGTERM the moment the listener opens, SIGTERM when idle, and SIGTERM while a client keep-alive connection is open. "did not exit" means the process was still holding the port when the grace period ran out.

|  | Signalled at startup | Idle | Client connection open |
|---|---:|---:|---:|
| Goma (file watch) | 2 ms | 2 ms | 3 ms |
| Goma (file watch, debounce 0s) | 15 ms | 3 ms | 14 ms |
| Goma (reload API) | 2 ms | 3 ms | 2 ms |
| Traefik | 3 ms | 3 ms | 2 ms |
| Traefik (throttle 0s) | 2 ms | 2 ms | 2 ms |
| nginx | 26 ms | 27 ms | 41 ms |
| HAProxy | 2 ms | 2 ms | 3 ms |


---

Generated by `scripts/summarize.py` from the CSVs in this directory.

