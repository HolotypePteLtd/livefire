---
title: Self-hosting
description: The rooms server reference — config fields, TLS proxy, deployment checklist, running without Docker.
---

> You only need this section if you want the details. The walkthrough is
> [Instant multiplayer server → Put the server on the
> internet](/docs/multiplayer-server/#4-put-the-server-on-the-internet).

One process, one port; TLS terminates at a reverse proxy. The shipped
`docker-compose.yml` runs the rooms server behind **Caddy** (automatic
Let's Encrypt for your `DOMAIN`, WebSocket upgrades transparent) and serves
this static site from the same origin.

What comes up with `docker compose up -d`:

| Service | Role |
| --- | --- |
| `rooms-node` | the server binary (`packages/node`): `/v1/*` HTTP API + `/play/<roomKey>` WebSockets on one port, SQLite in the `rooms-data` volume |
| `site` | one-shot init container that builds this site and publishes `dist/` into the shared `rooms-site` volume |
| `caddy` | TLS (HTTP/2 + HTTP/3), proxies `/v1/*` and `/play/*` to the server, serves everything else (docs, `llms.txt`, `/spec/*`) from the site volume |

The image is a multi-stage build: the build stage compiles the
ReactPhysics3D native library and the AOT bundle (`dart build cli` — native
assets linked by build hooks); the runtime is `debian:bookworm-slim`,
unprivileged, with `libsqlite3`.

Bluesky sign-in needs one extra file mounted — see
[Player accounts](/docs/accounts/). The same block powers the
[developer panel](/docs/panel/): add your DID to `adminDids` and
`https://<DOMAIN>/panel` becomes your key dashboard.

## Server config reference (`node.json`)

| Field | Type | Default / rule | Meaning |
| --- | --- | --- | --- |
| `publicBaseUrl` | string | — | Origin used to build room URLs (`wss://…/play/<key>`); must match the public domain behind Caddy |
| `nodeSecret` | string | 16+ chars | HMAC key for join/creator tokens; generate 32+ random characters |
| `apiKeys` | object | — | Service keys (name → secret) — **bootstrap ADMIN keys** (`Authorization: Bearer <key>`), hashed at boot; in Postgres mode they never become database rows |
| `dataDir` | string | `/var/lib/rooms` | SQLite directory (persist it — join-token consumption and room pins survive restarts) |
| `listen.port` | int | 8787, 1024–65535 | Server listen port (plain HTTP; TLS is the proxy's job) |
| `listen.address` | string | `0.0.0.0` | Bind address |
| `allowedOrigins` | string[] | — | Origin allowlist enforced before the WebSocket upgrade |
| `adminDids` | string[] | `[]` | DIDs allowed into the [developer panel](/docs/panel/) at `/panel` (sign in with Bluesky). Empty disables the panel; config `apiKeys` are bootstrap ADMIN keys, read-only there. In Postgres mode this list only **seeds** the admin table once — afterwards admins are managed in the panel |
| `limits.maxRooms` | int | 256 | Concurrent rooms; beyond → `quota_exceeded` |
| `limits.maxReservedCapacity` | int | 4096 | Sum of room capacities; beyond → `quota_exceeded` |
| `limits.idleTtlSeconds` | int | 300 | Idle rooms stop ticking but keep room + state in memory |
| `limits.connectionsPerIpPerMinute` | int | 60 | Pre-upgrade per-IP throttle |
| `joinTokenTtlSeconds` | int | 900 (60–86400) | Issued join-token lifetime |
| `physics` | bool | `true` | Wire the reactphysics3d physics backend (`false` → physics rooms return `unsupported_template`) |
| `auth` | object | `["guest"]` | Sign-in providers — see [Player accounts](/docs/accounts/) and the [Identity reference](/docs/identity/) |

Config is fail-fast: unknown or out-of-range fields abort startup.

## TLS via Caddy

`deploy/Caddyfile`:

```txt
{$DOMAIN} {
	encode zstd gzip
	handle /v1/* {
		reverse_proxy rooms-node:8787
	}
	handle /play/* {
		reverse_proxy rooms-node:8787
	}
	handle {
		root * /srv/site
		try_files {path} {path}/
		file_server
	}
}
```

- Set `DOMAIN` (and optionally `ACME_EMAIL`) in the compose environment;
  certificates are issued and renewed automatically.
- HTTP/3 is enabled (`443/udp` is published).
- The server's routes are explicit; everything else is the static site, so
  `https://your-domain/` is the docs, `https://your-domain/v1/…` the API,
  `https://your-domain/llms.txt` the agent index.

## Deployment checklist (e.g. Hetzner)

1. A server with Docker and ports 80/443 (TCP + UDP 443) open.
2. DNS A/AAAA record for your domain → server IP (must resolve before
   Let's Encrypt will issue).
3. `.env` with `DOMAIN`, `ACME_EMAIL` (the physics dependency is public —
   no build token needed).
4. `node.json` from `deploy/node.example.json` — new `nodeSecret`, real
   `apiKeys`, your game origins in `allowedOrigins`, `publicBaseUrl` =
   `https://<DOMAIN>`.
5. `docker compose up -d --build`; check `docker compose ps` and
   `docker compose logs caddy`.
6. Smoke test: `curl -s https://<DOMAIN>/v1/rooms` → `401` (Caddy + server +
   auth all working); `https://<DOMAIN>/llms.txt` → this site.
7. Backups: the `rooms-data` volume (SQLite). Room **state** is memory-only
   by design; rooms are lazily recreated from their pinned config on the
   next join after a restart.

## Deploy with Coolify and Traefik

The [Coolify example](https://github.com/HolotypePteLtd/openfire/tree/master/deploy/coolify)
runs the rooms node behind Traefik. Route the node's domain to port
`8787`, terminate TLS at the proxy, and set `publicBaseUrl` to the
external HTTPS origin. You can deploy the docs separately as a static
site.

## Platform data in Supabase

The node has two persistence modes, chosen automatically from its
environment:

- **SQLite (default).** Everything the panel needs — admins, API keys,
  counters — lives in the node's own SQLite file. Zero setup; this is
  the self-hoster path and the behavior never changed.
- **Supabase Postgres.** Set both environment variables on the node
  service:

  ```
  SUPABASE_URL=https://<kong-domain-of-your-supabase-stack>
  SUPABASE_SECRET_KEY=<service-key>
  ```

  and the platform half moves to Postgres (reached through Kong with
  the stack's service key). This unlocks the panel's admin management, scoped API keys
  (`maxRooms`, `templates`) and the audit log; `adminDids` seeds the
  admin table on first boot, then the database is the source of truth.
  The room **runtime** — rooms, peers, join tokens — stays in SQLite
  either way: the data plane never waits on Postgres.

Requirements for the Postgres mode (see `supabase/README.md` in the
repository for the migration and exact steps): a self-hosted Supabase
stack, its service key, and the panel tables applied once with
`supabase/scripts/apply-migrations.sh`. Bearer-key lookup uses an
in-memory cache. Creating rooms with panel-issued keys requires an
authoritative quota check in Postgres. Unset the two variables and
restart to return to SQLite mode.

## Running without Docker

```sh
cd packages/node
cp ../../deploy/node.example.json /tmp/node.json   # then edit secrets
dart run bin/node.dart --config /tmp/node.json     # physics rooms included
```

The server handles SIGINT/SIGTERM by draining (rooms closed, peers get 1001).
See the [HTTP API reference](/docs/api/) for the endpoint contract and its
implementation notes.

## Docs elsewhere, server here (split origins)

This compose file serves the docs from the same origin as the server
(`https://<DOMAIN>/`), which is the single-origin convenience path. The
site is plain static output, so it can equally be deployed to Cloudflare
Pages (docs there, server here — see `site/README.md` for the wrangler and
git-integrated paths). That is two origins and nothing breaks:

- the site's internal links are same-origin paths (`/docs/…`,
  `/llms.txt`, `/spec/…`) — they resolve under whichever domain serves
  them;
- the API's base URL is not hardcoded anywhere in the site: the
  API reference documents `https://<your-server-domain>/v1/…`, and each
  server deployment advertises its own origin via `publicBaseUrl` in
  `node.json` (it builds the room URLs clients connect to).

---
*Generated from `docker-compose.yml`, `deploy/Caddyfile` and
`deploy/node.example.json` in the repository.*
