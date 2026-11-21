---
title: Self-hosting
description: Deploy a Livefire node with Docker Compose, verify HTTPS and create a room.
---

## Deploy with Docker Compose

Livefire runs on a Linux host with Docker Compose. You’ll need Git,
OpenSSL, curl, and a domain pointing to the host. Open inbound TCP ports
80 and 443 for Caddy’s automatic HTTPS. UDP port 443 is optional for
HTTP/3. This setup uses guest players and SQLite.

### 1. Clone and configure

```sh
git clone https://github.com/HolotypePteLtd/livefire
cd livefire
```

Replace `rooms.example.com` with your domain, then run this once from
the checkout. Keep the API key on your game backend.

```sh
DOMAIN=rooms.example.com
LIVEFIRE_API_KEY=$(openssl rand -hex 32)
LIVEFIRE_NODE_SECRET=$(openssl rand -hex 32)

(
  umask 077
  printf 'DOMAIN=%s\n' "$DOMAIN" > .env
  cat > node.json <<EOF
{
  "publicBaseUrl": "https://$DOMAIN",
  "nodeSecret": "$LIVEFIRE_NODE_SECRET",
  "apiKeys": {"default": "$LIVEFIRE_API_KEY"},
  "dataDir": "/var/lib/rooms",
  "allowedOrigins": ["https://$DOMAIN"],
  "auth": {"providers": ["guest"]}
}
EOF
)

sudo chown 10001:10001 node.json
sudo chmod 400 node.json
```

The node container reads `node.json` as UID `10001`. If the game runs on
another web origin, add that origin to `allowedOrigins` with `sudoedit node.json`.
Native WebSocket clients must send an allowed `Origin` when the list is
configured.

### 2. Start and check the API

```sh
docker compose up -d --build
docker compose ps -a
curl --fail-with-body --silent --show-error --write-out '\nHTTP %{http_code}\n' \
  -H "Authorization: Bearer $LIVEFIRE_API_KEY" \
  "https://$DOMAIN/v1/rooms"
```

Run the curl command in the shell that generated the API key. Expect
`HTTP 200` and an empty `rooms` list on a fresh node. The one-shot `site`
container should exit with code `0` after building the docs. If the API
check fails, inspect `docker compose logs rooms-node caddy`. Check DNS
and inbound ports if Caddy is still obtaining the certificate.

### 3. Create a room

```sh
curl --fail-with-body --silent --show-error --write-out '\nHTTP %{http_code}\n' \
  -X POST "https://$DOMAIN/v1/rooms" \
  -H "Authorization: Bearer $LIVEFIRE_API_KEY" \
  -H 'Content-Type: application/json' \
  --data '{
    "template": "relay",
    "config": {
      "version": 1,
      "template": "relay",
      "capacity": 8,
      "maxRows": 64,
      "totalBytes": 32768,
      "playerKeys": {"pose": {"maxBytes": 256, "publishesPerSecond": 10}},
      "roomKeys": {}
    }
  }'
```

Expect `HTTP 201`, a `wss://` room URL and a one-time `joinToken`. Give
the URL and token to the first player. Mint a new token for each
additional player with [the room token endpoint](/docs/api/).

The Compose stack serves the API and WebSockets through Caddy and
publishes the docs at `https://<your-domain>/docs/`. Back up `node.json`,
`.env`, and the `rooms-data` volume. Room configuration survives a
restart. Live simulation state is held in memory.

