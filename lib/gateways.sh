#!/usr/bin/env bash
# Per-gateway adapters.
#
# Every scenario talks to a gateway through this one interface:
#
#   gw_prepare <name>                       fresh config tree, no routes
#   gw_start   <name>                       start it, set GW_PID, wait until ready
#   gw_stop    <name>                       stop it and everything it spawned
#   gw_route   <name> <id> <target-url>     declare route /r-<id>/ -> target
#   gw_route_pool <name> <id> <t1> <t2> ...  declare a load-balanced route
#   gw_commit  <name>                       make pending route files take effect
#   gw_drop_routes <name> [glob]            remove route definitions
#
# gw_route writes a file; gw_commit is where the difference between the two
# families shows. Goma and Traefik watch their config directory and reload
# themselves, so gw_commit is a no-op for them. nginx and haproxy have to be
# told, so gw_commit signals them — the job a Kubernetes controller would do.
# The propagation clock starts when gw_route returns, and gw_commit runs
# immediately after, so neither family is charged for the other's design.
set -euo pipefail

GW_PID=""

gw_dir() { echo "$RUN_DIR/$1"; }

# --------------------------------------------------------------- prepare ----

gw_prepare() {
  local gw="$1" d; d="$(gw_dir "$gw")"
  rm -rf "$d"; mkdir -p "$d/logs" "$d/tmp"
  case "$gw" in
    goma|goma-reload|goma-fast)
      mkdir -p "$d/dynamic"
      sed -e "s|__PORT__|$GW_PORT|g" -e "s|__DYNAMIC__|$d/dynamic|g" \
        "$BENCH_ROOT/gateways/goma/$gw.yml.tmpl" >"$d/goma.yml"
      ;;
    traefik|traefik-fast)
      mkdir -p "$d/dynamic"
      sed -e "s|__PORT__|$GW_PORT|g" -e "s|__DYNAMIC__|$d/dynamic|g" \
        "$BENCH_ROOT/gateways/traefik/$gw.yml.tmpl" >"$d/traefik.yml"
      ;;
    nginx)
      mkdir -p "$d/dynamic/routes" "$d/dynamic/upstreams" "$d/tmp"
      # nginx and HAProxy need to be told how many workers to run; Go gateways
      # size themselves from their CPU affinity. Deriving both from the CPUs the
      # gateway is pinned to keeps every gateway on the same budget.
      sed -e "s|__PORT__|$GW_PORT|g" -e "s|__DYNAMIC__|$d/dynamic|g" -e "s|__RUNDIR__|$d|g" \
          -e "s|__WORKERS__|$(gw_cpu_count)|g" \
        "$BENCH_ROOT/gateways/nginx/nginx.conf.tmpl" >"$d/nginx.conf"
      ;;
    haproxy)
      mkdir -p "$d/routes" "$d/backends"
      sed -e "s|__PORT__|$GW_PORT|g" -e "s|__RUNDIR__|$d|g" -e "s|__WORKERS__|$(gw_cpu_count)|g" \
        "$BENCH_ROOT/gateways/haproxy/haproxy.cfg.head.tmpl" >"$d/haproxy.cfg.head"
      haproxy_render "$gw"
      ;;
    *) die "unknown gateway: $gw" ;;
  esac
}

# ----------------------------------------------------------------- start ----

# Launch the gateway process and set GW_PID, without waiting for anything.
# Used by gw_start and by the shutdown scenario, which has to signal the
# process at the first moment it is externally visible.
#
# Every gateway is started under setsid, in a session of its own. HAProxy's
# master relays signals to its process group, so a SIGUSR2 sent to a master that
# shares the harness's group takes the harness down with it. Its own session
# also makes the whole tree killable with one group signal. GW_PIN pins it to
# GW_CPUS when that is set.
gw_exec() {
  local gw="$1" d; d="$(gw_dir "$gw")"
  ensure_port_free "$GW_PORT"
  case "$gw" in
    goma|goma-reload|goma-fast)
      "${GW_PIN[@]}" setsid "$BIN_DIR/goma" server -c "$d/goma.yml" >"$d/logs/gw.log" 2>&1 &
      ;;
    traefik|traefik-fast)
      "${GW_PIN[@]}" setsid "$BIN_DIR/traefik" --configfile="$d/traefik.yml" >"$d/logs/gw.log" 2>&1 &
      ;;
    nginx)
      "${GW_PIN[@]}" setsid nginx -c "$d/nginx.conf" -e "$d/logs/nginx-error.log" >"$d/logs/gw.log" 2>&1 &
      ;;
    haproxy)
      # Routes written before start still have to be assembled into the single
      # config file the process reads at boot. -W master-worker keeps one stable
      # parent pid across reloads; -db keeps it foregrounded so the harness owns
      # it and the sampler can follow it.
      haproxy_render "$gw"
      "${GW_PIN[@]}" setsid haproxy -W -db -f "$d/haproxy.cfg" >"$d/logs/gw.log" 2>&1 &
      ;;
    *) die "unknown gateway: $gw" ;;
  esac
  # taskset and setsid both exec in place, so $! is the gateway itself.
  GW_PID=$!
}

