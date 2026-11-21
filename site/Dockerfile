# Build the static docs site (landing + Starlight docs + agent endpoints).
#
# IMPORTANT: the build context must be the REPOSITORY ROOT, not site/ —
# docker-compose.yml sets `context: .` — because the docs pages markdown-
# import ../docs/*.md and the spec cross-check reads ../packages/... during
# `npm run build`. (The root .dockerignore excludes docs/, so this Dockerfile
# uses its own companion ignore file, site/Dockerfile.dockerignore.)

FROM dart:stable AS dart-sdk

FROM node:24-bookworm-slim AS build
COPY --from=dart-sdk /usr/lib/dart /usr/lib/dart
COPY --from=dart-sdk /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENV PATH="/usr/lib/dart/bin:${PATH}"
WORKDIR /src/site

# Dependencies first for layer caching (lockfile is committed).
COPY site/package.json site/package-lock.json ./
RUN npm ci

# Site sources, plus the repository documents and protocol sources the build
# consumes (markdown imports + the build-time spec cross-check).
COPY site/ ./
COPY docs/ /src/docs/
COPY packages/protocol/ /src/packages/protocol/
COPY packages/client/ /src/packages/client/
COPY packages/server_sdk/lib/src/relay_authority.dart /src/packages/server_sdk/lib/src/
COPY packages/server_sdk/lib/src/movement_authority.dart /src/packages/server_sdk/lib/src/

RUN npm run build

# One-shot publisher: copies the built dist/ into the shared volume so Caddy
# can serve it (compose marks this service service_completed_successfully).
FROM alpine:3.21
COPY --from=build /src/site/dist /site
CMD ["sh", "-c", "rm -rf /srv/site && mkdir -p /srv/site && cp -r /site/. /srv/site/"]
