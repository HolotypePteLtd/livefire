---
title: Device accounts and recovery
description: Create player accounts on your PDS and recover a session using a device key.
---

If your game needs a persistent player ID before sign-up, Livefire can create an account on your PDS. The first time the game runs, the SDK generates an ES256 key pair and sends the public key to the node. The node returns the account’s DID, handle, and session. On later launches, the SDK can use the private key to recover the same DID.

For players who already have an AT Protocol account, [enable sign-in with their existing handle](/docs/accounts/).

## What your server needs

To create device accounts on an existing reference PDS, add an
`ident` block to the Livefire node’s `node.json`:

```json
"ident": {
  "pdsUrl": "https://pds.example.com",
  "serviceKey": "…",
  "handleDomain": "pds.example.com"
}
```

- `pdsUrl` is the PDS’s HTTPS origin, reachable from the Livefire node.
- `serviceKey` is the PDS admin password (`PDS_ADMIN_PASSWORD`). Store it
  in the node’s private configuration. Livefire uses it to mint a
  single-use invite, then creates the account with a generated password.
- `handleDomain` is the suffix for generated handles such as
  `anon-xxxxxx.pds.example.com`. Query your PDS to find its allowed suffixes:

  ```sh
  curl -fsS https://pds.example.com/xrpc/com.atproto.server.describeServer
  ```

  Pick a suffix from `availableUserDomains` and omit its leading dot in
  `handleDomain`. Configure wildcard DNS and HTTPS routing for the
  generated handles as described in the
  [reference PDS setup guide](https://github.com/bluesky-social/pds#configure-dns-for-your-domain).
- `nonceTtlSeconds` defaults to 300. `sessionTtlSeconds` defaults to
  30 days.

Recreate the node container to load the configuration:

```sh
docker compose up -d --force-recreate rooms-node
```

If you enabled player OAuth sign-in, use
[both Compose files](/docs/accounts/#2-turn-sign-in-on-in-nodejson)
when recreating the node. Device-account creation is rate-limited per IP.

## HTTP routes

| Route | What it does |
| --- | --- |
| `POST /ident/device-account` `{rotationPubJwk, handle?, room?}` | Creates the guest account on your PDS, stores the recovery public key, returns `{did, handle, session}` — plus a one-time join token and play URL when `room` is given. |
| `GET /ident/nonce?did=…` | A single-use challenge nonce for that DID (short TTL). |
| `POST /ident/recover` `{did, nonce, assertion, room?}` | The nonce + an ES256 signature over `{iss, sub, nonce, iat}` by the recovery key → a fresh session for the same DID (and a panel session too, if that DID is one of your panel admins). |

The SDK caches the `gs_` session token. To renew a session, the client signs a single-use nonce with its recovery key. The server verifies the signature against the public key it registered for that DID.

## In the TypeScript SDK

Call `create` when the game starts. Set `host` to the Livefire node’s HTTPS origin. The node contacts the PDS on the client’s behalf.

```ts
import { Livefire, openKeystore } from 'openfire-sdk';

const host = 'https://play.example.com';
const keystore = openKeystore();
const account = await Livefire.deviceAccount.create({
  host, keystore, roomKey: room.roomKey,
});
const game = await account.joinRoom({ roomKey: room.roomKey, name: 'Sam' });
```

### Recover a session

Call `recover` with the keystore containing the account’s key. On a new device, first restore the saved keystore record. Clearing browser storage removes the default IndexedDB record. If that was the only copy, the player can no longer recover this DID through the SDK.

```ts
const account = await Livefire.deviceAccount.recover({ host, keystore });
```

### Protect the saved key

By default, the SDK encrypts the record with AES-GCM and stores the wrapping key alongside it. Anyone who can read the whole record can decrypt it. To require a passphrase, call `openKeystore({ passphrase })` at creation and recovery. The SDK derives the wrapping key from the passphrase and a per-record salt using PBKDF2 (150,000 iterations).

The node operator retains the generated PDS account password and the PDS operator controls account rotation. The device key proves identity to Livefire within that trust relationship. Password resets by email and linking a device account to an existing Bluesky account are planned features.
