# Goma Gateway benchmark — run `run-2`

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
| Goma (file watch) | 508 | 512 | 516 | 0 | 0 |
| Goma (file watch, debounce 0s) | 7 | 11 | 14 | 0 | 0 |
| Goma (reload API) | 11 | 18 | 22 | 0 | 0 |
| Traefik | 1,897 | 1,994 | 1,998 | 0 | 0 |
| Traefik (throttle 0s) | 47 | 121 | 123 | 0 | 0 |
| nginx | 108 | 112 | 112 | 0 | 0 |
| HAProxy | 31 | 44 | 46 | 0 | 0 |


## Route changes


### Rapid changes

|  | Requests | Errors | Error % | Codes | Origins hit | Changes seen by clients (of 11) |
|---|---:|---:|---:|---:|---:|---:|
| Goma (file watch) | 78,394 | 0 | 0.00 | 200:78394 | c9101:40636 c9102:37758 | 1 |
| Goma (file watch, debounce 0s) | 82,453 | 0 | 0.00 | 200:82453 | c9101:20401 c9102:62052 | 11 |
| Goma (reload API) | 79,156 | 0 | 0.00 | 200:79156 | c9101:18561 c9102:60595 | 11 |
| Traefik | 78,966 | 0 | 0.00 | 200:78966 | c9101:49633 c9102:29333 | 1 |
| Traefik (throttle 0s) | 78,730 | 0 | 0.00 | 200:78730 | c9101:21144 c9102:57586 | 11 |
| nginx | 122,571 | 0 | 0.00 | 200:122571 | c9101:32219 c9102:90352 | 11 |
| HAProxy | 109,391 | 0 | 0.00 | 200:109391 | c9101:28156 c9102:81235 | 11 |


### Spaced-out changes

|  | Requests | Errors | Error % | Codes | Origins hit | Changes seen by clients (of 11) |
|---|---:|---:|---:|---:|---:|---:|
| Goma (file watch) | 263,703 | 0 | 0.00 | 200:263703 | c9101:109793 c9102:153910 | 11 |
| Goma (file watch, debounce 0s) | 265,045 | 0 | 0.00 | 200:265045 | c9101:104777 c9102:160268 | 11 |
| Goma (reload API) | 264,567 | 0 | 0.00 | 200:264567 | c9101:103178 c9102:161389 | 11 |
| Traefik | 257,856 | 0 | 0.00 | 200:257856 | c9101:78066 c9102:179790 | 5 |
| Traefik (throttle 0s) | 266,418 | 0 | 0.00 | 200:266418 | c9101:104966 c9102:161452 | 11 |
| nginx | 383,460 | 0 | 0.00 | 200:383460 | c9101:151217 c9102:232243 | 11 |
| HAProxy | 365,666 | 0 | 0.00 | 200:365666 | c9101:147829 c9102:217837 | 11 |


## Backend failover

|  | Requests | Failed | Failed % | Longest unbroken failure streak (s) | Seconds with failures | Codes |
|---|---:|---:|---:|---:|---:|---:|
| Goma (file watch) | 19,200 | 10 | 0.05 | 1 | 9 | 200:19190 502:10 |
| Goma (file watch, debounce 0s) | 19,200 | 10 | 0.05 | 1 | 9 | 200:19190 502:10 |
| Goma (reload API) | 19,200 | 10 | 0.05 | 1 | 9 | 200:19190 502:10 |
| Traefik | 19,200 | 3,303 | 17.20 | 23 | 68 | 200:15897 502:3303 |
| Traefik (throttle 0s) | 19,200 | 3,299 | 17.18 | 23 | 68 | 200:15901 502:3299 |
| nginx | 19,200 | 0 | 0.00 | 0 | 0 | 200:19200 |
| HAProxy | 16,996 | 94 | 0.55 | 2 | 6 | conn_error:94 200:16902 |


## Route scale (1000 routes)


### Creating the table