For Bluesky sign-in and the developer panel, see [Player accounts](/docs/accounts/).
Supabase is optional and is covered [below](#platform-data-in-supabase).

## Already run a PDS?

An existing AT Protocol Personal Data Server (PDS) can support player
sign-in, guest account creation, or both.

- **Sign in players who already have accounts.** Follow the
  [AT Protocol sign-in setup](/docs/accounts/#2-turn-sign-in-on-in-nodejson).
  Players use their existing handles. Livefire looks up each handle,
  finds its PDS in the account’s DID document, and sends the player to
  that server’s OAuth provider. Keep the default handle resolver if it
  can resolve your players’ handles.
- **Create guest accounts on your PDS.** Add the
  [`ident` block](/docs/identity-ladder/#what-your-server-needs) to
  `node.json`. Set `pdsUrl` to your existing PDS’s HTTPS origin,
  `serviceKey` to its admin password, and `handleDomain` to a suffix
  that PDS accepts. Follow the linked DNS and restart steps, then try
  [creating a device account](/docs/identity-ladder/#in-the-typescript-sdk)
  from your game client.

## Server config reference (`node.json`)

| Field | Type | Default / rule | Meaning |
| --- | --- | --- | --- |
| `publicBaseUrl` | string | — | Origin used to build room URLs (`wss://…/play/<key>`); must match the public domain behind Caddy |
| `nodeSecret` | string | 16+ chars | HMAC key for join/creator tokens; generate 32+ random characters |
| `apiKeys` | object | — | Service keys (name → secret) — **bootstrap ADMIN keys** (`Authorization: Bearer <key>`), hashed at boot; in Postgres mode they never become database rows |
| `dataDir` | string | Required | SQLite directory (persist it — join-token consumption and room pins survive restarts) |
| `listen.port` | int | 8787, 1024–65535 | Server listen port (plain HTTP; TLS is the proxy's job) |
| `listen.address` | string | `0.0.0.0` | Bind address |
| `allowedOrigins` | string[] | `[]` | Allowed WebSocket origins. An empty list accepts any origin |
| `trustedProxies` | string[] | `[]` | IP addresses of reverse proxies trusted to supply the client IP for rate limiting |
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

The [Caddyfile](https://github.com/HolotypePteLtd/livefire/blob/master/deploy/Caddyfile)
forwards the room API, WebSockets, identity and panel routes to the node.
Caddy serves the docs from the shared site volume. Only Caddy publishes
ports on the host.

For per-player throttling behind a proxy, put the direct proxy IP in
`trustedProxies`. With the default empty list, the node counts connections
by the address of its direct peer. If the proxy is recreated with a
different IP, update the configured address.

## Deploy with Coolify and Traefik

The [Coolify example](https://github.com/HolotypePteLtd/livefire/tree/master/deploy/coolify)
runs the rooms node behind Traefik. Route the node's domain to port
`8787`, terminate TLS at the proxy, and set `publicBaseUrl` to the
external HTTPS origin. You can deploy the docs separately as a static
site.

## Platform data in Supabase

By default the node uses SQLite. Admin access comes from `adminDids` in `node.json`. To manage admins through the panel or enable key quotas and the audit log, apply the [Supabase migrations](https://github.com/HolotypePteLtd/livefire/tree/master/supabase) to your stack. Set both environment variables on the node service, then restart the node.

```text
SUPABASE_URL=https://<kong-domain-of-your-supabase-stack>
SUPABASE_SECRET_KEY=<service-key>
```

On first boot, `adminDids` seeds the Postgres admin table. The node then reads admins, panel-issued keys, and their limits from Postgres. It checks room creation quotas there. Room configuration and join-token consumption still use local SQLite. Live simulation state stays in memory. Unset both variables and restart to return to the node’s SQLite configuration.

## Run locally with Dart

Install Dart 3.12 or newer and the native build tools `clang` and
`cmake`. From the repository root, copy the example into a private
temporary directory.

```sh
livefire_local_dir=$(mktemp -d)
cp deploy/node.example.json "$livefire_local_dir/node.json"
```

In that file, replace the example secrets, set `publicBaseUrl` to
`http://127.0.0.1:8787`, and set `listen.address` to `127.0.0.1`.
Use a writable absolute path for `dataDir` and set `allowedOrigins`
to `[]` for local development.

```sh
cd packages/node
dart run bin/node.dart --config "$livefire_local_dir/node.json"
```

Use the API check above against `http://127.0.0.1:8787/v1/rooms` with
the key you saved in the local config. Clients on this node receive
`ws://` room URLs.

## Serve the docs on a separate domain

Compose serves the documentation and API on the same host. You can also deploy the static docs separately. Set `publicBaseUrl` to the node’s HTTPS origin so the API returns the correct room URLs. Add the web game’s origin to `allowedOrigins` if the game connects from a different host. See [site deployment](https://github.com/HolotypePteLtd/livefire/tree/master/site) for the build and hosting options.
