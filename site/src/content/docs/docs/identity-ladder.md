---
title: Identity ladder
description: Let players start instantly as guests, keep progress with a device keypair, recover it on a new device — and upgrade later.
---

For a game, identity is a ladder — every rung should be climbable
*while playing*, and nobody should be asked to sign up on day 0:

1. **Day 0 — play immediately.** The game generates a **device
   account** on the player's machine: an `anon-…` guest handle on your
   rooms server, zero signup, zero prompts. The player is in the room
   in one round-trip.
2. **Their key, their progress.** Alongside the account the client
   generates an ES256 **recovery keypair**. The private half never
   leaves the device (it is stored encrypted in IndexedDB — the SDK
   does this for you). Lose the session — new device, cleared browser
   storage — and the key still proves who they are.
3. **Recover.** The client asks the server for a single-use challenge,
   signs it with the recovery key, and gets a fresh session for the
   **same account ID**. Progress and bans follow.
4. **Upgrade later (designed, not shipped yet).** Password/e-mail and
   linking a Bluesky account slot into the same ladder — recovery keys
   keep working.

This page is about the client + server pieces that ship today: the
`/ident/*` routes on a rooms node and the TypeScript SDK surface.

## What your server needs

Device accounts are created on **your PDS** (the account server), so
the node needs an `ident` block in `node.json`:

```json
"ident": {
  "pdsUrl": "https://pds.example.com",
  "serviceKey": "…",
  "handleDomain": "play.example.com"
}
```

- `pdsUrl` — your PDS.
- `serviceKey` — the **PDS admin password** (`PDS_ADMIN_PASSWORD`).
  This is required, and it is all the node needs: guest creation rides
  the admin path every stock reference PDS supports (no special PDS
  build). For each guest account the node mints a single-use invite
  code as the admin (`createInviteCode`, basic auth) and then calls
  `createAccount` with `{handle, password, inviteCode}` — the same
  thing `pdsadmin account create` does. The generated password is
  stored by the node (never shown to the player) so it can write
  things like match records into the guest's repo later.
- `handleDomain` — where the auto-generated guest handles live:
  `anon-<6 random>.<handleDomain>`. The `anon-` namespace plus a guest
  flag in the node's database keep guest accounts distinguishable from
  upgraded ones later. Defaults to your `publicBaseUrl` host.
- Optional: `nonceTtlSeconds` (default 300) and
  `sessionTtlSeconds` (default 30 days).

Without the block, every `/ident` route is a 404 and nothing else
changes. Account creation is rate-limited per IP like the rest of the
node's public surface.

## The routes

| Route | What it does |
| --- | --- |
| `POST /ident/device-account` `{rotationPubJwk, handle?, room?}` | Creates the guest account on your PDS, stores the recovery public key, returns `{did, handle, session}` — plus a one-time join token and play URL when `room` is given. |
| `GET /ident/nonce?did=…` | A single-use challenge nonce for that DID (short TTL). |
| `POST /ident/recover` `{did, nonce, assertion, room?}` | The nonce + an ES256 signature over `{iss, sub, nonce, iat}` by the recovery key → a fresh session for the same DID (and a panel session too, if that DID is one of your panel admins). |

`session` is a `gs_` token — a bearer credential the SDK caches. The
recovery key is checked every time a session is re-minted, so a lost
session is never a lost account.

## In the TypeScript SDK

```ts
import { Livefire, openKeystore } from 'openfire-sdk';

// Day 0 — one call on every boot: creates the account on first launch,
// revives it afterwards (cached session, or a recovery proof).
const account = await Livefire.deviceAccount.create({
  host: 'https://play.example.com',
  roomKey: room.roomKey,   // optional: mint a join token immediately
  keystore: openKeystore(), // default: encrypted IndexedDB
});

// Play — the same Room surface as Livefire.join().
const game = await account.joinRoom({ roomKey: room.roomKey, name: 'Sam' });

// New device / cleared storage: the sealed keystore record is all that
// must survive. Same did, fresh session.
const back = await Livefire.deviceAccount.recover({
  host: 'https://play.example.com',
  keystore: openKeystore(), // reads the surviving record
});
```

A wrong key cannot recover an account: the server checks the signature
against the stored public key and refuses (403), and every nonce dies
on first use — replays fail.

### Passphrase or not

The keystore encrypts the private key either way (AES-GCM):

- **No passphrase (v1 default):** the wrapping key is a random device
  key stored beside the encrypted blob. This protects the key material
  from casual export and copy-paste leakage — but an attacker who can
  read the browser storage wholesale gets both halves. Convenient;
  honest about what it is.
- **With a passphrase:** `openKeystore({ passphrase })` derives the
  wrapping key with PBKDF2 (150k iterations, per-record salt). A stolen
  storage blob is then useless without the passphrase — at the cost of
  asking the player for one.

The recovery *protocol* is identical either way; the passphrase only
hardens storage. (A stolen *device* is a later rung — the Bluesky link
upgrade is what protects against that.)

## Trust note

The node operator holds the PDS-level rotation key and therefore
outranks the client recovery key at the PDS layer — v1 guarantees are
app-level (recovery from session loss), not protection against a
malicious operator. Same trust level as Bluesky itself today. The
operator also holds each guest account's generated password (that is
what lets the node write into the player's repo) — a guest device
account is the operator's account in exactly the way a Bluesky account
is the PDS operator's to administer.

Concretely: a malicious operator could take over a device account at
the PDS layer, and recovery keys do not defend against that. What they
do guarantee — and what the tests pin — is that session loss, device
change and cleared storage never lose the account, and that nobody
*else* can claim it through the `/ident` routes.

## Upgrade paths (designed, later slices)

- **Password / e-mail** — an additional recovery factor above the
  keypair, for players who will not manage keys.
- **Bluesky link** — the existing Bluesky sign-in attaches to the same
  DID: real handle and avatar on the player list, bans across
  identities. The recovery key keeps working alongside it.

Self-hosting details (PDS service-level account creation, persistence
modes) live in [Identity](/docs/identity/) and
[Self-hosting](/docs/self-hosting/).
