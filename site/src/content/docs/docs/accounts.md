---
title: Enable player sign-in
description: Configure AT Protocol OAuth and sign players in with their existing handles.
---

A player who signs in can use their existing AT Protocol account, including one hosted on their own PDS. Livefire adds their public profile to the room roster and binds bans to their account ID (DID). Guests can still join with a one-time token.

Start with a [running node on an HTTPS domain](/docs/self-hosting/). You’ll need Dart to generate the node’s signing key.

## 1. Make the server's private key (once)

The server signs its sign-in requests with a private key. Generate one
at the root of your checkout. From that directory, run:

```sh
(umask 077; cd packages/node && dart run tool/gen_client_jwks.dart ../../oauth-client-jwks.json)
sudo chown 10001:10001 oauth-client-jwks.json
sudo chmod 400 oauth-client-jwks.json
```

Back up the private key and keep it out of version control.

## 2. Turn sign-in on in `node.json`

Open `node.json` with `sudoedit` if it is owned by the node’s UID.
Replace the guest-only `auth` block with:

```json
"auth": {
  "providers": ["guest", "atproto"],
  "atproto": {
    "clientName": "your game name",
    "entrywayUrl": "https://bsky.social",
    "plcDirectoryUrl": "https://plc.directory",
    "jwksPath": "/etc/rooms/oauth-client-jwks.json"
  }
}
```

Apply the change with the optional OAuth mount:

```sh
docker compose -f docker-compose.yml -f docker-compose.atproto.yml up -d --force-recreate rooms-node
```

Use both Compose files for subsequent updates to an OAuth-enabled node.
For a native process, set `jwksPath` to the private file on that host.

Players can sign in with an existing AT Protocol account, including one
on a self-hosted PDS. Livefire uses `auth.atproto.entrywayUrl` to resolve
the handle, then reads the account’s DID document to find its PDS.
The player approves sign-in with that PDS’s OAuth provider. If you run
your own handle resolver, set `entrywayUrl` to its HTTPS origin. It
must implement `com.atproto.identity.resolveHandle`.

See [using an existing PDS](/docs/self-hosting/#already-run-a-pds)
to set up guest account creation.

## 3. Start sign-in from your game

When the player chooses **Sign in**, request the following URL on your node. Supply the player’s handle and the room’s `roomKey`.

```text
GET /auth/start?handle=alice.bsky.social&room=7YPL-xKq3-...&format=json
```

Open the returned `authorizationUrl` in the player’s browser. Keep the `flow` value and poll `GET /auth/result?flow=<flow>` while the player approves sign-in with their account provider. On success, connect to the returned `url`, which includes the join token. Without `format=json`, the start endpoint redirects the browser directly to the provider. The roster includes the verified DID and updates when the node fetches the player’s public profile. See the [identity reference](/docs/identity/) for the handshake and resume rules.

If sign-in fails, check the node logs and confirm `publicBaseUrl` matches the public HTTPS origin. To publish a result or achievement to a consenting player’s account, see [match events](https://github.com/HolotypePteLtd/livefire/blob/master/docs/match_events.md).
