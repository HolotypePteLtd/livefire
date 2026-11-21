# Rooms node image: one process serving the control plane (/v1/*) and the
# data plane (/play/<roomKey>) on one port, behind a reverse proxy for TLS.
#
# Build:
#   docker build -t rooms-node .
#
# Multi-stage: dart:stable builds the AOT bundle (including the native
# ReactPhysics3D library via the package's build hook), debian:slim runs it
# as an unprivileged user.

FROM dart:stable AS build

# The reactphysics3d_dart build hook compiles its C bridge via
# native_toolchain_c, which on linux x64 resolves the compiler as clang
# by name (gcc, g++ and CC are not consulted) — so clang is REQUIRED:
# installing gcc without clang fails the build.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates clang cmake g++ gcc git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY packages ./packages

WORKDIR /app/packages/node
RUN dart pub get
# AOT bundle: bin/node + lib/libreactphysics3d_dart.so, linked by the
# package's own build hooks (keep the bundle layout intact in the runtime).
RUN dart build cli -o /tmp/out

# --- Runtime ---------------------------------------------------------------

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl libsqlite3-0 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /nonexistent rooms \
    && mkdir -p /var/lib/rooms /etc/rooms \
    && chown -R rooms:rooms /var/lib/rooms

COPY --from=build /tmp/out/bundle/ /app/
RUN chmod +x /app/bin/node

USER rooms
WORKDIR /app
EXPOSE 8787
VOLUME /var/lib/rooms

# Unauthenticated control-plane pings answer 401; that proves the listener
# (and the store) is alive without a valid key.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer healthcheck" \
        http://127.0.0.1:8787/v1/rooms | grep -q 401

ENTRYPOINT ["/app/bin/node"]
CMD ["--config", "/etc/rooms/node.json"]