|  | Seconds | Mean CPU (cores) | Peak CPU (cores) | Mean RSS (MB) | Peak RSS (MB) |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 1.6 | 0.087 | 0.12 | 23.1 | 23.5 |
| Goma (file watch, debounce 0s) | 1.1 | 1.660 | 1.70 | 53.1 | 64.5 |
| Goma (reload API) | 1.8 | 0.413 | 0.60 | 41.8 | 52.9 |
| Traefik | 2.1 | 1.320 | 1.34 | 105.8 | 107.2 |
| Traefik (throttle 0s) | 1.4 | 1.880 | 1.90 | 116.0 | 117.9 |
| nginx | 1.7 | 0.087 | 0.16 | 56.9 | 70.8 |
| HAProxy | 1.4 | 0.160 | 0.16 | 68.3 | 84.2 |


### Churning the table

|  | Seconds | Mean CPU (cores) | Peak CPU (cores) | Mean RSS (MB) | Peak RSS (MB) |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 119.4 | 0.790 | 0.88 | 70.0 | 112.2 |
| Goma (file watch, debounce 0s) | 119.0 | 0.887 | 1.18 | 97.2 | 156.4 |
| Goma (reload API) | 119.7 | 0.780 | 0.86 | 72.6 | 126.8 |
| Traefik | 119.9 | 1.623 | 1.70 | 126.0 | 130.3 |
| Traefik (throttle 0s) | 119.3 | 1.640 | 1.80 | 127.9 | 133.0 |
| nginx | 119.5 | 0.178 | 0.32 | 167.3 | 247.6 |
| HAProxy | 120.0 | 0.289 | 0.50 | 63.1 | 101.7 |


### Steady state after churn

|  | Seconds | Mean CPU (cores) | Peak CPU (cores) | Mean RSS (MB) | Peak RSS (MB) |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 30.0 | 0.002 | 0.10 | 59.0 | 70.1 |
| Goma (file watch, debounce 0s) | 30.0 | 0.005 | 0.22 | 66.1 | 66.1 |
| Goma (reload API) | 30.0 | 0.007 | 0.38 | 52.7 | 52.7 |
| Traefik | 30.0 | 1.377 | 1.42 | 122.2 | 125.8 |
| Traefik (throttle 0s) | 30.0 | 1.413 | 1.60 | 125.5 | 127.9 |
| nginx | 30.0 | 0.002 | 0.12 | 151.1 | 151.1 |
| HAProxy | 30.0 | 0.026 | 0.32 | 60.2 | 60.6 |


### After deleting every route

|  | Seconds | Mean CPU (cores) | Peak CPU (cores) | Mean RSS (MB) | Peak RSS (MB) |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 15.0 | 0.002 | 0.04 | 75.3 | 76.0 |
| Goma (file watch, debounce 0s) | 15.0 | 0.006 | 0.14 | 97.7 | 97.7 |
| Goma (reload API) | 15.0 | 0.001 | 0.02 | 52.7 | 52.7 |
| Traefik | 15.0 | 0.199 | 1.34 | 111.7 | 118.2 |
| Traefik (throttle 0s) | 15.0 | 0.222 | 1.44 | 108.9 | 109.3 |
| nginx | 15.0 | 0.001 | 0.02 | 150.1 | 150.1 |
| HAProxy | 15.1 | 0.001 | 0.04 | 50.0 | 50.0 |


### Churn batches completed in the fixed window

The churn loop runs for a fixed time, so a gateway whose commit is expensive gets through fewer batches — and therefore applies fewer changes — than one whose commit returns immediately.

|  | Routes | Churn seconds | Batches applied |
|---|---:|---:|---:|
| Goma (file watch) | 1000 | 120 | 224 |
| Goma (file watch, debounce 0s) | 1000 | 120 | 223 |
| Goma (reload API) | 1000 | 120 | 200 |
| Traefik | 1000 | 120 | 224 |
| Traefik (throttle 0s) | 1000 | 120 | 223 |
| nginx | 1000 | 120 | 215 |
| HAProxy | 1000 | 120 | 202 |


### An untouched route, probed throughout the churn

