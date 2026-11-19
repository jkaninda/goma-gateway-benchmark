# The benchmark runner: every gateway, the load generator and the harness in one
# Linux image, each at a pinned version.
#
#   ./scripts/docker-run.sh          builds this and runs bench.sh inside it
#
# Binaries are copied out of each project's official image rather than taken
# from a distribution, so the versions are the upstream releases and the same
# on amd64 and arm64. Change a version here and nowhere else.
ARG GOMA_VERSION=1.2.1
ARG TRAEFIK_VERSION=v3.7.19
ARG HAPROXY_VERSION=3.4.8
ARG NGINX_VERSION=1.30.7
ARG FORTIO_VERSION=1.77.0
ARG GO_VERSION=1.27

FROM golang:${GO_VERSION} AS benchtool
WORKDIR /src
COPY tools/benchtool/ ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/benchtool .

FROM jkaninda/goma-gateway:${GOMA_VERSION} AS goma
FROM traefik:${TRAEFIK_VERSION} AS traefik
FROM haproxy:${HAPROXY_VERSION} AS haproxy
FROM fortio/fortio:${FORTIO_VERSION} AS fortio

# nginx's official image is Debian trixie, as is HAProxy's, so HAProxy's binary
# runs here once its shared libraries are installed. Goma, Traefik and fortio
# are static Go binaries.
FROM nginx:${NGINX_VERSION}
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl iproute2 iptables procps python3 util-linux \
      libcrypt1 liblua5.4-0 libpcre2-8-0 libssl3t64 zlib1g libzstd1 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=haproxy   /usr/local/sbin/haproxy /usr/local/sbin/haproxy
COPY --from=goma      /usr/local/bin/goma     /opt/bench/bin/goma
COPY --from=traefik   /usr/local/bin/traefik  /opt/bench/bin/traefik
COPY --from=fortio    /usr/bin/fortio         /opt/bench/bin/fortio
COPY --from=benchtool /out/benchtool          /opt/bench/bin/benchtool
ENV BIN_DIR=/opt/bench/bin \
    BENCH_RUNTIME=docker
WORKDIR /bench
ENTRYPOINT ["bash", "/bench/bench.sh"]