gw_start() {
  local gw="$1" d; d="$(gw_dir "$gw")"
  gw_exec "$gw"
  wait_port "$GW_PORT" 20 || { tail -20 "$d/logs/gw.log" >&2; die "$gw did not listen on $GW_PORT"; }
  # Wait on the gateway's own health endpoint rather than a fixed sleep. A fixed
  # settle would be added to every startup measurement and to nothing else,
  # which is exactly the kind of constant that makes gateways look identical
  # when they are not.
  wait_url_200 "$(gw_health_url "$gw")" 20 \
    || { tail -20 "$d/logs/gw.log" >&2; die "$gw never answered its health endpoint"; }
}

gw_stop() {
  local gw="$1"
  GW_STOP_ESCALATED=0
  if [[ -n "${GW_PID:-}" && "${GW_PID:-0}" -gt 0 ]]; then
    kill -TERM "-$GW_PID" 2>/dev/null || kill -TERM "$GW_PID" 2>/dev/null || true
  fi
  # The group signal above already covers nginx's and haproxy's workers, which
  # live in the same session. Deliberately no pkill by name here: a pattern like
  # `pkill -f "nginx: "` also matches any shell whose command line mentions it.
  local pid="${GW_PID:-}"
  GW_PID=""
  local end=$((SECONDS + 8))
  while (( SECONDS < end )); do
    port_open "$GW_PORT" || return 0
    sleep 0.01
  done
  # Graceful shutdown did not finish in time (Goma drains in-flight requests on
  # SIGTERM, which can outlast a scenario's load). Escalate rather than fail:
  # a stuck port would poison every later scenario.
  GW_STOP_ESCALATED=1
  if [[ -n "$pid" && "$pid" -gt 0 ]]; then
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  end=$((SECONDS + 8))
  while (( SECONDS < end )); do
    port_open "$GW_PORT" || return 0
    sleep 0.1
  done
  die "$gw still holding port $GW_PORT"
}

gw_health_url() {
  case "$1" in
    goma|goma-reload|goma-fast) echo "$GW_URL/healthz" ;;
    traefik|traefik-fast) echo "$GW_URL/ping" ;;
    *)       echo "$GW_URL/_bench/health" ;;
  esac
}

# ---------------------------------------------------------------- routes ----

# gw_route <gw> <id> <target>   ->  /r-<id>/  proxied to <target>, prefix stripped
gw_route() { gw_route_pool "$1" "$2" "$3"; }

# gw_route_pool <gw> <id> <target...>
gw_route_pool() {
  local gw="$1" id="$2"; shift 2
  local targets=("$@") d; d="$(gw_dir "$gw")"
  case "$gw" in
    goma|goma-reload|goma-fast) goma_route "$d" "$id" "${targets[@]}" ;;
    traefik|traefik-fast) traefik_route "$d" "$id" "${targets[@]}" ;;
    nginx)    nginx_route    "$d" "$id" "${targets[@]}" ;;
    haproxy)  haproxy_route  "$d" "$id" "${targets[@]}" ;;
  esac
}

gw_commit() {
  local gw="$1" d; d="$(gw_dir "$gw")"
  case "$gw" in
    goma|goma-fast|traefik|traefik-fast)
      : # file watcher picks the change up on its own
      ;;
    goma-reload)
      # Same job as the SIGHUP below: tell the gateway to apply what is on disk
      # now. Goma's reload endpoint is synchronous, so when curl returns the
      # new configuration is live.
      curl -s -o /dev/null -X POST -H 'Authorization: Bearer benchmark' \
        --max-time 10 "$GW_URL/gateway/reload" || true
      ;;
    nginx)
      # SIGHUP: nginx validates the new config, starts new workers, drains old.
      gw_signal HUP
      ;;
    haproxy)
      haproxy_render "$gw"
      # SIGUSR2: the master re-execs, reads the file again and hands the
      # listening sockets to the new worker. A USR2 that arrives while a
      # previous re-exec is still in flight is dropped, so wait for this one to
      # land before returning — otherwise a fast scenario measures a lost
      # signal instead of a reload. The wait is part of haproxy's real cost and
      # the measurement clock is already running when we get here.
      local before after
      before=$(grep -c 'Loading success' "$d/logs/gw.log" 2>/dev/null; true)
      gw_signal USR2
      local end=$((SECONDS + 10))
      while (( SECONDS < end )); do
        after=$(grep -c 'Loading success' "$d/logs/gw.log" 2>/dev/null; true)
        (( after > before )) && break
        sleep 0.01
      done
      ;;
  esac
}

# Signal the gateway, never the process group. `kill -USR2 ""` and `kill -USR2 0`
# both target the caller's whole process group, which kills the harness itself.
gw_signal() {
  [[ -n "${GW_PID:-}" && "${GW_PID:-0}" -gt 0 ]] || return 0
  kill "-$1" "$GW_PID" 2>/dev/null || true
}

