# Identity: Guests, Device Accounts & AT Protocol

Livefire supports three composable identity tiers. Start with zero-friction guests, add recoverable device accounts, or turn on Bluesky / AT Protocol sign-in — all using the same room protocol.

---

## Identity tiers at a glance

| Tier | How a player joins | Verified DID? | What it unlocks |
| :--- | :--- | :--- | :--- |
| **1. Guest token** (`guest`) | One-time `jt_` token from `POST /v1/rooms` or `…/tokens` | No | Instant play; no account required |
| **2. Device account** (`/ident/*`) | Client-generated ES256 keypair + PDS guest account | Yes (`did:…`) | Zero-signup persistent DID, session recovery, DID-bound bans |
| **3. AT Protocol OAuth** (`atproto`) | Bluesky / PDS sign-in via `/auth/start` | Yes (`did:…`) | Portable identity, prefetched avatar/displayName, cross-device resume, `/panel` admin access |

---

## AT Protocol sign-in (`/auth/*`)

The Livefire node acts as a confidential OAuth client (`private_key_jwt` with ES256 + PKCE + DPoP). Completion uses **polling** (`/auth/result?flow=…`) so the exact same flow works on web popups and desktop browsers.

```text
  Client / Game                     Livefire Node                         AT Protocol (PDS / AS)
  ─────────────                     ─────────────                         ──────────────────────
        │ 1. GET /auth/start              │                                          │
        │    ?handle&room[&creator=true   │── resolveHandle → DID doc → PDS ────────►│
        │     &creatorToken=ct_…]         │── AS metadata + PAR (PKCE/DPoP/JWT) ────►│
        │◄── {authorizationUrl, flow} ────┤                                          │
        │                                 │                                          │
        │ 2. Open authorizationUrl in browser → user approves ──────────────────────►│
        │                                 │                                          │
        │                                 │◄── GET /auth/callback?code&state&iss ────┤
        │                                 │── token exchange → verified sub (DID) ──►│
        │                                 │── mint DID-bound jt_ join token          │
        │ 3. Poll GET /auth/result?flow=… │                                          │
        │◄── {joinToken, did, url, …} ────┤                                          │
        │                                 │                                          │
        │ 4. WebSocket /play/<roomKey>?token=<joinToken> ───────────────────────────►│
```

### What a verified DID unlocks in rooms
- **DID-bound bans:** Bans apply to the player's account ID for the room's lifetime, across handle changes and reconnects.
- **Identity-bound resume:** A resume token bound to a DID cannot be used by a guest or another DID (`Session identity changed`).
- **Creator leadership:** Claiming `creator=true` on `/auth/start` requires presenting the room's `creatorToken` (`&creatorToken=ct_…`), preventing unauthorized players from hijacking leadership.
- **Portable profiles:** On first join, the node fetches `app.bsky.actor.getProfile` in the background (never blocking join), caches `displayName`, `avatar`, and `handle` in SQLite (`did_profiles`, 24 h TTL), and broadcasts updates via `members[].profile`.

### Node configuration

Generate the node's private ES256 key once:

```sh
cd packages/node
dart run tool/gen_client_jwks.dart /etc/rooms/oauth-client-jwks.json
```

Enable the provider in `node.json`:

```json
{
  "publicBaseUrl": "https://rooms.example.com",
  "auth": {
    "providers": ["guest", "atproto"],
    "atproto": {
      "clientName": "My Game Rooms",
      "entrywayUrl": "https://bsky.social",
      "plcDirectoryUrl": "https://plc.directory",
      "jwksPath": "/etc/rooms/oauth-client-jwks.json"
    }
  }
}
```

- `/oauth/client.json` serves the OAuth client metadata document (its URL is the `client_id`).
- `/oauth/jwks.json` serves only the public half of `jwksPath`.
- Production authorization servers require `https://` for `publicBaseUrl`.

---

## Guest identity ladder (`/ident/*`)

For games that want persistent player IDs with **zero signup screen**:

```text
  Day 0 (first launch)
    Client generates ES256 keypair locally (private key never leaves device)
      ──► POST /ident/device-account { rotationPubJwk, room? }
      ◄── { did, handle: "anon-xxxxxx.<domain>", session: "gs_…", joinToken? }

  Recovery (new device or cleared storage)
    Client ──► GET  /ident/nonce?did=…            ──► { nonce }
    Client ──► POST /ident/recover { did, nonce, assertion (ES256 JWS), room? }
           ◄── fresh gs_ session (and ps_ session if DID is a panel admin)
```

### Configuration (`node.json`)

```json
{
  "ident": {
    "pdsUrl": "https://pds.example.com",
    "serviceKey": "your-pds-admin-password",
    "handleDomain": "pds.example.com",
    "nonceTtlSeconds": 300,
    "sessionTtlSeconds": 2592000
  }
}
```

- Use a handle suffix listed in your PDS's `com.atproto.server.describeServer` response under `availableUserDomains`. Omit the leading dot in `handleDomain`.
- The node creates accounts on your stock AT Protocol PDS via `com.atproto.server.createInviteCode` (Basic auth `admin:<serviceKey>`) + `com.atproto.server.createAccount`.
- Recovery public keys (`recovery_keys`) and generated guest credentials (`guest_credentials`) persist in both SQLite and Supabase Postgres modes (`supabase/migrations/0002` & `0003`).
- In TypeScript, use `Livefire.deviceAccount.create()` / `Livefire.deviceAccount.recover()` from `sdk/typescript/src/identity.ts` (includes encrypted IndexedDB keystore).

> **Trust note:** Recovery keys are **app-level**. The node operator holds the PDS-level rotation key and generated guest app password, so v1 guarantees recovery from client session loss — not protection against a malicious node operator.

---

## Package boundaries

| Package | Responsibility |
| :--- | :--- |
| `packages/atproto_identity` | Client-side desktop loopback OAuth (`AtprotoAccountManager`) and `NodeAuthClient` (no `dart:io` in `NodeAuthClient`). |
| `packages/server_sdk` | Server-side `AtprotoAuthProvider`, `NodeAtprotoResolver`, `ConfidentialClient`, `ProfileService`, `GuestIdentityApi`, and `MatchEventPublisher`. |
| `packages/protocol` & `packages/client` | Zero AT Protocol dependencies — identity flows purely as an opaque adapter-verified string and optional roster profile map. |