|  | Requests | Errors | Error % | Codes |
|---|---:|---:|---:|---:|
| Goma (file watch) | 382,680 | 0 | 0.00 | 200:382680 |
| Goma (file watch, debounce 0s) | 360,777 | 0 | 0.00 | 200:360777 |
| Goma (reload API) | 387,078 | 0 | 0.00 | 200:387078 |
| Traefik | 313,768 | 0 | 0.00 | 200:313768 |
| Traefik (throttle 0s) | 291,159 | 0 | 0.00 | 200:291159 |
| nginx | 558,777 | 0 | 0.00 | 200:558777 |
| HAProxy | 462,074 | 0 | 0.00 | 200:462074 |


## Traffic performance


### Throughput (req/s)

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 3,990 | 20,080 | 33,937 | 36,949 | 33,619 |
| Goma (file watch, debounce 0s) | 3,991 | 20,072 | 35,603 | 38,107 | 34,806 |
| Goma (reload API) | 4,039 | 19,970 | 34,337 | 36,675 | 31,379 |
| Traefik | 3,888 | 18,897 | 35,595 | 41,761 | 34,296 |
| Traefik (throttle 0s) | 3,926 | 19,002 | 36,132 | 38,468 | 32,108 |
| nginx | 5,921 | 44,437 | 137,543 | 121,326 | 59,950 |
| HAProxy | 5,639 | 41,540 | 124,929 | 137,302 | 153,387 |


### p50 latency (ms)

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 0.59 | 0.54 | 0.77 | 2.94 | 6.69 |
| Goma (file watch, debounce 0s) | 0.59 | 0.53 | 0.75 | 2.88 | 6.52 |
| Goma (reload API) | 0.59 | 0.53 | 0.77 | 2.96 | 7.26 |
| Traefik | 0.59 | 0.54 | 0.71 | 2.59 | 6.35 |
| Traefik (throttle 0s) | 0.58 | 0.54 | 0.71 | 2.79 | 6.64 |
| nginx | 0.55 | 0.51 | 0.51 | 0.75 | 1.87 |
| HAProxy | 0.56 | 0.51 | 0.52 | 0.75 | 1.60 |


### p99 latency (ms)

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 0.99 | 1.95 | 3.50 | 11.43 | 22.13 |
| Goma (file watch, debounce 0s) | 0.99 | 1.93 | 3.22 | 10.93 | 20.40 |
| Goma (reload API) | 0.99 | 1.94 | 3.43 | 11.51 | 22.94 |
| Traefik | 0.99 | 2.39 | 3.95 | 10.76 | 22.44 |
| Traefik (throttle 0s) | 0.99 | 2.39 | 3.87 | 11.50 | 24.50 |
| nginx | 0.99 | 0.99 | 1.00 | 7.36 | 46.69 |
| HAProxy | 0.99 | 0.99 | 1.00 | 2.97 | 4.71 |


### Gateway CPU during each point (cores)

Gateway CPU is sampled during each point and requests per second are divided by it. Absolute throughput depends on the host and on whether the gateway was pinned away from the load generator; this ratio travels better between machines.

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 0.77 | 1.29 | 1.68 | 1.74 | 1.73 |
| Goma (file watch, debounce 0s) | 0.76 | 1.29 | 1.69 | 1.74 | 1.72 |
| Goma (reload API) | 0.76 | 1.28 | 1.68 | 1.74 | 1.72 |
| Traefik | 0.78 | 1.29 | 1.68 | 1.76 | 1.70 |
| Traefik (throttle 0s) | 0.77 | 1.27 | 1.70 | 1.75 | 1.71 |
| nginx | 0.30 | 0.95 | 1.25 | 1.40 | 1.68 |
| HAProxy | 0.37 | 1.17 | 1.44 | 1.51 | 1.57 |


### Load-side CPU busy during each point (%)

Share of the load CPUs (fortio and the origin) in use. Near 100% means that point was capped by the load generator rather than the gateway.

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 11 | 36 | 50 | 53 | 51 |
| Goma (file watch, debounce 0s) | 11 | 36 | 51 | 53 | 52 |
| Goma (reload API) | 11 | 36 | 50 | 53 | 50 |
| Traefik | 11 | 35 | 52 | 57 | 53 |
| Traefik (throttle 0s) | 11 | 35 | 52 | 56 | 52 |
| nginx | 16 | 68 | 80 | 71 | 42 |
| HAProxy | 16 | 64 | 78 | 76 | 76 |