gw_drop_routes() {
  local gw="$1" pattern="${2:-*}" d; d="$(gw_dir "$gw")"
  case "$gw" in
    goma|goma-reload|goma-fast|traefik|traefik-fast) rm -f "$d"/dynamic/route-$pattern.yml ;;
    nginx)   rm -f "$d"/dynamic/routes/$pattern.conf "$d"/dynamic/upstreams/$pattern.conf ;;
    haproxy) rm -f "$d"/routes/$pattern.txt "$d"/backends/$pattern.txt ;;
  esac
}

gw_route_count() {
  local gw="$1" d; d="$(gw_dir "$gw")"
  case "$gw" in
    goma|goma-reload|goma-fast|traefik|traefik-fast) find "$d/dynamic" -maxdepth 1 -name 'route-*.yml' | wc -l ;;
    nginx)        find "$d/dynamic/routes" -name '*.conf' | wc -l ;;
    haproxy)      find "$d/routes" -name '*.txt' | wc -l ;;
  esac
}

# ------------------------------------------------------- per-gateway impl ---

goma_route() {
  local d="$1" id="$2"; shift 2
  local f="$d/dynamic/route-$id.yml" tmp="$d/dynamic/.route-$id.yml.tmp"
  {
    echo "routes:"
    echo "  - name: r-$id"
      echo "    path: /r-$id/"
      echo "    rewrite: /"
    if (( $# == 1 )); then
      echo "    target: $1"
    else
      echo "    backends:"
      for t in "$@"; do echo "      - endpoint: $t"; done
    fi
  } >"$tmp"
  # Atomic rename: a file watcher must never see a half-written route.
  mv -f "$tmp" "$f"
}

traefik_route() {
  local d="$1" id="$2"; shift 2
  local f="$d/dynamic/route-$id.yml" tmp="$d/dynamic/.route-$id.yml.tmp"
  {
    echo "http:"
    echo "  routers:"
    echo "    r-$id:"
    echo "      rule: \"PathPrefix(\`/r-$id/\`)\""
    echo "      entryPoints: [web]"
    echo "      service: s-$id"
    echo "      middlewares: [strip-$id]"
    echo "  middlewares:"
    echo "    strip-$id:"
    echo "      stripPrefix:"
    echo "        prefixes: [\"/r-$id\"]"
    echo "  services:"
    echo "    s-$id:"
    echo "      loadBalancer:"
    echo "        servers:"
    for t in "$@"; do echo "          - url: \"$t\""; done
  } >"$tmp"
  mv -f "$tmp" "$f"
}

nginx_route() {
  local d="$1" id="$2"; shift 2
  local up="$d/dynamic/upstreams/$id.conf" rt="$d/dynamic/routes/$id.conf"
  {
    echo "upstream u_$id {"
    for t in "$@"; do echo "    server ${t#http://};"; done
    echo "    keepalive 32;"
    echo "}"
  } >"$up.tmp" && mv -f "$up.tmp" "$up"
  {
    echo "location /r-$id/ {"
    echo "    proxy_pass http://u_$id/;"
    echo "}"
  } >"$rt.tmp" && mv -f "$rt.tmp" "$rt"
}

haproxy_route() {
  local d="$1" id="$2"; shift 2
  {
    echo "    use_backend be_$id if { path_beg /r-$id/ }"
  } >"$d/routes/$id.txt"
  {
    echo "backend be_$id"
    echo "    http-request set-path %[path,regsub(^/r-$id/,/)]"
    local n=1
    for t in "$@"; do
      echo "    server s$n ${t#http://} check inter 2s fall 2 rise 2"
      n=$((n+1))
    done
  } >"$d/backends/$id.txt"
}

# Rebuild the single haproxy.cfg from the header plus every route fragment.
haproxy_render() {
  local d; d="$(gw_dir "$1")"
  local tmp="$d/haproxy.cfg.tmp"
  cat "$d/haproxy.cfg.head" >"$tmp"
  if compgen -G "$d/routes/*.txt" >/dev/null; then cat "$d"/routes/*.txt >>"$tmp"; fi
  printf '\nbackend be_notfound\n    http-request return status 404 content-type "text/plain" string "not found\\n"\n\n' >>"$tmp"
  if compgen -G "$d/backends/*.txt" >/dev/null; then cat "$d"/backends/*.txt >>"$tmp"; fi
  mv -f "$tmp" "$d/haproxy.cfg"
}

gw_version() {
  case "$1" in
    goma|goma-reload|goma-fast) "$BIN_DIR/goma" version 2>&1 | awk -F': ' '/version/{print $2; exit}' ;;
    traefik|traefik-fast) "$BIN_DIR/traefik" version 2>&1 | awk -F': *' '/^Version/{print $2; exit}' ;;
    nginx)   nginx -v 2>&1 | sed 's|.*/||' ;;
    haproxy) haproxy -v 2>&1 | awk '/HAProxy version/{print $3; exit}' ;;
  esac
}
