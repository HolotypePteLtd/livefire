# Control-Plane HTTP API

Send requests to your node’s HTTPS origin. If you have a hosted preview key, use `https://play.holotype.com.sg`.

---

## Authentication & key scoping

Send an API key on every `/v1/*` request:

```http
Authorization: Bearer <api-key>
```

| Key source | Capabilities | Management |
| :--- | :--- | :--- |
| **Bootstrap keys** (`node.json` → `apiKeys`) | Full operator access to all rooms on the node | Read-only in `/panel`; edit `node.json` and restart |
| **Panel-issued keys** (`POST /panel/api/keys`) | Scoped to **rooms created by that key**; optional `maxRooms` and `templates` limits (Postgres mode) | Created once (hash-only storage) and revocable in `/panel` |

- Missing or revoked key → `401 unauthorized`.
- Request bodies on `/v1/*` are capped at **4 MiB** (oversized bodies → `413 payload_too_large`).

---

## Endpoints at a glance

| Method & Path | Purpose | Success |
| :--- | :--- | :--- |
| `POST /v1/rooms` | Create a room from a template config; returns room URL + first join token | `201 Created` |
| `POST /v1/rooms/:id/tokens` | Mint an additional one-time join token (optionally return `creatorToken`) | `201 Created` |
| `GET /v1/rooms/:id` | Look up room status, peer count, capacity, URL, and pinned config | `200 OK` |
| `GET /v1/rooms?limit=&cursor=` | Cursor-paginated list of rooms (newest first, omits `config`) | `200 OK` |
| `DELETE /v1/rooms/:id` | Drain and close a room immediately (idempotent) | `204 No Content` |
| `PUT /v1/rooms/:id/owner` | Assign an owner to a legacy room (bootstrap key required) | `204 No Content` |

---

## Room lifecycle

### `POST /v1/rooms` — Create a room

**Request:**

```json
{
  "template": "relay",
  "config": { "...": "validated per room_templates.md (version 1)" },
  "region": "ap-southeast-1"
}
```

- `template` *(required)* — `"relay"` or `"physics"`. Nodes without physics enabled return `422 unsupported_template`.
- `config` *(required)* — validated strictly against [the template schema](https://github.com/HolotypePteLtd/livefire/blob/master/docs/room_templates.md) before provisioning. Unknown fields are rejected; configs are pinned verbatim.
- `region` *(optional)* — accepted and ignored on single-region nodes.

**Response (`201 Created`):**

```json
{
  "roomId": "rm_a7Kx3mQZ",
  "roomKey": "hwJ2mNpq4XbK7TzvRfZeWx3a",
  "template": "relay",
  "url": "wss://play.holotype.com.sg/play/hwJ2mNpq4XbK7TzvRfZeWx3a",
  "joinToken": "jt_eyJybSI6… .k7Qm2vN…",
  "joinTokenExpiresAt": "2026-12-01T12:15:00Z",
  "creatorToken": "ct_…",
  "createdAt": "2026-12-01T12:00:00Z",
  "status": "live"
}
```

- **`roomId`** (`rm_` + 8 chars) — API handle used for lookup, token minting, and deletion.
- **`roomKey`** (24 chars) — unguessable URL key used on `/play/<roomKey>`.
- **`joinToken`** (`jt_…`) — HMAC-SHA256-signed, single-use, room-bound join token.
- **`creatorToken`** (`ct_…`) — room-leader credential presented on join (and required when claiming `creator=true` via `/auth/start`).

---

### `POST /v1/rooms/:id/tokens` — Mint a join token

**Request (optional body):**

```json
{ "creator": false }
```

**Response (`201 Created`):**

```json
{
  "joinToken": "jt_…",
  "joinTokenExpiresAt": "2026-12-01T12:15:00Z"
}
```

Pass `"creator": true` to also include the room's `creatorToken` in the response.

---

### `GET /v1/rooms/:id` — Look up a room

Returns `200 OK` with `roomId`, `roomKey`, `template`, `status` (`live` | `closed`), `createdAt`, `peers`, `capacity`, `url`, and the pinned `config`. Join and creator tokens are never exposed here.

---

### `GET /v1/rooms?limit=50&cursor=…` — List rooms

Cursor-paginated (`limit` 1–200, default 50), ordered by `createdAt` descending. Returns `{ "rooms": [...], "nextCursor": "..." }` (`nextCursor` is omitted on the last page). Individual items match lookup without `config`.

---

### `DELETE /v1/rooms/:id` — Drain & close a room

Closes the room immediately, disconnecting peers with WebSocket close code `1001` (no resume allowed). Returns `204 No Content` (idempotent if already closed).

### `PUT /v1/rooms/:id/owner` — Assign a legacy room owner

Rooms created before owner tracking have no recorded creator key. A bootstrap key sees `"ownerKeyId":null` for these rooms in the list and lookup responses. To assign a legacy room to its verified owner, send `{"keyId":"ak_…"}` with the ID of an active panel-issued key from `GET /panel/api/keys`. The assigned key can then list, look up, close, and mint join tokens for that room.

Repeating the same assignment returns `204 No Content`. Assigning an already owned room to a different key returns `409 conflict`.

---

## Join token semantics

```text
  Backend ──(POST /v1/rooms/:id/tokens)──► Node mints jt_<payload>.<hmac>
                                                     │
  Client  ──(WS /play/<roomKey>?token=jt_…)──────────▼
                                           Pre-upgrade gate checks:
                                             1. Per-IP rate limit
                                             2. Origin allowlist
                                             3. HMAC signature, expiry & room binding
                                             4. Live room & connected-peer capacity
                                             5. Consume nonce once (SQLite token_uses)
```

- **Default TTL:** 15 minutes (`joinTokenTtlSeconds`, configurable 60–86400 s).
- **One-time use:** Each `jt_` nonce is persisted in SQLite on upgrade; replaying a consumed token closes the socket with `1008`.
- **Restart persistence:** Room configs and consumed token nonces survive node restarts in SQLite. Live room simulation state is memory-only — on the next join after a restart, the room is lazily recreated from its pinned config.

---

## Error format

Every non-2xx response returns JSON:

```json
{
  "error": {
    "code": "invalid_config",
    "message": "capacity must be an integer in 1-128",
    "field": "config"
  }
}
```

| Code | HTTP | Meaning |
| :--- | :--- | :--- |
| `invalid_request` | `400` | Malformed JSON body or query parameter |
| `unauthorized` | `401` | Missing, invalid, or revoked API key |
| `forbidden` | `403` | Bootstrap key required for legacy owner assignment |
| `key_room_limit` | `403` | Scoped key reached its `maxRooms` ceiling |
| `key_template_not_allowed` | `403` | Template not allowed by key's `templates` scope |
| `not_found` | `404` | Unknown or inaccessible room, or unknown active panel key |
| `conflict` | `409` | Conflicting state mutation |
| `payload_too_large` | `413` | Request body exceeds size limit |
| `unsupported_template` | `422` | Template not enabled on this node |
| `invalid_config` | `422` | Config failed `room_templates.md` validation |
| `quota_exceeded` | `429` | Node room/capacity limit or IP rate limit reached |
| `internal` | `500` | Unexpected server error (internals never leaked) |
| `unavailable` | `503` | PostgreSQL room authorization is temporarily unavailable |
