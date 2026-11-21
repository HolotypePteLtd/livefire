---
title: Developer panel
description: The node's built-in dashboard at /panel — sign in with Bluesky, manage admins and API keys, watch rooms and the audit log.
---

The rooms node ships its own dashboard at **`/panel`** — no extra
service, no build step, served by the node itself. It is the
self-serve surface for the one secret a game backend needs: the API
key.

On the hosted node it is
[play.holotype.com.sg/panel](https://play.holotype.com.sg/panel); on
your own node it is `https://<your-domain>/panel`.

## Sign in with Bluesky

The panel uses the same "sign in with Bluesky" the rooms use. You sign
in with your own account; the node verifies it over AT Protocol OAuth
and gives the panel a 12-hour session. Nothing to install, no
passwords.

Who gets in depends on the node's **persistence mode** (below): in
SQLite mode the operator lists admin DIDs in `node.json`; in Postgres
mode the admin list itself is managed from the panel.

- Not an admin? You can sign in, but the panel says *not authorized* —
  ask an admin to promote your DID (Postgres mode) or the operator to
  add it to `adminDids` (SQLite mode).
- No admins at all? The panel shows *disabled*.
- Guests never see the panel, and API keys are never panel
  credentials: it is a human surface only.

## Two persistence modes

The panel's *platform data* — the admin list, API keys, per-key
counters, the audit log — can live either in the node's own SQLite
file (the default, zero setup) or in a shared Supabase Postgres. The
mode is **automatic**: set `SUPABASE_URL` + `SUPABASE_SECRET_KEY` in
the node's environment and the platform half moves to Postgres; leave
them unset and everything stays SQLite, exactly as before. Rooms,
players and join tokens — the hot data plane — always stay in the
node's SQLite file and never wait on Postgres.

| | SQLite (default) | Supabase Postgres |
| --- | --- | --- |
| Admins | `adminDids` in `node.json`, read-only | managed in the panel: promote by DID **or handle**, revoke with guards |
| API keys | created/revoked in the panel, unscoped | created/revoked in the panel, with **scopes** |
| Audit log | — | every mutating panel action, visible in the panel |
| Setup | nothing | two env vars + one migration on the Supabase stack |

Postgres mode is what the hosted node runs (the same self-hosted
Supabase stack our other products share). Self-hosters who want it:
see [Self-hosting](/docs/self-hosting/#platform-data-in-supabase) —
it needs a Supabase stack with a service key and the panel tables
applied.

## Admins (Postgres mode)

On the first Postgres-mode boot, the `adminDids` from `node.json` are
seeded into the database — once. From then on the database is the
source of truth and the config list is ignored: the panel's Admins
section promotes a new admin by DID or Bluesky handle (the node
resolves the handle to the DID itself) and revokes admins again. Two
guards keep you from locking yourself out: you cannot revoke your own
access, and you cannot revoke the last active admin. Every change
lands in the audit log.

## API keys: created, shown once, hashed — optionally scoped

The keys page lists every key — its prefix, label, scopes, creation
date, and how much work it has done — and creates new ones:

- **Create**: give it a label, get a full key (`sk_…`). It is shown
  **exactly once**; only a SHA-256 hash is stored, so nobody — not
  even the operator — can show it again. Copy it straight into your
  game backend's environment.
- **Scopes** (Postgres mode): a key can be limited to a number of
  rooms (`maxRooms`, blank = unlimited) and to specific templates
  (`templates`, blank = all). Going over is refused with a clear
  `403 key_room_limit` / `403 key_template_not_allowed` — the limit is
  enforced in the database, not just in the panel.
- **Revoke**: dead immediately. Rooms stay up; new API calls get
  `401`.
- **Counters**: rooms created and join tokens minted per key, so you
  can see which game did what.

Keys that live in `node.json` (`apiKeys`) are **bootstrap** keys. They
show with a badge and cannot be revoked from the panel — removing one
is a config edit and a restart, on purpose: the panel can never lock
the operator out of their own node. In Postgres mode they are not even
database rows — the node keeps their hashes in memory only.

## Audit log (Postgres mode)

Every mutating panel action — a key created or revoked, an admin
promoted or revoked — writes one row: when, who, what, on which
target, with the details. The panel shows the newest entries; it is
the "who changed what" answer for a shared node.

## Rooms at a glance

The rooms page is read-only: every room on the node with its template,
status, peer count and age. For anything else — creating rooms,
minting join tokens — use the API; that part is two lines with the
[TypeScript SDK](/docs/multiplayer-server/#the-hosted-node-preview-rooms-without-a-server):

```ts
const of = Livefire.admin(API_KEY, NODE_URL);
const room = await of.createRoom({ template: 'relay', capacity: 16 });
```

## Running it on your own node

The panel is part of the node binary. Follow the [player account setup](/docs/accounts/)
to enable OAuth and mount the signing key. Then set `adminDids` in
`node.json`:

```json
{
  "adminDids": ["did:plc:your-did-here"],
  "auth": {
    "providers": ["guest", "atproto"],
    "atproto": {
      "clientName": "your game name",
      "entrywayUrl": "https://bsky.social",
      "plcDirectoryUrl": "https://plc.directory",
      "jwksPath": "/etc/rooms/oauth-client-jwks.json"
    }
  }
}
```

Your DID is on your Bluesky profile page (`did:plc:…`). If sign-in was
already working for players, the panel works too — the JWKS file is
the same one. See [Player accounts](/docs/accounts/) for the auth
block and [Self-hosting](/docs/self-hosting/) for the full config
reference.

---
*The panel's own surface: `GET /panel` (page), `/panel/api/session`,
`/panel/api/auth/start` + `/panel/api/auth/result` (sign-in),
`/panel/api/keys` (list/create/revoke), `/panel/api/admins`
(list/promote/revoke, Postgres mode), `/panel/api/audit` (Postgres
mode), `/panel/api/rooms`. Panel sessions are `ps_` HMAC tokens under
the node secret, 12 h, Bearer — never API keys.*