### Throughput per core of gateway CPU (req/s per core)

|  | 1 conn | 8 conn | 32 conn | 128 conn | 256 conn |
|---|---:|---:|---:|---:|---:|
| Goma (file watch) | 5,215 | 15,606 | 20,182 | 21,273 | 19,413 |
| Goma (file watch, debounce 0s) | 5,223 | 15,606 | 21,102 | 21,901 | 20,212 |
| Goma (reload API) | 5,293 | 15,546 | 20,457 | 21,109 | 18,195 |
| Traefik | 5,014 | 14,628 | 21,239 | 23,707 | 20,126 |
| Traefik (throttle 0s) | 5,090 | 14,983 | 21,312 | 21,946 | 18,830 |
| nginx | 19,603 | 46,966 | 110,419 | 86,503 | 35,750 |
| HAProxy | 15,272 | 35,574 | 86,942 | 91,006 | 97,971 |


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
| Goma (file watch) | 32 | 362,547 | 0 |
| Goma (file watch, debounce 0s) | 32 | 333,068 | 0 |
| Goma (reload API) | 32 | 335,719 | 0 |
| Traefik | 32 | 370,854 | 0 |
| Traefik (throttle 0s) | 32 | 366,015 | 0 |
| nginx | 32 | 1,377,653 | 1,379 |
| HAProxy | 32 | 1,257,279 | 243 |


## Idle footprint


### Resident memory when idle (MB)

RSS is summed across the process tree, so a multi-process gateway (nginx, HAProxy) has its shared pages counted once per process and is overstated relative to the single-process Go gateways. Process counts are in the table below.

|  | 1 route(s) | 100 route(s) | 1000 route(s) |
|---|---:|---:|---:|
| Goma (file watch) | 22.8 | 25.9 | 56.6 |
| Goma (file watch, debounce 0s) | 22.9 | 28.0 | 55.6 |
| Goma (reload API) | 22.4 | 25.1 | 52.8 |
| Traefik | 93.0 | 98.0 | 110.8 |
| Traefik (throttle 0s) | 93.6 | 97.7 | 106.7 |
| nginx | 22.9 | 29.8 | 88.8 |
| HAProxy | 50.4 | 51.3 | 63.1 |


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
| Goma (file watch) | 83 | 61 | 110 |
| Goma (file watch, debounce 0s) | 69 | 55 | 122 |
| Goma (reload API) | 71 | 71 | 96 |
| Traefik | 84 | 99 | 381 |
| Traefik (throttle 0s) | 52 | 54 | 235 |
| nginx | 25 | 28 | 50 |
| HAProxy | 45 | 48 | 88 |


### Time to release the port after SIGTERM (ms)

|  | 1 route(s) | 100 route(s) | 1000 route(s) |
|---|---:|---:|---:|
| Goma (file watch) | 16 | 17 | 16 |
| Goma (file watch, debounce 0s) | 3 | 3 | 16 |
| Goma (reload API) | 3 | 3 | 3 |
| Traefik | 2 | 2 | 3 |
| Traefik (throttle 0s) | 3 | 3 | 3 |
| nginx | 29 | 44 | 52 |
| HAProxy | 4 | 3 | 4 |


## Graceful shutdown

SIGTERM the moment the listener opens, SIGTERM when idle, and SIGTERM while a client keep-alive connection is open. "did not exit" means the process was still holding the port when the grace period ran out.

|  | Signalled at startup | Idle | Client connection open |
|---|---:|---:|---:|
| Goma (file watch) | 14 ms | 17 ms | 14 ms |
| Goma (file watch, debounce 0s) | 14 ms | 14 ms | 15 ms |
| Goma (reload API) | 2 ms | 3 ms | 3 ms |
| Traefik | 2 ms | 3 ms | 2 ms |
| Traefik (throttle 0s) | 2 ms | 3 ms | 3 ms |
| nginx | 39 ms | 40 ms | 29 ms |
| HAProxy | 2 ms | 2 ms | 3 ms |


---

Generated by `scripts/summarize.py` from the CSVs in this directory.

